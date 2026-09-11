-- =============================================================================
-- A.R.M.O.R — Phase 4: Supervisor Dashboard & Compliance Test Suite
-- File: backend/scripts/test_phase4_supervisor_dashboard.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. FIXTURES
-- -----------------------------------------------------------------------------

INSERT INTO mines (id, name, district, state, type, fire_incidents_3yr, gas_incidents_3yr, electrical_incidents_3yr, is_active)
VALUES 
  ('00000000-0000-0000-0000-0000000000a1', 'Test Mine Alpha', 'Dhanbad', 'Jharkhand', 'coal', 10, 4, 1, TRUE),
  ('00000000-0000-0000-0000-0000000000b2', 'Test Mine Beta', 'Bokaro', 'Jharkhand', 'steel', 1, 0, 0, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Workers in Mine Alpha
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, current_streak, longest_streak, last_trained_at, created_at, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111101', 'WKR-JH-9201', 'wkr.alpha.one', 'Worker Alpha One', '00000000-0000-0000-0000-0000000000a1', 'hi', 90, 3, 5, NOW() - INTERVAL '1 day', NOW() - INTERVAL '10 days', TRUE),
  ('11111111-1111-1111-1111-111111111102', 'WKR-JH-9202', 'wkr.alpha.two', 'Worker Alpha Two', '00000000-0000-0000-0000-0000000000a1', 'sat', 45, 0, 1, NOW() - INTERVAL '5 days', NOW() - INTERVAL '10 days', TRUE),
  ('11111111-1111-1111-1111-111111111103', 'WKR-JH-9203', 'wkr.alpha.three', 'Worker Alpha Three', '00000000-0000-0000-0000-0000000000a1', 'hi', 70, 0, 2, NOW() - INTERVAL '35 days', NOW() - INTERVAL '40 days', TRUE)
ON CONFLICT (id) DO NOTHING;

-- Worker in Mine Beta
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, current_streak, longest_streak, last_trained_at, created_at, is_active)
VALUES
  ('22222222-2222-2222-2222-222222222201', 'WKR-JH-9204', 'wkr.beta.one', 'Worker Beta One', '00000000-0000-0000-0000-0000000000b2', 'en', 85, 2, 4, NOW() - INTERVAL '2 days', NOW() - INTERVAL '10 days', TRUE)
ON CONFLICT (id) DO NOTHING;

-- Supervisors
INSERT INTO supervisors (id, username, full_name, mine_id, role, is_active)
VALUES
  ('33333333-3333-3333-3333-333333333301', 'sup.alpha', 'Supervisor Alpha', '00000000-0000-0000-0000-0000000000a1', 'supervisor', TRUE),
  ('33333333-3333-3333-3333-333333333302', 'sup.beta', 'Supervisor Beta', '00000000-0000-0000-0000-0000000000b2', 'supervisor', TRUE),
  ('33333333-3333-3333-3333-333333333303', 'dgms.officer', 'DGMS Inspector', '00000000-0000-0000-0000-0000000000a1', 'dgms_inspector', TRUE)
ON CONFLICT (id) DO NOTHING;

-- Training session for Worker Alpha One (Passed Fire)
INSERT INTO training_sessions (id, worker_id, mine_id, module, difficulty, score, stars, passed, weak_areas, levels_completed, duration_seconds, synced_from_local, created_at)
VALUES
  ('55555555-5555-5555-5555-555555555501', '11111111-1111-1111-1111-111111111101', '00000000-0000-0000-0000-0000000000a1', 'fire', 'hard', 90, 3, TRUE, ARRAY['alarm_delayed'], 3, 600, TRUE, NOW() - INTERVAL '1 day')
ON CONFLICT (id) DO NOTHING;

-- Training session for Worker Alpha Two (Failed Fire)
INSERT INTO training_sessions (id, worker_id, mine_id, module, difficulty, score, stars, passed, weak_areas, levels_completed, duration_seconds, synced_from_local, created_at)
VALUES
  ('55555555-5555-5555-5555-555555555502', '11111111-1111-1111-1111-111111111102', '00000000-0000-0000-0000-0000000000a1', 'fire', 'medium', 45, 0, FALSE, ARRAY['extinguisher_wrong'], 1, 300, TRUE, NOW() - INTERVAL '5 days')
ON CONFLICT (id) DO NOTHING;

-- Certificate for Worker Alpha One
INSERT INTO certificates (id, cert_code, worker_id, session_id, module, score, issued_at, expires_at, qr_hash, is_revoked)
VALUES
  ('66666666-6666-6666-6666-666666666601', 'SK-2026-JH-99001', '11111111-1111-1111-1111-111111111101', '55555555-5555-5555-5555-555555555501', 'fire', 90, NOW() - INTERVAL '1 day', NOW() + INTERVAL '364 days', 'hash123', FALSE)
ON CONFLICT (id) DO NOTHING;

-- Training actions for weak areas telemetry
INSERT INTO training_actions (session_id, action_name, is_correct, response_time_ms, mistake_tag)
VALUES
  ('55555555-5555-5555-5555-555555555501', 'alarm_pull', FALSE, 4200, 'delayed_alarm'),
  ('55555555-5555-5555-5555-555555555502', 'extinguisher_select', FALSE, 3100, 'wrong_extinguisher_class'),
  ('55555555-5555-5555-5555-555555555502', 'alarm_pull', FALSE, 5200, 'delayed_alarm')
ON CONFLICT (id) DO NOTHING;

-- Emergency Drills
INSERT INTO emergency_drills (id, mine_id, title, drill_type, scheduled_date, status)
VALUES
  ('77777777-7777-7777-7777-777777777701', '00000000-0000-0000-0000-0000000000a1', 'Q3 Mine Fire Drill', 'fire', CURRENT_DATE + INTERVAL '5 days', 'scheduled'),
  ('77777777-7777-7777-7777-777777777702', '00000000-0000-0000-0000-0000000000b2', 'Beta Gas Evacuation', 'gas_leak', CURRENT_DATE + INTERVAL '7 days', 'scheduled')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- TEST 1: Supervisor Alpha Dashboard Summary
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '33333333-3333-3333-3333-333333333301';

DO $$
DECLARE
  v_summary JSONB;
BEGIN
  v_summary := get_supervisor_dashboard_summary();

  IF (v_summary->>'total_workers')::INT <> 3 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Expected 3 total workers, got %', v_summary->>'total_workers';
  END IF;

  IF (v_summary->>'trained_workers')::INT <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Expected 1 trained worker, got %', v_summary->>'trained_workers';
  END IF;

  IF (v_summary->>'overdue_workers')::INT <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Expected 1 overdue worker, got %', v_summary->>'overdue_workers';
  END IF;

  IF (v_summary->>'active_certificates_count')::INT <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Expected 1 active cert, got %', v_summary->>'active_certificates_count';
  END IF;

  IF (v_summary->>'upcoming_drills_count')::INT <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Expected 1 upcoming drill, got %', v_summary->>'upcoming_drills_count';
  END IF;

  RAISE NOTICE 'TEST 1 PASSED: get_supervisor_dashboard_summary metrics verified.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 2: Supervisor Workers Listing & Search / Filter
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_res JSONB;
  v_overdue_res JSONB;
BEGIN
  -- List all workers in Mine Alpha
  v_res := get_supervisor_workers();
  IF (v_res->>'total_count')::INT <> 3 THEN
    RAISE EXCEPTION 'TEST 2a FAILED: Expected 3 workers, got %', v_res->>'total_count';
  END IF;

  -- Filter overdue workers
  v_overdue_res := get_supervisor_workers(p_status => 'overdue');
  IF (v_overdue_res->>'total_count')::INT <> 1 THEN
    RAISE EXCEPTION 'TEST 2b FAILED: Expected 1 overdue worker, got %', v_overdue_res->>'total_count';
  END IF;

  IF v_overdue_res->'workers'->0->>'worker_code' <> 'WKR-JH-9203' THEN
    RAISE EXCEPTION 'TEST 2c FAILED: Overdue worker mismatch.';
  END IF;

  RAISE NOTICE 'TEST 2 PASSED: get_supervisor_workers pagination and filters verified.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 3: Supervisor Worker Detail
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_detail JSONB;
BEGIN
  v_detail := get_supervisor_worker_detail('11111111-1111-1111-1111-111111111101');

  IF v_detail->'worker'->>'worker_code' <> 'WKR-JH-9201' THEN
    RAISE EXCEPTION 'TEST 3 FAILED: Worker info not retrieved properly.';
  END IF;

  IF jsonb_array_length(v_detail->'sessions') <> 1 THEN
    RAISE EXCEPTION 'TEST 3 FAILED: Expected 1 session in history.';
  END IF;

  IF jsonb_array_length(v_detail->'certificates') <> 1 THEN
    RAISE EXCEPTION 'TEST 3 FAILED: Expected 1 certificate.';
  END IF;

  RAISE NOTICE 'TEST 3 PASSED: get_supervisor_worker_detail returned complete history.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 4: Supervisor Blocked from Another Mine Worker Detail
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    PERFORM get_supervisor_worker_detail('22222222-2222-2222-2222-222222222201');
    RAISE EXCEPTION 'TEST 4 FAILED: Supervisor Alpha inspected Mine Beta worker!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%WORKER_NOT_FOUND%' THEN
      RAISE NOTICE 'TEST 4 PASSED: Cross-mine worker access blocked.';
    ELSE
      RAISE EXCEPTION 'TEST 4 FAILED with unexpected error: %', SQLERRM;
    END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- TEST 5: Mine Weak-Area Analytics
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_analytics JSONB;
BEGIN
  v_analytics := get_mine_weak_areas();

  IF jsonb_array_length(v_analytics) < 2 THEN
    RAISE EXCEPTION 'TEST 5 FAILED: Expected at least 2 aggregated mistake categories.';
  END IF;

  -- delayed_alarm had 2 failures across 2 workers
  IF v_analytics->0->>'mistake_tag' <> 'delayed_alarm' THEN
    RAISE EXCEPTION 'TEST 5 FAILED: Top weak area must be delayed_alarm, got %', v_analytics->0->>'mistake_tag';
  END IF;

  IF (v_analytics->0->>'failure_count')::INT <> 2 THEN
    RAISE EXCEPTION 'TEST 5 FAILED: delayed_alarm count must be 2.';
  END IF;

  RAISE NOTICE 'TEST 5 PASSED: get_mine_weak_areas aggregate analytics verified.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 6: Mine Recent Activity Feed
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_activity JSONB;
BEGIN
  v_activity := get_mine_recent_activity(5);

  IF jsonb_array_length(v_activity) <> 2 THEN
    RAISE EXCEPTION 'TEST 6 FAILED: Expected 2 recent sessions for Mine Alpha.';
  END IF;

  RAISE NOTICE 'TEST 6 PASSED: get_mine_recent_activity returned feed.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 7: Compliance Report
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_report JSONB;
BEGIN
  v_report := get_compliance_report();

  IF v_report->'mine'->>'name' <> 'Test Mine Alpha' THEN
    RAISE EXCEPTION 'TEST 7a FAILED: Mine name mismatch in report.';
  END IF;

  IF (v_report->'compliance_summary'->>'total_headcount')::INT <> 3 THEN
    RAISE EXCEPTION 'TEST 7b FAILED: Headcount mismatch.';
  END IF;

  IF (v_report->'compliance_summary'->>'certified_count')::INT <> 1 THEN
    RAISE EXCEPTION 'TEST 7c FAILED: Certified count mismatch.';
  END IF;

  RAISE NOTICE 'TEST 7 PASSED: get_compliance_report generated audit payload.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 8: Supervisor Blocked from Generating Other Mine Compliance Report
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    PERFORM get_compliance_report('00000000-0000-0000-0000-0000000000b2');
    RAISE EXCEPTION 'TEST 8 FAILED: Supervisor Alpha requested Mine Beta audit report!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%UNAUTHORIZED%' THEN
      RAISE NOTICE 'TEST 8 PASSED: Cross-mine compliance audit blocked.';
    ELSE
      RAISE EXCEPTION 'TEST 8 FAILED with unexpected error: %', SQLERRM;
    END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- TEST 9: DGMS Inspector Global Compliance Audit Access
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '33333333-3333-3333-3333-333333333303';

DO $$
DECLARE
  v_report JSONB;
BEGIN
  v_report := get_compliance_report('00000000-0000-0000-0000-0000000000b2');

  IF v_report->'mine'->>'name' <> 'Test Mine Beta' THEN
    RAISE EXCEPTION 'TEST 9 FAILED: DGMS auditor could not audit Mine Beta.';
  END IF;

  RAISE NOTICE 'TEST 9 PASSED: DGMS Inspector successfully audited Mine Beta.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 10: RLS on emergency_drills
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '33333333-3333-3333-3333-333333333301';

DO $$
DECLARE
  v_count INT;
BEGIN
  -- Supervisor Alpha should see Mine Alpha drill only
  SELECT COUNT(*) INTO v_count FROM emergency_drills;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST 10a FAILED: Expected 1 drill for Mine Alpha, got %', v_count;
  END IF;

  -- Create a drill for Mine Alpha
  INSERT INTO emergency_drills (mine_id, title, drill_type, scheduled_date)
  VALUES ('00000000-0000-0000-0000-0000000000a1', 'Unannounced Fire Alarm', 'fire', CURRENT_DATE + INTERVAL '10 days');

  RAISE NOTICE 'TEST 10 PASSED: emergency_drills RLS verified.';
END $$;

ROLLBACK;
