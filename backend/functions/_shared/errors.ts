// Standardized error response helpers for Supabase Edge Functions
// Phase 1: Placeholder — will be used from Phase 3 onwards

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
