-- =============================================================================
-- A.R.M.O.R — Corrective Migration: Fix verify_certificate Signature & Phase 6 RPCs
-- Migration: 00000000000007_fix_verify_certificate_signature.sql
-- =============================================================================
-- Resolution for Postgres ERROR: 42P13 (cannot change return type of existing function).
-- PostgreSQL requires an explicit DROP FUNCTION before altering TABLE (OUT parameter) signatures.
--
-- Actions:
--   1. DROP FUNCTION IF EXISTS public.verify_certificate(TEXT);
--   2. Recreate public.verify_certificate(TEXT) with enhanced 11-column return structure
--      including status ('valid', 'expired', 'revoked') and district.
--   3. Re-grant EXECUTE permissions on verify_certificate to anon, authenticated, service_role.
--   4. Reapply issue_training_certificate and get_leaderboard to ensure complete Phase 6
--      installation in case statement 1 failure aborted prior migration execution.
-- =============================================================================

-- =============================================================================
-- 1. DROP EXISTING verify_certificate FUNCTION
-- =============================================================================
DROP FUNCTION IF EXISTS public.verify_certificate(TEXT);

-- =============================================================================
-- 2. RECREATE verify_certificate WITH PHASE 6 RETURN STRUCTURE
-- =============================================================================
CREATE OR REPLACE FUNCTION public.verify_certificate(p_cert_code TEXT)
RETURNS TABLE (
  cert_code    TEXT,
  worker_name  TEXT,
  worker_code  TEXT,
  mine_name    TEXT,
  district     TEXT,
  module       public.training_module,
  score        INTEGER,
  issued_at    TIMESTAMPTZ,
  expires_at   TIMESTAMPTZ,
  status       TEXT,
  is_valid     BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
STABLE
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.cert_code,
    w.full_name                                     AS worker_name,
    w.worker_code,
    COALESCE(m.name, 'Unassigned')                  AS mine_name,
    COALESCE(m.district, 'Jharkhand')               AS district,
    c.module,
    c.score,
    c.issued_at,
    c.expires_at,
    CASE
      WHEN c.is_revoked THEN 'revoked'
      WHEN c.expires_at <= NOW() THEN 'expired'
      ELSE 'valid'
    END                                             AS status,
    (NOT c.is_revoked AND c.expires_at > NOW())     AS is_valid
  FROM   public.certificates c
  JOIN   public.workers      w ON w.id = c.worker_id
  LEFT JOIN public.mines     m ON m.id = w.mine_id
  WHERE  c.cert_code = p_cert_code;
END;
$$;

-- Grant execution to anon (for public QR verification), authenticated, and service_role
GRANT EXECUTE ON FUNCTION public.verify_certificate(TEXT) TO anon, authenticated, service_role;

-- =============================================================================
-- 3. ENSURE CONFIGURABLE BASE URL IN issue_training_certificate
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
  v_cert_code   TEXT;
  v_qr_hash     TEXT;
  v_issued_at   TIMESTAMPTZ := NOW();
  v_expires_at  TIMESTAMPTZ := NOW() + INTERVAL '1 year';
  v_cert_id     UUID;
  v_result      JSONB;
  v_base_url    TEXT;
  v_verify_url  TEXT;
BEGIN
  -- Generate unique cert code (SK-YYYY-JH-XXXXX)
  v_cert_code := public.generate_cert_code();

  -- Compute internal backend integrity hash
  v_qr_hash := public.generate_qr_hash(v_cert_code, p_worker_id, p_module, p_score);

  -- Retrieve configurable verification base URL or fallback to internal template
  v_base_url := NULLIF(current_setting('app.settings.cert_verify_base_url', TRUE), '');
  IF v_base_url IS NULL THEN
    v_base_url := 'https://armor-verify.internal/verify?code=';
  END IF;

  v_verify_url := v_base_url || v_cert_code;

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
  )
  VALUES (
    v_cert_code,
    p_worker_id,
    p_session_id,
    p_module,
    p_score,
    v_issued_at,
    v_expires_at,
    v_qr_hash,
    FALSE
  )
  RETURNING id INTO v_cert_id;

  SELECT jsonb_build_object(
    'id',               v_cert_id,
    'cert_code',        v_cert_code,
    'worker_id',        p_worker_id,
    'session_id',       p_session_id,
    'module',           p_module,
    'score',            p_score,
    'issued_at',        v_issued_at,
    'expires_at',       v_expires_at,
    'qr_hash',          v_qr_hash,
    'verification_url', v_verify_url,
    'is_revoked',       FALSE
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- =============================================================================
-- 4. ENSURE MULTI-TIER LEADERBOARD RPC: get_leaderboard
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_leaderboard(
  p_scope   TEXT DEFAULT 'my_mine',
  p_limit   INTEGER DEFAULT 20,
  p_offset  INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id         UUID;
  v_my_mine_id        UUID;
  v_my_district       TEXT;
  v_limit             INTEGER;
  v_offset            INTEGER;
  v_total_workers     INTEGER := 0;
  v_my_rank           INTEGER := NULL;
  v_my_score_rank     INTEGER := NULL;
  v_my_entry          JSONB := NULL;
  v_leaderboard_json  JSONB := '[]'::jsonb;
BEGIN
  -- 1. Identify caller
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Valid JWT session required.';
  END IF;

  -- 2. Validate scope
  IF p_scope NOT IN ('my_mine', 'my_district', 'all_jharkhand') THEN
    RAISE EXCEPTION 'INVALID_SCOPE: Supported scopes are my_mine, my_district, all_jharkhand.';
  END IF;

  -- 3. Resolve caller context (worker or supervisor)
  SELECT w.mine_id, m.district
  INTO v_my_mine_id, v_my_district
  FROM public.workers w
  LEFT JOIN public.mines m ON m.id = w.mine_id
  WHERE w.id = v_caller_id;

  IF v_my_mine_id IS NULL THEN
    SELECT s.mine_id, m.district
    INTO v_my_mine_id, v_my_district
    FROM public.supervisors s
    LEFT JOIN public.mines m ON m.id = s.mine_id
    WHERE s.id = v_caller_id;
  END IF;

  -- Handle unassigned mine for scoped requests
  IF p_scope = 'my_mine' AND v_my_mine_id IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'unassigned_mine',
      'scope', p_scope,
      'message', 'Worker has not selected a mine yet. Complete mine onboarding or query all_jharkhand.',
      'total_workers', 0,
      'my_rank', NULL,
      'my_score_rank', NULL,
      'my_entry', NULL,
      'leaderboard', '[]'::jsonb
    );
  END IF;

  IF p_scope = 'my_district' AND v_my_district IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'unassigned_district',
      'scope', p_scope,
      'message', 'Worker mine has no registered district. Query all_jharkhand instead.',
      'total_workers', 0,
      'my_rank', NULL,
      'my_score_rank', NULL,
      'my_entry', NULL,
      'leaderboard', '[]'::jsonb
    );
  END IF;

  -- 4. Clamp pagination
  v_limit := GREATEST(1, LEAST(COALESCE(p_limit, 20), 100));
  v_offset := GREATEST(0, COALESCE(p_offset, 0));

  -- 5. Build leaderboard with deterministic ranking CTE
  WITH scoped_workers AS (
    SELECT
      w.id AS worker_uuid,
      w.worker_code,
      w.full_name,
      w.avatar_url,
      COALESCE(m.name, 'Unassigned') AS mine_name,
      COALESCE(m.district, 'Jharkhand') AS district,
      w.safety_score,
      w.current_streak,
      w.longest_streak,
      COUNT(DISTINCT ts.id) FILTER (WHERE ts.passed = TRUE) AS modules_passed,
      COALESCE(wb.badge_count, 0) AS badges_count,
      w.created_at
    FROM public.workers w
    LEFT JOIN public.mines m ON m.id = w.mine_id
    LEFT JOIN public.training_sessions ts ON ts.worker_id = w.id
    LEFT JOIN LATERAL (
      SELECT COUNT(*)::INT AS badge_count
      FROM public.worker_badges
      WHERE worker_id = w.id
    ) wb ON TRUE
    WHERE w.is_active = TRUE
      AND (
        p_scope = 'all_jharkhand'
        OR (p_scope = 'my_mine' AND w.mine_id = v_my_mine_id)
        OR (p_scope = 'my_district' AND m.district = v_my_district)
      )
    GROUP BY
      w.id, w.worker_code, w.full_name, w.avatar_url,
      m.name, m.district, w.safety_score, w.current_streak,
      w.longest_streak, wb.badge_count, w.created_at
  ),
  ranked AS (
    SELECT
      worker_uuid,
      worker_code,
      full_name,
      avatar_url,
      mine_name,
      district,
      safety_score,
      current_streak,
      longest_streak,
      modules_passed,
      badges_count,
      ROW_NUMBER() OVER (
        ORDER BY
          safety_score DESC,
          longest_streak DESC,
          modules_passed DESC,
          created_at ASC,
          worker_code ASC
      )::INT AS rank,
      DENSE_RANK() OVER (ORDER BY safety_score DESC)::INT AS score_rank
    FROM scoped_workers
  )
  SELECT
    (SELECT COUNT(*)::INT FROM ranked),
    (SELECT rank FROM ranked WHERE worker_uuid = v_caller_id),
    (SELECT score_rank FROM ranked WHERE worker_uuid = v_caller_id),
    (
      SELECT jsonb_build_object(
        'rank',           r.rank,
        'score_rank',     r.score_rank,
        'worker_code',    r.worker_code,
        'full_name',      r.full_name,
        'avatar_url',     r.avatar_url,
        'mine_name',      r.mine_name,
        'district',       r.district,
        'safety_score',   r.safety_score,
        'current_streak', r.current_streak,
        'longest_streak', r.longest_streak,
        'modules_passed', r.modules_passed,
        'badges_count',   r.badges_count
      )
      FROM ranked r
      WHERE r.worker_uuid = v_caller_id
    ),
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'rank',           r.rank,
            'score_rank',     r.score_rank,
            'worker_code',    r.worker_code,
            'full_name',      r.full_name,
            'avatar_url',     r.avatar_url,
            'mine_name',      r.mine_name,
            'district',       r.district,
            'safety_score',   r.safety_score,
            'current_streak', r.current_streak,
            'longest_streak', r.longest_streak,
            'modules_passed', r.modules_passed,
            'badges_count',   r.badges_count
          )
          ORDER BY r.rank ASC
        )
        FROM (
          SELECT * FROM ranked
          ORDER BY rank ASC
          LIMIT v_limit OFFSET v_offset
        ) r
      ),
      '[]'::jsonb
    )
  INTO
    v_total_workers,
    v_my_rank,
    v_my_score_rank,
    v_my_entry,
    v_leaderboard_json;

  RETURN jsonb_build_object(
    'status',         'ok',
    'scope',          p_scope,
    'total_workers',  v_total_workers,
    'my_rank',        v_my_rank,
    'my_score_rank',  v_my_score_rank,
    'my_entry',       v_my_entry,
    'limit',          v_limit,
    'offset',         v_offset,
    'leaderboard',    v_leaderboard_json
  );
END;
$$;

-- Grant execution to authenticated users
GRANT EXECUTE ON FUNCTION public.get_leaderboard(TEXT, INTEGER, INTEGER) TO authenticated, service_role;
