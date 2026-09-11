-- =============================================================================
-- A.R.M.O.R — Phase 7: Backend Production Hardening & Security Hardening
-- Migration: 00000000000008_production_hardening.sql
-- =============================================================================
-- Features:
--   1. Revoke public direct execution on verify_certificate(TEXT) from 'anon'.
--      Enforces that all public QR verification requests must route through the
--      verify-certificate Edge Function gateway for rate limiting & validation.
--   2. Authoritative training session integrity trigger:
--      Guarantees server-side computation of stars and pass thresholds even if
--      attempted via direct REST insert.
--   3. Database performance indexes for session sync, supervisor KPIs,
--      safety score recomputations, and notification queues.
-- =============================================================================

-- =============================================================================
-- 1. REVOKE DIRECT ANON ACCESS TO verify_certificate
-- =============================================================================
-- Closes direct anonymous RPC access. Public scanners must invoke the
-- Edge Function gateway (which enforces regex validation, IP rate limits,
-- and edge caching) before querying this function via service_role.
-- =============================================================================

REVOKE EXECUTE ON FUNCTION public.verify_certificate(TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.verify_certificate(TEXT) TO authenticated, service_role;

-- =============================================================================
-- 2. TRAINING SESSION INTEGRITY TRIGGER
-- =============================================================================
-- Enforces authoritative score-to-stars and score-to-pass mapping on any
-- training_sessions INSERT or UPDATE, preventing client-side forgery.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.enforce_training_session_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- 1. Authoritative computation of stars from score
  NEW.stars := public.calculate_stars(NEW.score);

  -- 2. Authoritative passing threshold (score >= 60)
  NEW.passed := (NEW.score >= 60);

  -- 3. Verify worker_id matches auth.uid() for regular authenticated clients
  IF current_user = 'authenticated' AND NEW.worker_id <> auth.uid() THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Cannot insert or modify training session for another worker.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_training_session_integrity ON public.training_sessions;
CREATE TRIGGER trg_training_session_integrity
  BEFORE INSERT OR UPDATE ON public.training_sessions
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_training_session_integrity();

-- =============================================================================
-- 3. PRODUCTION PERFORMANCE INDEXES
-- =============================================================================

-- 3.1 Speed up session deduplication certificate checks (sync_training_session)
CREATE INDEX IF NOT EXISTS idx_certificates_session_id
  ON public.certificates (session_id);

-- 3.2 Speed up supervisor worker listings, KPI rollups, and drill broadcasts
CREATE INDEX IF NOT EXISTS idx_workers_mine_active
  ON public.workers (mine_id, is_active);

-- 3.3 Speed up update_worker_safety_score() module aggregation
CREATE INDEX IF NOT EXISTS idx_training_sessions_passed_module
  ON public.training_sessions (worker_id, module)
  WHERE passed = TRUE;

-- 3.4 Speed up worker notification feed ordering (get_my_notifications)
CREATE INDEX IF NOT EXISTS idx_notifications_worker_created
  ON public.notifications (worker_id, created_at DESC);
