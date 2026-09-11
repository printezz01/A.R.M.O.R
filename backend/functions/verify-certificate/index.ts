// =============================================================================
// A.R.M.O.R — Phase 6/7: Public Certificate Verification Edge Function
// File: backend/functions/verify-certificate/index.ts
// =============================================================================
// Publicly accessible verification endpoint for QR code scanners and public auditors.
// Wraps protected verify_certificate(cert_code) PostgreSQL RPC via server-side service key.
// Direct database anon RPC execution is disabled for rate-limiting & abuse prevention.
// Exposes ONLY safe public attributes (worker name, worker code, mine, status, dates).
// Strictly strips all internal UUIDs, DB identifiers, phone numbers, and secrets.
// Includes format validation, rate-limiting abuse protection, and edge caching.
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { errorResponse } from "../_shared/errors.ts";

// Standard A.R.M.O.R Certificate Code Pattern: SK-YYYY-JH-NNNNN
const CERT_CODE_REGEX = /^SK-\d{4}-JH-\d{5}$/i;

// In-memory sliding-window rate limiter per client IP
// 30 requests per minute per IP (best-effort Edge instance limiter)
// For enterprise multi-region clusters, Cloudflare/WAF distributed limiting is recommended.
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const MAX_REQUESTS_PER_WINDOW = 30;
const ipRequestMap = new Map<string, { count: number; resetAt: number }>();

function checkRateLimit(clientIp: string): { allowed: boolean; remaining: number; resetInSec: number } {
  const now = Date.now();
  const entry = ipRequestMap.get(clientIp);

  // Clean up periodically if map grows large
  if (ipRequestMap.size > 10000) {
    for (const [key, val] of ipRequestMap.entries()) {
      if (val.resetAt <= now) ipRequestMap.delete(key);
    }
  }

  if (!entry || entry.resetAt <= now) {
    ipRequestMap.set(clientIp, { count: 1, resetAt: now + RATE_LIMIT_WINDOW_MS });
    return { allowed: true, remaining: MAX_REQUESTS_PER_WINDOW - 1, resetInSec: 60 };
  }

  if (entry.count >= MAX_REQUESTS_PER_WINDOW) {
    const resetInSec = Math.max(1, Math.ceil((entry.resetAt - now) / 1000));
    return { allowed: false, remaining: 0, resetInSec };
  }

  entry.count += 1;
  const resetInSec = Math.max(1, Math.ceil((entry.resetAt - now) / 1000));
  return { allowed: true, remaining: MAX_REQUESTS_PER_WINDOW - entry.count, resetInSec };
}

serve(async (req: Request) => {
  // 1. CORS Preflight
  const corsRes = handleCors(req);
  if (corsRes) return corsRes;

  // 2. HTTP Method Check
  if (req.method !== "GET" && req.method !== "POST") {
    return errorResponse("Method not allowed. Use GET or POST.", 405, "METHOD_NOT_ALLOWED");
  }

  // 3. Client IP Extraction & Rate Limiting
  const clientIp =
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    req.headers.get("cf-connecting-ip") ||
    "client-default";

  const rateLimit = checkRateLimit(clientIp);
  const rateLimitHeaders = {
    "X-RateLimit-Limit": String(MAX_REQUESTS_PER_WINDOW),
    "X-RateLimit-Remaining": String(rateLimit.remaining),
    "X-RateLimit-Reset": String(rateLimit.resetInSec),
  };

  if (!rateLimit.allowed) {
    return new Response(
      JSON.stringify({
        error: {
          message: "Verification rate limit exceeded. Please retry in a few seconds.",
          code: "RATE_LIMIT_EXCEEDED",
          retry_after_seconds: rateLimit.resetInSec,
        },
      }),
      {
        status: 429,
        headers: {
          ...corsHeaders,
          ...rateLimitHeaders,
          "Content-Type": "application/json",
          "Retry-After": String(rateLimit.resetInSec),
        },
      }
    );
  }

  // 4. Extract Certificate Code
  let certCode: string | null = null;
  if (req.method === "GET") {
    const url = new URL(req.url);
    certCode = url.searchParams.get("code") || url.searchParams.get("cert_code");
  } else {
    try {
      const body = await req.json();
      certCode = body.code || body.cert_code;
    } catch {
      return errorResponse("Invalid JSON request body.", 400, "BAD_REQUEST");
    }
  }

  if (!certCode || typeof certCode !== "string") {
    return errorResponse(
      "Missing certificate code. Provide 'code' parameter.",
      400,
      "MISSING_CERT_CODE"
    );
  }

  const normalizedCode = certCode.trim().toUpperCase();

  // 5. Strict Format Validation (Abuse/Injection Prevention)
  if (!CERT_CODE_REGEX.test(normalizedCode)) {
    return new Response(
      JSON.stringify({
        status: "invalid_format",
        is_valid: false,
        message: "Invalid certificate code format. Expected format: SK-YYYY-JH-NNNNN.",
        provided_code: normalizedCode,
      }),
      {
        status: 400,
        headers: {
          ...corsHeaders,
          ...rateLimitHeaders,
          "Content-Type": "application/json",
        },
      }
    );
  }

  // 6. Invoke Protected PostgreSQL RPC via Server-Side Service Key
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseServiceKey =
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
      Deno.env.get("SUPABASE_ANON_KEY") ||
      "";

    if (!supabaseUrl || !supabaseServiceKey) {
      return errorResponse("Supabase service configuration missing.", 500, "CONFIG_ERROR");
    }

    // Server-side privileged client: executes verify_certificate while public anon RPC access remains blocked
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data, error } = await supabase.rpc("verify_certificate", {
      p_cert_code: normalizedCode,
    });

    if (error) {
      console.error("Database error during verify_certificate:", error);
      return errorResponse("Unable to verify certificate at this time.", 500, "DB_ERROR");
    }

    // 7. Handle Not Found
    if (!data || !Array.isArray(data) || data.length === 0) {
      return new Response(
        JSON.stringify({
          status: "not_found",
          is_valid: false,
          message: "Certificate not found or invalid certificate identifier.",
          cert_code: normalizedCode,
          verified_at: new Date().toISOString(),
        }),
        {
          status: 404,
          headers: {
            ...corsHeaders,
            ...rateLimitHeaders,
            "Content-Type": "application/json",
            "Cache-Control": "public, max-age=30",
          },
        }
      );
    }

    const cert = data[0];

    // 8. Formulate Status Message & Safe Public Payload
    let message = "Certificate verified successfully.";
    if (cert.status === "revoked") {
      message = "This certificate has been revoked by safety authorities and is no longer valid.";
    } else if (cert.status === "expired") {
      message = `This certificate expired on ${cert.expires_at}. Mandatory DGMS recertification is required.`;
    }

    const responsePayload = {
      status: cert.status, // 'valid' | 'expired' | 'revoked'
      is_valid: cert.is_valid,
      message,
      certificate: {
        cert_code: cert.cert_code,
        worker_name: cert.worker_name,
        worker_code: cert.worker_code,
        mine_name: cert.mine_name,
        district: cert.district,
        module: cert.module,
        score: cert.score,
        issued_at: cert.issued_at,
        expires_at: cert.expires_at,
      },
      verified_at: new Date().toISOString(),
    };

    return new Response(JSON.stringify(responsePayload), {
      status: 200,
      headers: {
        ...corsHeaders,
        ...rateLimitHeaders,
        "Content-Type": "application/json",
        "Cache-Control": "public, max-age=60, s-maxage=60", // 60s cache for verified cert responses
      },
    });
  } catch (err: unknown) {
    const error = err instanceof Error ? err.message : String(err);
    console.error("Unhandled error in verify-certificate:", error);
    return errorResponse("Internal server error during verification.", 500, "INTERNAL_ERROR");
  }
});
