// Standardized error response helpers for Supabase Edge Functions
// File: supabase/functions/_shared/errors.ts

import { corsHeaders } from "./cors.ts";

export function errorResponse(
  message: string,
  status: number = 400,
  code?: string
): Response {
  return new Response(
    JSON.stringify({
      error: {
        message,
        code: code ?? "ERROR",
        timestamp: new Date().toISOString(),
      },
    }),
    {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
}

export function successResponse(data: unknown, status: number = 200): Response {
  return new Response(JSON.stringify({ data }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
