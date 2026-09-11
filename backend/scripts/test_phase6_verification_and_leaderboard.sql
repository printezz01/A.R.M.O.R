-- =============================================================================
-- A.R.M.O.R — Phase 6: Public Verification & Multi-Tier Leaderboards Test Suite
-- File: backend/scripts/test_phase6_verification_and_leaderboard.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. FIXTURES
-- -----------------------------------------------------------------------------

-- Three Mines: Alpha & Gamma in Dhanbad, Beta in Bokaro
INSERT INTO mines (id, name, district, state, type, fire_incidents_3yr, gas_incidents_3yr, electrical_incidents_3yr, is_active)
VALUES
  ('00000000-0000-0000-0000-0000000006a1', 'Test Mine Alpha', 'Dhanbad', 'Jharkhand', 'coal', 8, 3, 0, TRUE),
  ('00000000-0000-0000-0000-0000000006b2', 'Test Mine Beta', 'Bokaro', 'Jharkhand', 'steel', 2, 0, 0, TRUE),
  ('00000000-0000-0000-0000-0000000006c3', 'Test Mine Gamma', 'Dhanbad', 'Jharkhand', 'coal', 5, 1, 0, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Workers
-- Worker 1: Mine Alpha, Dhanbad, score=90, longest_streak=10
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, current_streak, longest_streak, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111601', 'WKR-JH-6001', 'lead.worker.one', 'Worker One Alpha', '00000000-0000-0000-0000-0000000006a1', 'hi', 90, 5, 10, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Worker 2: Mine Alpha, Dhanbad, score=90, longest_streak=5 (tie with Worker 1 on score, but lower streak)
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, current_streak, longest_streak, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111602', 'WKR-JH-6002', 'lead.worker.two', 'Worker Two Alpha', '00000000-0000-0000-0000-0000000006a1', 'sat', 90, 2, 5, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Worker 3: Mine Beta, Bokaro, score=95, longest_streak=20 (highest score)
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, current_streak, longest_streak, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111603', 'WKR-JH-6003', 'lead.worker.three', 'Worker Three Beta', '00000000-0000-0000-0000-0000000006b2', 'en', 95, 15, 20, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Worker 4: Mine Gamma, Dhanbad, score=80, longest_streak=3 (same district as Alpha)
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, current_streak, longest_streak, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111604', 'WKR-JH-6004', 'lead.worker.four', 'Worker Four Gamma', '00000000-0000-0000-0000-0000000006c3', 'hi', 80, 1, 3, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Worker 5: Unassigned Mine, score=50
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, current_streak, longest_streak, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111605', 'WKR-JH-6005', 'lead.worker.five', 'Worker Five Unassigned', NULL, 'hi', 50, 0, 0, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Training sessions for module passed counts
INSERT INTO training_sessions (id, worker_id, mine_id, module, difficulty, score, stars, passed)
VALUES
  ('55555555-5555-5555-5555-555555555601', '11111111-1111-1111-1111-111111111601', '00000000-0000-0000-0000-0000000006a1', 'fire', 'hard', 92, 3, TRUE),
  ('55555555-5555-5555-5555-555555555602', '11111111-1111-1111-1111-111111111601', '00000000-0000-0000-0000-0000000006a1', 'gas_leak', 'medium', 88, 2, TRUE),
  ('55555555-5555-5555-5555-555555555603', '11111111-1111-1111-1111-111111111602', '00000000-0000-0000-0000-0000000006a1', 'fire', 'hard', 90, 3, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Badges for Worker 1
INSERT INTO worker_badges (worker_id, badge_id, earned_at)
SELECT '11111111-1111-1111-1111-111111111601', id, NOW()
FROM badges
LIMIT 2
ON CONFLICT DO NOTHING;

-- Certificates (Valid, Expired, Revoked)
INSERT INTO certificates (id, cert_code, worker_id, session_id, module, score, issued_at, expires_at, qr_hash, is_revoked)
VALUES
  -- Valid
  ('66666666-6666-6666-6666-666666666601', 'SK-2026-JH-00001', '11111111-1111-1111-1111-111111111601', '55555555-5555-5555-5555-555555555601', 'fire', 92, NOW() - INTERVAL '30 days', NOW() + INTERVAL '335 days', 'hash1', FALSE),
  -- Expired
  ('66666666-6666-6666-6666-666666666602', 'SK-2025-JH-00002', '11111111-1111-1111-1111-111111111602', '55555555-5555-5555-5555-555555555603', 'fire', 90, NOW() - INTERVAL '400 days', NOW() - INTERVAL '35 days', 'hash2', FALSE),
  -- Revoked
  ('66666666-6666-6666-6666-666666666603', 'SK-2026-JH-00003', '11111111-1111-1111-1111-111111111603', '55555555-5555-5555-5555-555555555601', 'gas_leak', 88, NOW() - INTERVAL '10 days', NOW() + INTERVAL '355 days', 'hash3', TRUE)
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- TEST 1: Public verify_certificate on Valid Certificate
-- -----------------------------------------------------------------------------
SET LOCAL ROLE anon;

DO $$
DECLARE
  v_rec RECORD;
BEGIN
  SELECT * INTO v_rec FROM verify_certificate('SK-2026-JH-00001');

  IF v_rec.cert_code IS NULL THEN
    RAISE EXCEPTION 'TEST 1a FAILED: Valid certificate returned no rows.';
  END IF;

  IF v_rec.status <> 'valid' OR v_rec.is_valid <> TRUE THEN
    RAISE EXCEPTION 'TEST 1b FAILED: Expected status=valid, is_valid=true. Got status=%, is_valid=%', v_rec.status, v_rec.is_valid;
  END IF;

  IF v_rec.worker_name <> 'Worker One Alpha' OR v_rec.worker_code <> 'WKR-JH-6001' THEN
    RAISE EXCEPTION 'TEST 1c FAILED: Worker metadata mismatch.';
  END IF;

  RAISE NOTICE 'TEST 1 PASSED: Valid certificate verified correctly.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 2: Public verify_certificate on Expired Certificate
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_rec RECORD;
BEGIN
  SELECT * INTO v_rec FROM verify_certificate('SK-2025-JH-00002');

  IF v_rec.cert_code IS NULL THEN
    RAISE EXCEPTION 'TEST 2a FAILED: Expired certificate returned no rows.';
  END IF;

  IF v_rec.status <> 'expired' OR v_rec.is_valid <> FALSE THEN
    RAISE EXCEPTION 'TEST 2b FAILED: Expected status=expired, is_valid=false. Got status=%, is_valid=%', v_rec.status, v_rec.is_valid;
  END IF;

  RAISE NOTICE 'TEST 2 PASSED: Expired certificate correctly identified.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 3: Public verify_certificate on Revoked Certificate
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_rec RECORD;
BEGIN
  SELECT * INTO v_rec FROM verify_certificate('SK-2026-JH-00003');

  IF v_rec.cert_code IS NULL THEN
    RAISE EXCEPTION 'TEST 3a FAILED: Revoked certificate returned no rows.';
  END IF;

  IF v_rec.status <> 'revoked' OR v_rec.is_valid <> FALSE THEN
    RAISE EXCEPTION 'TEST 3b FAILED: Expected status=revoked, is_valid=false. Got status=%, is_valid=%', v_rec.status, v_rec.is_valid;
  END IF;

  RAISE NOTICE 'TEST 3 PASSED: Revoked certificate correctly identified.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 4: Public verify_certificate on Non-existent Certificate
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM verify_certificate('SK-9999-JH-99999');

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 4 FAILED: Unknown certificate should return 0 rows.';
  END IF;

  RAISE NOTICE 'TEST 4 PASSED: Nonexistent certificate returns empty set.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 5: Leaderboard: 'my_mine' Scope
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111602'; -- Worker 2 in Mine Alpha

DO $$
DECLARE
  v_res JSONB;
BEGIN
  v_res := get_leaderboard(p_scope => 'my_mine');

  IF (v_res->>'status') <> 'ok' THEN
    RAISE EXCEPTION 'TEST 5a FAILED: Leaderboard call failed: %', v_res;
  END IF;

  IF (v_res->>'total_workers')::INT <> 2 THEN
    RAISE EXCEPTION 'TEST 5b FAILED: Expected 2 workers in Mine Alpha, got %', v_res->>'total_workers';
  END IF;

  -- Worker 2 should be rank 2 (Worker 1 has longer streak)
  IF (v_res->>'my_rank')::INT <> 2 THEN
    RAISE EXCEPTION 'TEST 5c FAILED: Expected Worker 2 to be rank 2 in Mine Alpha, got %', v_res->>'my_rank';
  END IF;

  -- Verify first entry is Worker 1
  IF v_res->'leaderboard'->0->>'worker_code' <> 'WKR-JH-6001' THEN
    RAISE EXCEPTION 'TEST 5d FAILED: Expected Worker 1 at rank 1.';
  END IF;

  RAISE NOTICE 'TEST 5 PASSED: my_mine leaderboard correctly scoped.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 6: Leaderboard: 'my_district' Scope (Dhanbad spanning Alpha & Gamma)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111601'; -- Worker 1 in Dhanbad

DO $$
DECLARE
  v_res JSONB;
BEGIN
  v_res := get_leaderboard(p_scope => 'my_district');

  -- Dhanbad has Worker 1 (Alpha), Worker 2 (Alpha), Worker 4 (Gamma) = 3 workers
  IF (v_res->>'total_workers')::INT <> 3 THEN
    RAISE EXCEPTION 'TEST 6a FAILED: Expected 3 workers in Dhanbad district, got %', v_res->>'total_workers';
  END IF;

  -- Worker 3 (in Bokaro) must NOT be present
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_res->'leaderboard') w
    WHERE w->>'worker_code' = 'WKR-JH-6003'
  ) THEN
    RAISE EXCEPTION 'TEST 6b FAILED: Worker 3 (Bokaro) leaked into Dhanbad district leaderboard!';
  END IF;

  RAISE NOTICE 'TEST 6 PASSED: my_district leaderboard correctly aggregated.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 7: Leaderboard: 'all_jharkhand' Scope & Deterministic Tie-Breaking
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_res JSONB;
BEGIN
  v_res := get_leaderboard(p_scope => 'all_jharkhand');

  -- Total active workers: 5
  IF (v_res->>'total_workers')::INT <> 5 THEN
    RAISE EXCEPTION 'TEST 7a FAILED: Expected 5 workers statewide, got %', v_res->>'total_workers';
  END IF;

  -- Rank 1 must be Worker 3 (highest safety score = 95)
  IF v_res->'leaderboard'->0->>'worker_code' <> 'WKR-JH-6003' THEN
    RAISE EXCEPTION 'TEST 7b FAILED: Expected Worker 3 at rank 1 with score 95, got %', v_res->'leaderboard'->0->>'worker_code';
  END IF;

  -- Rank 2 must be Worker 1 (score 90, longest_streak 10)
  IF v_res->'leaderboard'->1->>'worker_code' <> 'WKR-JH-6001' THEN
    RAISE EXCEPTION 'TEST 7c FAILED: Expected Worker 1 at rank 2 (streak tie-breaker), got %', v_res->'leaderboard'->1->>'worker_code';
  END IF;

  -- Rank 3 must be Worker 2 (score 90, longest_streak 5)
  IF v_res->'leaderboard'->2->>'worker_code' <> 'WKR-JH-6002' THEN
    RAISE EXCEPTION 'TEST 7d FAILED: Expected Worker 2 at rank 3, got %', v_res->'leaderboard'->2->>'worker_code';
  END IF;

  RAISE NOTICE 'TEST 7 PASSED: all_jharkhand leaderboard and tie-breaking verified.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 8: Unassigned Mine Worker Handling
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111605'; -- Worker 5 (mine_id IS NULL)

DO $$
DECLARE
  v_res JSONB;
BEGIN
  -- my_mine should return unassigned status without throwing error
  v_res := get_leaderboard(p_scope => 'my_mine');
  IF v_res->>'status' <> 'unassigned_mine' THEN
    RAISE EXCEPTION 'TEST 8a FAILED: Expected status=unassigned_mine, got %', v_res->>'status';
  END IF;

  -- all_jharkhand should still succeed
  v_res := get_leaderboard(p_scope => 'all_jharkhand');
  IF v_res->>'status' <> 'ok' OR (v_res->>'my_rank')::INT <> 5 THEN
    RAISE EXCEPTION 'TEST 8b FAILED: Unassigned worker all_jharkhand lookup failed.';
  END IF;

  RAISE NOTICE 'TEST 8 PASSED: Unassigned worker gracefully handled.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 9: Privacy Model Audit
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_res JSONB;
  v_item JSONB;
BEGIN
  v_res := get_leaderboard(p_scope => 'all_jharkhand', p_limit => 1);
  v_item := v_res->'leaderboard'->0;

  -- Ensure strictly no internal UUIDs, phone numbers, or passwords exist in JSON output
  IF v_item ? 'id' OR v_item ? 'worker_uuid' OR v_item ? 'phone' OR v_item ? 'password' OR v_item ? 'username' THEN
    RAISE EXCEPTION 'TEST 9 FAILED: Private fields leaked in leaderboard item: %', v_item;
  END IF;

  RAISE NOTICE 'TEST 9 PASSED: Privacy audit confirmed no sensitive data exposed.';
END $$;

ROLLBACK;
