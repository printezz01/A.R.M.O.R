-- =============================================================================
-- A.R.M.O.R — Phase 4: Supervisor Dashboard API & Compliance
-- Migration: 00000000000004_supervisor_dashboard.sql
-- =============================================================================
-- Features:
--   1. Table: emergency_drills (drill scheduling and attendance foundation)
--   2. RLS policies on emergency_drills (mine-scoped supervisor access)
--   3. RPC: get_supervisor_dashboard_summary (mine summary KPI cards)
--   4. RPC: get_supervisor_workers (paginated search & filter)
--   5. RPC: get_supervisor_worker_detail (profile, sessions, certs, weak areas)
--   6. RPC: get_mine_weak_areas (mine-wide failure pattern analytics)
--   7. RPC: get_mine_recent_activity (live training activity feed)
--   8. RPC: get_compliance_report (DGMS audit & compliance data)
-- =============================================================================

-- =============================================================================
-- 1. TABLE: emergency_drills
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.emergency_drills (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id             UUID NOT NULL REFERENCES public.mines (id) ON DELETE RESTRICT,
  title               TEXT NOT NULL,
  drill_type          public.training_module NOT NULL DEFAULT 'fire',
  scheduled_date      DATE NOT NULL,
  completed_at        TIMESTAMPTZ,
  participants_count  INTEGER NOT NULL DEFAULT 0,
  status              TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'in_progress', 'completed', 'cancelled')),
  notes               TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_emergency_drills_mine_id ON public.emergency_drills (mine_id);
CREATE INDEX IF NOT EXISTS idx_emergency_drills_date    ON public.emergency_drills (scheduled_date DESC);

-- =============================================================================
-- 2. RLS: emergency_drills
-- =============================================================================

ALTER TABLE public.emergency_drills ENABLE ROW LEVEL SECURITY;

-- Supervisor reads drills for own mine
CREATE POLICY "drills_select_supervisor"
  ON public.emergency_drills FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      WHERE s.id = auth.uid()
        AND s.mine_id = emergency_drills.mine_id
        AND s.is_active = TRUE
    )
  );

-- Supervisor creates drills for own mine
CREATE POLICY "drills_insert_supervisor"
  ON public.emergency_drills FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      WHERE s.id = auth.uid()
        AND s.mine_id = emergency_drills.mine_id
        AND s.is_active = TRUE
    )
  );

-- Supervisor updates drills for own mine
CREATE POLICY "drills_update_supervisor"
  ON public.emergency_drills FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      WHERE s.id = auth.uid()
        AND s.mine_id = emergency_drills.mine_id
        AND s.is_active = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      WHERE s.id = auth.uid()
        AND s.mine_id = emergency_drills.mine_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspector and admin read/manage all drills
CREATE POLICY "drills_all_dgms_admin"
  ON public.emergency_drills FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- Service role full access
CREATE POLICY "drills_service_role"
  ON public.emergency_drills FOR ALL TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- =============================================================================
-- 3. RPC: get_supervisor_dashboard_summary()
-- Returns high-level metrics for the supervisor's assigned mine.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_supervisor_dashboard_summary()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_supervisor_id     UUID;
  v_mine_id           UUID;
  v_mine_name         TEXT;
  v_role              TEXT;
  v_total_workers     INT;
  v_trained_workers   INT;
  v_pending_workers   INT;
  v_overdue_workers   INT;
  v_avg_safety_score  INT;
  v_fire_passed       INT;
  v_fire_pct          NUMERIC;
  v_gas_passed        INT;
  v_gas_pct           NUMERIC;
  v_elec_passed       INT;
  v_elec_pct          NUMERIC;
  v_active_certs      INT;
  v_expired_certs     INT;
  v_upcoming_drills   INT;
BEGIN
  v_supervisor_id := auth.uid();
  IF v_supervisor_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  -- Authoritatively identify supervisor and assigned mine
  SELECT s.mine_id, s.role::TEXT, m.name
  INTO v_mine_id, v_role, v_mine_name
  FROM public.supervisors s
  JOIN public.mines m ON m.id = s.mine_id
  WHERE s.id = v_supervisor_id AND s.is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Only registered supervisors or safety officers can access the dashboard.';
  END IF;

  -- 1. Total active workers in mine
  SELECT COUNT(*) INTO v_total_workers
  FROM public.workers
  WHERE mine_id = v_mine_id AND is_active = TRUE;

  -- 2. Trained workers (completed at least one passed module)
  SELECT COUNT(DISTINCT worker_id) INTO v_trained_workers
  FROM public.training_sessions ts
  JOIN public.workers w ON w.id = ts.worker_id
  WHERE w.mine_id = v_mine_id AND w.is_active = TRUE AND ts.passed = TRUE;

  -- 3. Pending workers (registered but zero attempts)
  SELECT COUNT(*) INTO v_pending_workers
  FROM public.workers w
  WHERE w.mine_id = v_mine_id
    AND w.is_active = TRUE
    AND NOT EXISTS (
      SELECT 1 FROM public.training_sessions ts WHERE ts.worker_id = w.id
    );

  -- 4. Overdue workers (hasn't trained in >30 days, or pending >14 days)
  SELECT COUNT(*) INTO v_overdue_workers
  FROM public.workers w
  WHERE w.mine_id = v_mine_id
    AND w.is_active = TRUE
    AND (
      (w.last_trained_at IS NOT NULL AND w.last_trained_at < NOW() - INTERVAL '30 days')
      OR
      (w.last_trained_at IS NULL AND w.created_at < NOW() - INTERVAL '14 days')
    );

  -- 5. Average Safety Score
  SELECT COALESCE(ROUND(AVG(safety_score))::INT, 0) INTO v_avg_safety_score
  FROM public.workers
  WHERE mine_id = v_mine_id AND is_active = TRUE;

  -- 6. Module progress: Fire
  SELECT COUNT(DISTINCT ts.worker_id) INTO v_fire_passed
  FROM public.training_sessions ts
  JOIN public.workers w ON w.id = ts.worker_id
  WHERE w.mine_id = v_mine_id AND w.is_active = TRUE AND ts.module = 'fire' AND ts.passed = TRUE;

  v_fire_pct := CASE WHEN v_total_workers > 0 THEN ROUND((v_fire_passed::NUMERIC / v_total_workers::NUMERIC) * 100, 1) ELSE 0 END;

  -- 7. Module progress: Gas Leak
  SELECT COUNT(DISTINCT ts.worker_id) INTO v_gas_passed
  FROM public.training_sessions ts
  JOIN public.workers w ON w.id = ts.worker_id
  WHERE w.mine_id = v_mine_id AND w.is_active = TRUE AND ts.module = 'gas_leak' AND ts.passed = TRUE;

  v_gas_pct := CASE WHEN v_total_workers > 0 THEN ROUND((v_gas_passed::NUMERIC / v_total_workers::NUMERIC) * 100, 1) ELSE 0 END;

  -- 8. Module progress: Electrical
  SELECT COUNT(DISTINCT ts.worker_id) INTO v_elec_passed
  FROM public.training_sessions ts
  JOIN public.workers w ON w.id = ts.worker_id
  WHERE w.mine_id = v_mine_id AND w.is_active = TRUE AND ts.module = 'electrical' AND ts.passed = TRUE;

  v_elec_pct := CASE WHEN v_total_workers > 0 THEN ROUND((v_elec_passed::NUMERIC / v_total_workers::NUMERIC) * 100, 1) ELSE 0 END;

  -- 9. Certificate counts
  SELECT
    COUNT(*) FILTER (WHERE c.expires_at > NOW() AND NOT c.is_revoked),
    COUNT(*) FILTER (WHERE c.expires_at <= NOW() AND NOT c.is_revoked)
  INTO v_active_certs, v_expired_certs
  FROM public.certificates c
  JOIN public.workers w ON w.id = c.worker_id
  WHERE w.mine_id = v_mine_id AND w.is_active = TRUE;

  -- 10. Upcoming drills
  SELECT COUNT(*) INTO v_upcoming_drills
  FROM public.emergency_drills
  WHERE mine_id = v_mine_id AND scheduled_date >= CURRENT_DATE AND status = 'scheduled';

  RETURN jsonb_build_object(
    'mine_id', v_mine_id,
    'mine_name', v_mine_name,
    'role', v_role,
    'total_workers', v_total_workers,
    'trained_workers', v_trained_workers,
    'pending_workers', v_pending_workers,
    'overdue_workers', v_overdue_workers,
    'average_safety_score', v_avg_safety_score,
    'fire_progress', jsonb_build_object('passed_count', v_fire_passed, 'percentage', v_fire_pct),
    'gas_progress', jsonb_build_object('passed_count', v_gas_passed, 'percentage', v_gas_pct),
    'electrical_progress', jsonb_build_object('passed_count', v_elec_passed, 'percentage', v_elec_pct),
    'active_certificates_count', COALESCE(v_active_certs, 0),
    'expired_certificates_count', COALESCE(v_expired_certs, 0),
    'upcoming_drills_count', COALESCE(v_upcoming_drills, 0),
    'generated_at', NOW()
  );
END;
$$;

-- =============================================================================
-- 4. RPC: get_supervisor_workers(...)
-- Paginated search, filter, and listing of workers in supervisor's mine.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_supervisor_workers(
  p_search     TEXT DEFAULT NULL,
  p_status     TEXT DEFAULT 'all',      -- 'all', 'trained', 'pending', 'overdue'
  p_module     public.training_module DEFAULT NULL,
  p_limit      INT DEFAULT 50,
  p_offset     INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_supervisor_id UUID;
  v_mine_id       UUID;
  v_role          TEXT;
  v_total_matched INT;
  v_workers       JSONB;
BEGIN
  v_supervisor_id := auth.uid();
  IF v_supervisor_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  SELECT mine_id, role::TEXT INTO v_mine_id, v_role
  FROM public.supervisors
  WHERE id = v_supervisor_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Supervisor access only.';
  END IF;

  WITH filtered_workers AS (
    SELECT
      w.id,
      w.worker_code,
      w.full_name,
      w.username,
      w.phone,
      w.language,
      w.safety_score,
      w.current_streak,
      w.longest_streak,
      w.last_trained_at,
      w.created_at,
      -- Status calculation
      CASE
        WHEN (w.last_trained_at IS NOT NULL AND w.last_trained_at < NOW() - INTERVAL '30 days')
          OR (w.last_trained_at IS NULL AND w.created_at < NOW() - INTERVAL '14 days')
          THEN 'overdue'
        WHEN EXISTS (SELECT 1 FROM public.training_sessions ts WHERE ts.worker_id = w.id AND ts.passed = TRUE)
          THEN 'trained'
        ELSE 'pending'
      END AS status,
      -- Passed modules
      COALESCE((
        SELECT array_agg(DISTINCT ts.module::TEXT)
        FROM public.training_sessions ts
        WHERE ts.worker_id = w.id AND ts.passed = TRUE
      ), '{}') AS passed_modules,
      -- Active certificate count
      (
        SELECT COUNT(*)
        FROM public.certificates c
        WHERE c.worker_id = w.id AND c.expires_at > NOW() AND NOT c.is_revoked
      ) AS active_certs
    FROM public.workers w
    WHERE w.mine_id = v_mine_id
      AND w.is_active = TRUE
      AND (
        p_search IS NULL
        OR TRIM(p_search) = ''
        OR w.full_name ILIKE '%' || TRIM(p_search) || '%'
        OR w.worker_code ILIKE '%' || TRIM(p_search) || '%'
        OR w.username ILIKE '%' || TRIM(p_search) || '%'
      )
  ),
  status_filtered AS (
    SELECT *
    FROM filtered_workers fw
    WHERE (
      p_status IS NULL OR p_status = 'all' OR fw.status = p_status
    )
    AND (
      p_module IS NULL OR p_module::TEXT = ANY(fw.passed_modules)
    )
  )
  SELECT
    COUNT(*),
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', sf.id,
          'worker_code', sf.worker_code,
          'full_name', sf.full_name,
          'username', sf.username,
          'phone', sf.phone,
          'language', sf.language,
          'safety_score', sf.safety_score,
          'current_streak', sf.current_streak,
          'longest_streak', sf.longest_streak,
          'last_trained_at', sf.last_trained_at,
          'status', sf.status,
          'passed_modules', sf.passed_modules,
          'active_certs', sf.active_certs
        )
        ORDER BY sf.safety_score DESC, sf.full_name ASC
      ),
      '[]'::JSONB
    )
  INTO v_total_matched, v_workers
  FROM (
    SELECT * FROM status_filtered
    ORDER BY safety_score DESC, full_name ASC
    LIMIT GREATEST(p_limit, 1)
    OFFSET GREATEST(p_offset, 0)
  ) sf;

  RETURN jsonb_build_object(
    'total_count', COALESCE(v_total_matched, 0),
    'limit', p_limit,
    'offset', p_offset,
    'workers', v_workers
  );
END;
$$;

-- =============================================================================
-- 5. RPC: get_supervisor_worker_detail(p_worker_id UUID)
-- Detailed profile, training history, certificates, and weak areas.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_supervisor_worker_detail(p_worker_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_supervisor_id UUID;
  v_mine_id       UUID;
  v_role          TEXT;
  v_worker_info   JSONB;
  v_sessions      JSONB;
  v_certs         JSONB;
  v_weak_areas    JSONB;
BEGIN
  v_supervisor_id := auth.uid();
  IF v_supervisor_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  SELECT mine_id, role::TEXT INTO v_mine_id, v_role
  FROM public.supervisors
  WHERE id = v_supervisor_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Supervisor access only.';
  END IF;

  -- Verify supervisor authority over this worker (mine boundary check)
  SELECT jsonb_build_object(
    'id', w.id,
    'worker_code', w.worker_code,
    'username', w.username,
    'full_name', w.full_name,
    'phone', w.phone,
    'language', w.language,
    'mine_id', w.mine_id,
    'mine_name', m.name,
    'safety_score', w.safety_score,
    'current_streak', w.current_streak,
    'longest_streak', w.longest_streak,
    'last_trained_at', w.last_trained_at,
    'created_at', w.created_at
  ) INTO v_worker_info
  FROM public.workers w
  JOIN public.mines m ON m.id = w.mine_id
  WHERE w.id = p_worker_id
    AND w.is_active = TRUE
    AND (v_role IN ('dgms_inspector', 'admin') OR w.mine_id = v_mine_id);

  IF v_worker_info IS NULL THEN
    RAISE EXCEPTION 'WORKER_NOT_FOUND: Worker not found or belongs to another mine.';
  END IF;

  -- 1. Training sessions history
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', ts.id,
        'module', ts.module,
        'difficulty', ts.difficulty,
        'score', ts.score,
        'stars', ts.stars,
        'passed', ts.passed,
        'weak_areas', ts.weak_areas,
        'duration_seconds', ts.duration_seconds,
        'created_at', ts.created_at
      )
      ORDER BY ts.created_at DESC
    ),
    '[]'::JSONB
  ) INTO v_sessions
  FROM public.training_sessions ts
  WHERE ts.worker_id = p_worker_id;

  -- 2. Certificates with expiration countdown
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'cert_code', c.cert_code,
        'module', c.module,
        'score', c.score,
        'issued_at', c.issued_at,
        'expires_at', c.expires_at,
        'is_expired', (c.expires_at <= NOW()),
        'days_to_expiry', GREATEST(0, EXTRACT(DAY FROM (c.expires_at - NOW()))::INT),
        'is_revoked', c.is_revoked
      )
      ORDER BY c.issued_at DESC
    ),
    '[]'::JSONB
  ) INTO v_certs
  FROM public.certificates c
  WHERE c.worker_id = p_worker_id;

  -- 3. Aggregated weak areas from actions
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'mistake_tag', ta.mistake_tag,
        'count', COUNT(*),
        'last_mistake_at', MAX(ta.created_at)
      )
      ORDER BY COUNT(*) DESC
    ),
    '[]'::JSONB
  ) INTO v_weak_areas
  FROM public.training_actions ta
  JOIN public.training_sessions ts ON ts.id = ta.session_id
  WHERE ts.worker_id = p_worker_id
    AND ta.is_correct = FALSE
    AND ta.mistake_tag IS NOT NULL
  GROUP BY ta.mistake_tag;

  RETURN jsonb_build_object(
    'worker', v_worker_info,
    'sessions', v_sessions,
    'certificates', v_certs,
    'weak_areas', v_weak_areas
  );
END;
$$;

-- =============================================================================
-- 6. RPC: get_mine_weak_areas()
-- Aggregate mistake telemetry across all workers in the supervisor's mine.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_mine_weak_areas()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_supervisor_id UUID;
  v_mine_id       UUID;
  v_result        JSONB;
BEGIN
  v_supervisor_id := auth.uid();
  IF v_supervisor_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  SELECT mine_id INTO v_mine_id
  FROM public.supervisors
  WHERE id = v_supervisor_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Supervisor access only.';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'mistake_tag', sub.mistake_tag,
        'action_name', sub.action_name,
        'module', sub.module,
        'failure_count', sub.total_failures,
        'affected_workers_count', sub.affected_workers
      )
      ORDER BY sub.total_failures DESC
    ),
    '[]'::JSONB
  ) INTO v_result
  FROM (
    SELECT
      ta.mistake_tag,
      ta.action_name,
      ts.module,
      COUNT(*) AS total_failures,
      COUNT(DISTINCT ts.worker_id) AS affected_workers
    FROM public.training_actions ta
    JOIN public.training_sessions ts ON ts.id = ta.session_id
    JOIN public.workers w ON w.id = ts.worker_id
    WHERE w.mine_id = v_mine_id
      AND ta.is_correct = FALSE
      AND ta.mistake_tag IS NOT NULL
    GROUP BY ta.mistake_tag, ta.action_name, ts.module
    ORDER BY total_failures DESC
    LIMIT 20
  ) sub;

  RETURN v_result;
END;
$$;

-- =============================================================================
-- 7. RPC: get_mine_recent_activity(p_limit INT DEFAULT 15)
-- Returns the latest completed training attempts across the supervisor's mine.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_mine_recent_activity(p_limit INT DEFAULT 15)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_supervisor_id UUID;
  v_mine_id       UUID;
  v_result        JSONB;
BEGIN
  v_supervisor_id := auth.uid();
  IF v_supervisor_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  SELECT mine_id INTO v_mine_id
  FROM public.supervisors
  WHERE id = v_supervisor_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Supervisor access only.';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'session_id', ts.id,
        'worker_id', w.id,
        'worker_name', w.full_name,
        'worker_code', w.worker_code,
        'module', ts.module,
        'difficulty', ts.difficulty,
        'score', ts.score,
        'stars', ts.stars,
        'passed', ts.passed,
        'duration_seconds', ts.duration_seconds,
        'created_at', ts.created_at
      )
      ORDER BY ts.created_at DESC
    ),
    '[]'::JSONB
  ) INTO v_result
  FROM (
    SELECT ts.*, w.full_name, w.worker_code
    FROM public.training_sessions ts
    JOIN public.workers w ON w.id = ts.worker_id
    WHERE w.mine_id = v_mine_id
    ORDER BY ts.created_at DESC
    LIMIT GREATEST(p_limit, 1)
  ) sub;

  RETURN v_result;
END;
$$;

-- =============================================================================
-- 8. RPC: get_compliance_report(p_mine_id UUID DEFAULT NULL)
-- Generates DGMS audit report payload for web dashboard and export.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_compliance_report(p_mine_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_supervisor_id       UUID;
  v_target_mine_id      UUID;
  v_role                TEXT;
  v_mine                RECORD;
  v_total_workers       INT;
  v_certified_workers   INT;
  v_compliance_rate     NUMERIC;
  v_high_risk_workers   JSONB;
  v_overdue_workers     JSONB;
BEGIN
  v_supervisor_id := auth.uid();
  IF v_supervisor_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  SELECT mine_id, role::TEXT INTO v_target_mine_id, v_role
  FROM public.supervisors
  WHERE id = v_supervisor_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Supervisor access only.';
  END IF;

  -- DGMS inspectors and admins can audit any mine; standard supervisors audit own mine
  IF p_mine_id IS NOT NULL THEN
    IF v_role IN ('dgms_inspector', 'admin') THEN
      v_target_mine_id := p_mine_id;
    ELSIF v_target_mine_id <> p_mine_id THEN
      RAISE EXCEPTION 'UNAUTHORIZED: Cannot access compliance data for other mines.';
    END IF;
  END IF;

  -- Fetch mine metadata
  SELECT id, name, district, state, type, fire_incidents_3yr, gas_incidents_3yr, electrical_incidents_3yr
  INTO v_mine
  FROM public.mines
  WHERE id = v_target_mine_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MINE_NOT_FOUND: Target mine not found.';
  END IF;

  -- Total active workforce
  SELECT COUNT(*) INTO v_total_workers
  FROM public.workers
  WHERE mine_id = v_target_mine_id AND is_active = TRUE;

  -- Certified workforce (at least one valid active certificate)
  SELECT COUNT(DISTINCT worker_id) INTO v_certified_workers
  FROM public.certificates c
  JOIN public.workers w ON w.id = c.worker_id
  WHERE w.mine_id = v_target_mine_id
    AND w.is_active = TRUE
    AND c.expires_at > NOW()
    AND NOT c.is_revoked;

  v_compliance_rate := CASE
    WHEN v_total_workers > 0 THEN ROUND((v_certified_workers::NUMERIC / v_total_workers::NUMERIC) * 100, 1)
    ELSE 0
  END;

  -- High risk workers: safety score < 60
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'worker_code', w.worker_code,
        'full_name', w.full_name,
        'safety_score', w.safety_score,
        'last_trained_at', w.last_trained_at
      )
      ORDER BY w.safety_score ASC
    ),
    '[]'::JSONB
  ) INTO v_high_risk_workers
  FROM public.workers w
  WHERE w.mine_id = v_target_mine_id
    AND w.is_active = TRUE
    AND w.safety_score < 60;

  -- Overdue workers list
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'worker_code', w.worker_code,
        'full_name', w.full_name,
        'last_trained_at', w.last_trained_at,
        'days_overdue', EXTRACT(DAY FROM (NOW() - COALESCE(w.last_trained_at, w.created_at)))::INT
      )
      ORDER BY w.last_trained_at ASC NULLS FIRST
    ),
    '[]'::JSONB
  ) INTO v_overdue_workers
  FROM public.workers w
  WHERE w.mine_id = v_target_mine_id
    AND w.is_active = TRUE
    AND (
      (w.last_trained_at IS NOT NULL AND w.last_trained_at < NOW() - INTERVAL '30 days')
      OR
      (w.last_trained_at IS NULL AND w.created_at < NOW() - INTERVAL '14 days')
    );

  RETURN jsonb_build_object(
    'audit_id', gen_random_uuid(),
    'report_title', 'DGMS Mine Safety Training & Compliance Audit',
    'mine', jsonb_build_object(
      'id', v_mine.id,
      'name', v_mine.name,
      'district', v_mine.district,
      'state', v_mine.state,
      'type', v_mine.type,
      'incident_history', jsonb_build_object(
        'fire_3yr', v_mine.fire_incidents_3yr,
        'gas_3yr', v_mine.gas_incidents_3yr,
        'electrical_3yr', v_mine.electrical_incidents_3yr
      )
    ),
    'compliance_summary', jsonb_build_object(
      'total_headcount', v_total_workers,
      'certified_count', v_certified_workers,
      'compliance_rate_pct', v_compliance_rate,
      'status', CASE WHEN v_compliance_rate >= 80 THEN 'COMPLIANT' WHEN v_compliance_rate >= 60 THEN 'WARNING' ELSE 'NON_COMPLIANT' END
    ),
    'high_risk_workers', v_high_risk_workers,
    'overdue_workers', v_overdue_workers,
    'audited_at', NOW(),
    'auditor_role', v_role
  );
END;
$$;
