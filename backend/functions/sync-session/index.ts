// =============================================================================
// A.R.M.O.R — Phase 3: Sync Session Edge Function
// File: backend/functions/sync-session/index.ts
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { errorResponse, successResponse } from "../_shared/errors.ts";

interface SyncActionPayload {
  action_name: string;
  is_correct: boolean;
  response_time_ms?: number;
  mistake_tag?: string;
  details?: Record<string, unknown>;
}

interface SyncSessionPayload {
  module: "fire" | "gas_leak" | "electrical";
  difficulty: "easy" | "medium" | "hard";
  score: number;
  mine_id?: string;
  weak_areas?: string[];
  levels_completed?: number;
  duration_seconds?: number;
  local_session_id?: string;
  synced_from_local?: boolean;
  actions?: SyncActionPayload[];
}

serve(async (req: Request) => {
  // Handle CORS preflight
  const corsRes = handleCors(req);
  if (corsRes) return corsRes;

  if (req.method !== "POST") {
    return errorResponse("Method not allowed", 405, "METHOD_NOT_ALLOWED");
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return errorResponse("Missing Authorization header", 401, "UNAUTHORIZED");
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

    // Client scoped to caller's JWT
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    // Parse and validate request body
    const payload: SyncSessionPayload = await req.json();

    if (!payload.module || !payload.difficulty || typeof payload.score !== "number") {
      return errorResponse(
        "Invalid payload: module, difficulty, and score are required.",
        400,
        "INVALID_PAYLOAD"
      );
    }

    if (payload.score < 0 || payload.score > 100) {
      return errorResponse(
        "Score must be between 0 and 100.",
        400,
        "INVALID_SCORE"
      );
    }

    // Call atomic PostgreSQL sync RPC
    const { data, error } = await supabase.rpc("sync_training_session", {
      p_module: payload.module,
      p_difficulty: payload.difficulty,
      p_score: payload.score,
      p_mine_id: payload.mine_id ?? null,
      p_weak_areas: payload.weak_areas ?? [],
      p_levels_completed: payload.levels_completed ?? 0,
      p_duration_seconds: payload.duration_seconds ?? null,
      p_local_session_id: payload.local_session_id ?? null,
      p_synced_from_local: payload.synced_from_local ?? true,
      p_actions: payload.actions ?? [],
    });

    if (error) {
      return errorResponse(error.message, 400, error.code ?? "SYNC_FAILED");
    }

    return successResponse(data, 200);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Internal Server Error";
    return errorResponse(message, 500, "INTERNAL_ERROR");
  }
});
