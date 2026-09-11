-- =============================================================================
-- A.R.M.O.R — Phase 3: Training Session Sync & Certificate Issuance
-- Migration: 00000000000002_training_and_certs.sql
-- =============================================================================
-- Features:
--   1. Table: training_actions (granular in-scenario telemetry)
--   2. RLS policies on training_actions (worker isolation, supervisor mine scope)
--   3. Helper function: generate_qr_hash (SHA-256 with standardized secret)
--   4. Atomic RPC: sync_training_session (idempotent sync, action ingestion,
--      authoritative score/stars, weak area capture, safety score recomputation,
--      streak maintenance, and certificate generation)
--   5. Function: issue_training_certificate (callable internally or via RPC)
-- =============================================================================

-- =============================================================================
-- 1. TABLE: training_actions
-- Granular telemetry recording worker decisions during AR scenarios.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.training_actions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id        UUID NOT NULL REFERENCES public.training_sessions (id) ON DELETE CASCADE,
  action_name       TEXT NOT NULL,
  is_correct        BOOLEAN NOT NULL,
  response_time_ms  INTEGER,
  mistake_tag       TEXT,
  details           JSONB,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_training_actions_session_id  ON public.training_actions (session_id);
CREATE INDEX IF NOT EXISTS idx_training_actions_action_name ON public.training_actions (action_name);
CREATE INDEX IF NOT EXISTS idx_training_actions_mistake_tag ON public.training_actions (mistake_tag) WHERE mistake_tag IS NOT NULL;

-- =============================================================================
-- 2. ROW LEVEL SECURITY: training_actions
-- =============================================================================

ALTER TABLE public.training_actions ENABLE ROW LEVEL SECURITY;

-- Worker reads actions for their own sessions
CREATE POLICY "training_actions_select_own"
  ON public.training_actions FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.training_sessions ts
      WHERE ts.id = training_actions.session_id
        AND ts.worker_id = auth.uid()
    )
  );

-- Worker inserts actions for their own sessions
CREATE POLICY "training_actions_insert_own"
  ON public.training_actions FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.training_sessions ts
      WHERE ts.id = training_actions.session_id
        AND ts.worker_id = auth.uid()
    )
  );

-- Supervisor reads actions for workers in their assigned mine
CREATE POLICY "training_actions_select_supervisor"
  ON public.training_actions FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.training_sessions ts
      JOIN public.workers w ON w.id = ts.worker_id
      JOIN public.supervisors s ON s.mine_id = w.mine_id
      WHERE ts.id = training_actions.session_id
        AND s.id = auth.uid()
        AND s.is_active = TRUE
    )
  );

-- DGMS inspectors and admins read all actions
CREATE POLICY "training_actions_select_dgms_admin"
  ON public.training_actions FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- Service role full access
CREATE POLICY "training_actions_service_role"
  ON public.training_actions FOR ALL TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- =============================================================================
-- 3. HELPER FUNCTION: generate_qr_hash
-- Deterministic SHA-256 calculation for offline/online certificate QR code.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.generate_qr_hash(
  p_cert_code  TEXT,
  p_worker_id  UUID,
  p_module     public.training_module,
  p_score      INTEGER
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_secret TEXT := 'ARMOR_DGMS_OFFLINE_SECRET_2026';
BEGIN
  RETURN encode(
    digest(
      p_cert_code || ':' || p_worker_id::TEXT || ':' || p_module::TEXT || ':' || p_score::TEXT || ':' || v_secret,
      'sha256'
    ),
    'hex'
  );
END;
$$;

-- =============================================================================
-- 4. FUNCTION: issue_training_certificate
-- Server-side issuance function for passing training sessions.
-- Sets cert_code, qr_hash, and 1-year expiry.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.issue_training_certificate(
  p_worker_id   UUID,
  p_session_id  UUID,
  p_module      public.training_module,
  p_score       INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cert_code  TEXT;
  v_qr_hash    TEXT;
  v_issued_at  TIMESTAMPTZ := NOW();
  v_expires_at TIMESTAMPTZ := NOW() + INTERVAL '1 year';
  v_cert_id    UUID;
  v_result     JSONB;
BEGIN
  -- Generate unique cert code (SK-YYYY-JH-XXXXX)
  v_cert_code := public.generate_cert_code();

  -- Compute deterministic QR hash
  v_qr_hash := public.generate_qr_hash(v_cert_code, p_worker_id, p_module, p_score);

  INSERT INTO public.certificates (
    cert_code,
    worker_id,
    session_id,
    module,
    score,
    issued_at,
    expires_at,
    qr_hash,
    is_revoked
  ) VALUES (
    v_cert_code,
    p_worker_id,
    p_session_id,
    p_module,
    p_score,
    v_issued_at,
    v_expires_at,
    v_qr_hash,
    FALSE
  ) RETURNING id INTO v_cert_id;

  SELECT jsonb_build_object(
    'id', c.id,
    'cert_code', c.cert_code,
    'worker_id', c.worker_id,
    'session_id', c.session_id,
    'module', c.module,
    'score', c.score,
    'issued_at', c.issued_at,
    'expires_at', c.expires_at,
    'qr_hash', c.qr_hash,
    'is_revoked', c.is_revoked
  ) INTO v_result
  FROM public.certificates c
  WHERE c.id = v_cert_id;

  RETURN v_result;
END;
$$;

-- =============================================================================
-- 5. ATOMIC RPC: sync_training_session
-- Complete transactional ingestion of training sessions from mobile/offline.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.sync_training_session(
  p_module             public.training_module,
  p_difficulty         public.difficulty_mode,
  p_score              INTEGER,
  p_mine_id            UUID DEFAULT NULL,
  p_weak_areas         TEXT[] DEFAULT '{}',
  p_levels_completed   INTEGER DEFAULT 0,
  p_duration_seconds   INTEGER DEFAULT NULL,
  p_local_session_id   TEXT DEFAULT NULL,
  p_synced_from_local  BOOLEAN DEFAULT TRUE,
  p_actions            JSONB DEFAULT '[]'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_worker_id         UUID;
  v_mine_id           UUID;
  v_session_id        UUID;
  v_stars             SMALLINT;
  v_passed            BOOLEAN;
  v_existing_session  RECORD;
  v_existing_cert     JSONB;
  v_cert_result       JSONB := NULL;
  v_new_safety_score  INTEGER;
  v_last_trained      TIMESTAMPTZ;
  v_curr_streak       INTEGER;
  v_long_streak       INTEGER;
  v_merged_weak_areas TEXT[];
  v_action_elem       JSONB;
  v_extracted_tags    TEXT[] := '{}';
BEGIN
  v_worker_id := auth.uid();
  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in to sync training sessions.';
  END IF;

  -- Validate worker exists
  SELECT mine_id, last_trained_at, current_streak, longest_streak
  INTO v_mine_id, v_last_trained, v_curr_streak, v_long_streak
  FROM public.workers
  WHERE id = v_worker_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'WORKER_NOT_FOUND: Active worker profile not found.';
  END IF;

  -- Determine mine_id (passed or worker's registered mine)
  IF p_mine_id IS NOT NULL THEN
    v_mine_id := p_mine_id;
  END IF;

  IF v_mine_id IS NULL THEN
    RAISE EXCEPTION 'MINE_REQUIRED: Worker must have an assigned mine to record training.';
  END IF;

  -- Validate score range
  IF p_score < 0 OR p_score > 100 THEN
    RAISE EXCEPTION 'INVALID_SCORE: Score must be between 0 and 100.';
  END IF;

  -- ---------------------------------------------------------------------------
  -- IDEMPOTENT CHECK: local_session_id deduplication
  -- ---------------------------------------------------------------------------
  IF p_local_session_id IS NOT NULL AND TRIM(p_local_session_id) <> '' THEN
    SELECT ts.id, ts.worker_id, ts.mine_id, ts.module, ts.difficulty,
           ts.score, ts.stars, ts.passed, ts.weak_areas, ts.created_at
    INTO v_existing_session
    FROM public.training_sessions ts
    WHERE ts.worker_id = v_worker_id
      AND ts.local_session_id = TRIM(p_local_session_id);

    IF FOUND THEN
      -- Fetch certificate if one was already issued for this session
      SELECT jsonb_build_object(
        'id', c.id,
        'cert_code', c.cert_code,
        'worker_id', c.worker_id,
        'session_id', c.session_id,
        'module', c.module,
        'score', c.score,
        'issued_at', c.issued_at,
        'expires_at', c.expires_at,
        'qr_hash', c.qr_hash,
        'is_revoked', c.is_revoked
      ) INTO v_existing_cert
      FROM public.certificates c
      WHERE c.session_id = v_existing_session.id;

      SELECT safety_score, current_streak INTO v_new_safety_score, v_curr_streak
      FROM public.workers WHERE id = v_worker_id;

      RETURN jsonb_build_object(
        'already_synced', TRUE,
        'session_id', v_existing_session.id,
        'module', v_existing_session.module,
        'score', v_existing_session.score,
        'stars', v_existing_session.stars,
        'passed', v_existing_session.passed,
        'weak_areas', v_existing_session.weak_areas,
        'certificate', v_existing_cert,
        'safety_score', v_new_safety_score,
        'current_streak', v_curr_streak,
        'created_at', v_existing_session.created_at,
        'message', 'Session already processed.'
      );
    END IF;
  END IF;

  -- ---------------------------------------------------------------------------
  -- AUTHORITATIVE CALCULATION: stars and passed
  -- ---------------------------------------------------------------------------
  v_stars  := public.calculate_stars(p_score);
  v_passed := (p_score >= 60);

  -- ---------------------------------------------------------------------------
  -- WEAK-AREA MERGING FROM ACTIONS
  -- ---------------------------------------------------------------------------
  v_merged_weak_areas := COALESCE(p_weak_areas, '{}');

  IF p_actions IS NOT NULL AND jsonb_typeof(p_actions) = 'array' THEN
    FOR v_action_elem IN SELECT * FROM jsonb_array_elements(p_actions)
    LOOP
      IF (v_action_elem->>'is_correct')::BOOLEAN = FALSE AND (v_action_elem->>'mistake_tag') IS NOT NULL THEN
        v_extracted_tags := array_append(v_extracted_tags, TRIM(v_action_elem->>'mistake_tag'));
      END IF;
    END LOOP;
  END IF;

  -- Combine and deduplicate weak area tags
  SELECT array_agg(DISTINCT tag)
  INTO v_merged_weak_areas
  FROM unnest(v_merged_weak_areas || v_extracted_tags) AS tag
  WHERE tag IS NOT NULL AND TRIM(tag) <> '';

  IF v_merged_weak_areas IS NULL THEN
    v_merged_weak_areas := '{}';
  END IF;

  -- ---------------------------------------------------------------------------
  -- INSERT TRAINING SESSION
  -- ---------------------------------------------------------------------------
  INSERT INTO public.training_sessions (
    worker_id,
    mine_id,
    module,
    difficulty,
    score,
    stars,
    passed,
    weak_areas,
    levels_completed,
    duration_seconds,
    synced_from_local,
    local_session_id
  ) VALUES (
    v_worker_id,
    v_mine_id,
    p_module,
    p_difficulty,
    p_score,
    v_stars,
    v_passed,
    v_merged_weak_areas,
    p_levels_completed,
    p_duration_seconds,
    p_synced_from_local,
    NULLIF(TRIM(p_local_session_id), '')
  ) RETURNING id INTO v_session_id;

  -- ---------------------------------------------------------------------------
  -- INGEST GRANULAR TRAINING ACTIONS
  -- ---------------------------------------------------------------------------
  IF p_actions IS NOT NULL AND jsonb_typeof(p_actions) = 'array' AND jsonb_array_length(p_actions) > 0 THEN
    INSERT INTO public.training_actions (
      session_id,
      action_name,
      is_correct,
      response_time_ms,
      mistake_tag,
      details
    )
    SELECT
      v_session_id,
      COALESCE(elem->>'action_name', 'action'),
      COALESCE((elem->>'is_correct')::BOOLEAN, FALSE),
      (elem->>'response_time_ms')::INTEGER,
      NULLIF(TRIM(elem->>'mistake_tag'), ''),
      elem->'details'
    FROM jsonb_array_elements(p_actions) AS elem;
  END IF;

  -- ---------------------------------------------------------------------------
  -- RECOMPUTE WORKER SAFETY SCORE
  -- ---------------------------------------------------------------------------
  PERFORM public.update_worker_safety_score(v_worker_id);

  SELECT safety_score INTO v_new_safety_score
  FROM public.workers
  WHERE id = v_worker_id;

  -- ---------------------------------------------------------------------------
  -- STREAK MAINTENANCE & LAST_TRAINED_AT
  -- ---------------------------------------------------------------------------
  IF v_last_trained IS NULL THEN
    v_curr_streak := 1;
  ELSIF DATE(v_last_trained AT TIME ZONE 'Asia/Kolkata') = DATE(NOW() AT TIME ZONE 'Asia/Kolkata') THEN
    -- Already trained today, preserve streak
    NULL;
  ELSIF DATE(v_last_trained AT TIME ZONE 'Asia/Kolkata') = DATE((NOW() - INTERVAL '1 day') AT TIME ZONE 'Asia/Kolkata') THEN
    -- Trained yesterday, increment streak
    v_curr_streak := COALESCE(v_curr_streak, 0) + 1;
  ELSE
    -- Streak broken, reset to 1
    v_curr_streak := 1;
  END IF;

  v_long_streak := GREATEST(COALESCE(v_long_streak, 0), v_curr_streak);

  UPDATE public.workers
  SET last_trained_at = NOW(),
      current_streak  = v_curr_streak,
      longest_streak  = v_long_streak,
      updated_at      = NOW()
  WHERE id = v_worker_id;

  -- ---------------------------------------------------------------------------
  -- CERTIFICATE ISSUANCE (IF PASSED)
  -- ---------------------------------------------------------------------------
  IF v_passed = TRUE THEN
    v_cert_result := public.issue_training_certificate(
      v_worker_id,
      v_session_id,
      p_module,
      p_score
    );
  END IF;

  -- ---------------------------------------------------------------------------
  -- RETURN STRUCTURED SYNC RESPONSE
  -- ---------------------------------------------------------------------------
  RETURN jsonb_build_object(
    'already_synced', FALSE,
    'session_id', v_session_id,
    'worker_id', v_worker_id,
    'mine_id', v_mine_id,
    'module', p_module,
    'difficulty', p_difficulty,
    'score', p_score,
    'stars', v_stars,
    'passed', v_passed,
    'weak_areas', v_merged_weak_areas,
    'levels_completed', p_levels_completed,
    'duration_seconds', p_duration_seconds,
    'certificate', v_cert_result,
    'safety_score', v_new_safety_score,
    'current_streak', v_curr_streak,
    'longest_streak', v_long_streak,
    'created_at', NOW()
  );
END;
$$;
