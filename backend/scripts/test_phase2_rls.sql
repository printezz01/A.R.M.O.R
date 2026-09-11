-- =============================================================================
-- A.R.M.O.R — Phase 2: RLS & Auth Validation Test Suite
-- File: backend/scripts/test_phase2_rls.sql
-- Run inside Supabase SQL Editor or psql to verify all Phase 2 security rules
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. TEST FIXTURES SETUP
-- -----------------------------------------------------------------------------

-- Create two test mines
INSERT INTO mines (id, name, district, state, type, fire_incidents_3yr, gas_incidents_3yr, electrical_incidents_3yr, is_active)
VALUES 
  ('00000000-0000-0000-0000-0000000000a1', 'Test Mine Alpha', 'Dhanbad', 'Jharkhand', 'coal', 5, 2, 0, TRUE),
  ('00000000-0000-0000-0000-0000000000b2', 'Test Mine Beta', 'Bokaro', 'Jharkhand', 'steel', 1, 0, 0, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Create two test workers
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'WKR-JH-9001', 'test.worker.alpha', 'Alpha Worker', '00000000-0000-0000-0000-0000000000a1', 'hi', 75, TRUE),
  ('22222222-2222-2222-2222-222222222222', 'WKR-JH-9002', 'test.worker.beta', 'Beta Worker', '00000000-0000-0000-0000-0000000000b2', 'sat', 80, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Create one test supervisor assigned to Mine Alpha
INSERT INTO supervisors (id, username, full_name, mine_id, role, is_active)
VALUES
  ('33333333-3333-3333-3333-333333333333', 'test.supervisor.alpha', 'Supervisor Alpha', '00000000-0000-0000-0000-0000000000a1', 'supervisor', TRUE)
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- TEST 1: Worker reading own profile via RLS
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111111';

DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM workers WHERE id = '11111111-1111-1111-1111-111111111111';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Worker could not read their own profile.';
  END IF;
  RAISE NOTICE 'TEST 1 PASSED: Worker successfully read own profile.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 2: Worker unable to access another worker's profile
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM workers WHERE id = '22222222-2222-2222-2222-222222222222';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 2 FAILED: Worker accessed another worker profile!';
  END IF;
  RAISE NOTICE 'TEST 2 PASSED: Worker isolated from other workers.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 3: Worker updating allowed own fields (language, mine_id, phone)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  UPDATE workers
  SET language = 'en',
      phone = '+919876543210'
  WHERE id = '11111111-1111-1111-1111-111111111111';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST 3 FAILED: Worker could not update allowed own fields.';
  END IF;
  RAISE NOTICE 'TEST 3 PASSED: Worker successfully updated allowed fields.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 4: Worker blocked from altering protected fields (safety_score, worker_code)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    UPDATE workers
    SET safety_score = 100
    WHERE id = '11111111-1111-1111-1111-111111111111';

    RAISE EXCEPTION 'TEST 4 FAILED: Worker was able to modify protected safety_score!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%IMMUTABLE_FIELD%' THEN
      RAISE NOTICE 'TEST 4 PASSED: Mutation of protected safety_score was blocked.';
    ELSE
      RAISE EXCEPTION 'TEST 4 FAILED with unexpected error: %', SQLERRM;
    END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- TEST 5: Supervisor reading workers in assigned mine (Mine Alpha)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '33333333-3333-3333-3333-333333333333';

DO $$
DECLARE
  v_count INT;
BEGIN
  -- Should see Alpha Worker (in Mine Alpha)
  SELECT COUNT(*) INTO v_count FROM workers WHERE mine_id = '00000000-0000-0000-0000-0000000000a1';
  IF v_count < 1 THEN
    RAISE EXCEPTION 'TEST 5 FAILED: Supervisor could not read workers in assigned mine.';
  END IF;
  RAISE NOTICE 'TEST 5 PASSED: Supervisor successfully read assigned mine workers.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 6: Supervisor blocked from reading workers in different mine (Mine Beta)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_count INT;
BEGIN
  -- Should NOT see Beta Worker (in Mine Beta)
  SELECT COUNT(*) INTO v_count FROM workers WHERE mine_id = '00000000-0000-0000-0000-0000000000b2';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 6 FAILED: Supervisor read workers from another mine!';
  END IF;
  RAISE NOTICE 'TEST 6 PASSED: Supervisor cannot view workers from other mines.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 7: Anonymous user reading active mines (onboarding)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE anon;
SET LOCAL "request.jwt.claim.sub" = '';

DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM mines WHERE is_active = TRUE;
  IF v_count < 1 THEN
    RAISE EXCEPTION 'TEST 7 FAILED: Anon user could not read active mines.';
  END IF;
  RAISE NOTICE 'TEST 7 PASSED: Anonymous user can read active mines.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 8: Anonymous user blocked from updating workers or mine selection
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  UPDATE workers SET language = 'hi' WHERE id = '11111111-1111-1111-1111-111111111111';
  IF FOUND THEN
    RAISE EXCEPTION 'TEST 8 FAILED: Anon user was able to modify a worker profile!';
  END IF;
  RAISE NOTICE 'TEST 8 PASSED: Anonymous user blocked from updating workers.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 9: Authenticated mine selection via set_worker_mine RPC
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111111';

DO $$
DECLARE
  v_res JSONB;
BEGIN
  v_res := set_worker_mine('00000000-0000-0000-0000-0000000000b2');
  IF (v_res->>'mine_id') <> '00000000-0000-0000-0000-0000000000b2' THEN
    RAISE EXCEPTION 'TEST 9 FAILED: set_worker_mine did not update worker mine.';
  END IF;
  RAISE NOTICE 'TEST 9 PASSED: Authenticated worker selected mine successfully.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 10: set_worker_mine with non-existent mine fails cleanly
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    PERFORM set_worker_mine('99999999-9999-9999-9999-999999999999');
    RAISE EXCEPTION 'TEST 10 FAILED: set_worker_mine accepted invalid mine UUID!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%MINE_NOT_FOUND%' THEN
      RAISE NOTICE 'TEST 10 PASSED: set_worker_mine rejected non-existent mine.';
    ELSE
      RAISE EXCEPTION 'TEST 10 FAILED with unexpected error: %', SQLERRM;
    END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- TEST 11: Authoritative profile retrieval via get_auth_profile()
-- -----------------------------------------------------------------------------
-- Test for Worker
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111111';

DO $$
DECLARE
  v_profile JSONB;
BEGIN
  v_profile := get_auth_profile();
  IF v_profile->>'role' <> 'worker' THEN
    RAISE EXCEPTION 'TEST 11a FAILED: Expected role worker, got %', v_profile->>'role';
  END IF;
  IF v_profile->>'username' <> 'test.worker.alpha' THEN
    RAISE EXCEPTION 'TEST 11b FAILED: Expected username test.worker.alpha, got %', v_profile->>'username';
  END IF;
  RAISE NOTICE 'TEST 11 PASSED: get_auth_profile correctly returned worker profile.';
END $$;

-- Test for Supervisor
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '33333333-3333-3333-3333-333333333333';

DO $$
DECLARE
  v_profile JSONB;
BEGIN
  v_profile := get_auth_profile();
  IF v_profile->>'role' <> 'supervisor' THEN
    RAISE EXCEPTION 'TEST 12a FAILED: Expected role supervisor, got %', v_profile->>'role';
  END IF;
  IF v_profile->>'username' <> 'test.supervisor.alpha' THEN
    RAISE EXCEPTION 'TEST 12b FAILED: Expected username test.supervisor.alpha, got %', v_profile->>'username';
  END IF;
  RAISE NOTICE 'TEST 12 PASSED: get_auth_profile correctly returned supervisor profile.';
END $$;

-- Roll back all test fixtures so database remains clean
ROLLBACK;
