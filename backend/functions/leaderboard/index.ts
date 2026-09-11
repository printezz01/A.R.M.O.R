// =============================================================================
// A.R.M.O.R — Phase 6: Leaderboard Edge Function
// File: backend/functions/leaderboard/index.ts
// =============================================================================
// Secure HTTP wrapper for multi-tier leaderboards ('my_mine', 'my_district', 'all_jharkhand').
// Enforces authenticated JWT access.
// Forwards caller session to execute authoritative get_leaderboard PostgreSQL RPC.
// Protects worker privacy: no phone numbers, passwords, or internal UUIDs exposed.
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { errorResponse } from "../_shared/errors.ts";

const VALID_SCOPES = new Set(["my_mine", "my_district", "all_jharkhand"]);

serve(async (req: Request) => {
  // 1. CORS Preflight
  const corsRes = handleCors(req);
  if (corsRes) return corsRes;

  // 2. HTTP Method Check
  if (req.method !== "GET" && req.method !== "POST") {
    return errorResponse("Method not allowed. Use GET or POST.", 405, "METHOD_NOT_ALLOWED");
  }

  // 3. Authenticated JWT Verification
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return errorResponse("Missing or invalid Authorization header.", 401, "UNAUTHORIZED");
  }

  // 4. Extract Query Parameters / Request Body
  let scope = "my_mine";
  let limit = 20;
  let offset = 0;

  if (req.method === "GET") {
    const url = new URL(req.url);
    const scopeParam = url.searchParams.get("scope");
    if (scopeParam) scope = scopeParam.trim().toLowerCase();

    const limitParam = url.searchParams.get("limit");
    if (limitParam) limit = parseInt(limitParam, 10) || 20;

    const offsetParam = url.searchParams.get("offset");
    if (offsetParam) offset = parseInt(offsetParam, 10) || 0;
  } else {
    try {
      const body = await req.json();
      if (body.scope) scope = String(body.scope).trim().toLowerCase();
      if (typeof body.limit === "number") limit = body.limit;
      if (typeof body.offset === "number") offset = body.offset;
    } catch {
      return errorResponse("Invalid JSON payload.", 400, "BAD_REQUEST");
    }
  }

  if (!VALID_SCOPES.has(scope)) {
    return errorResponse(
      `Invalid scope '${scope}'. Valid scopes: my_mine, my_district, all_jharkhand.`,
      400,
      "INVALID_SCOPE"
    );
  }

  // 5. Invoke Supabase RPC under caller's JWT context
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

    if (!supabaseUrl || !supabaseAnonKey) {
      return errorResponse("Supabase service configuration missing.", 500, "CONFIG_ERROR");
    }

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data, error } = await supabase.rpc("get_leaderboard", {
      p_scope: scope,
      p_limit: limit,
      p_offset: offset,
    });

    if (error) {
      console.error("Database error during get_leaderboard:", error);
      return errorResponse(error.message || "Failed to retrieve leaderboard.", 500, "DB_ERROR");
    }

    return new Response(JSON.stringify(data), {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
      },
    });
  } catch (err: unknown) {
    const error = err instanceof Error ? err.message : String(err);
    console.error("Unhandled error in leaderboard Edge Function:", error);
    return errorResponse("Internal server error.", 500, "INTERNAL_ERROR");
  }
});
