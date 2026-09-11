-- =============================================================================
-- A.R.M.O.R — Phase 3: Training Session Sync & Certificate Test Suite
-- File: backend/scripts/test_phase3_sync_certs.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. TEST FIXTURES
-- -----------------------------------------------------------------------------

INSERT INTO mines (id, name, district, state, type, fire_incidents_3yr, gas_incidents_3yr, electrical_incidents_3yr, is_active)
VALUES 
  ('00000000-0000-0000-0000-0000000000a1', 'Test Mine Alpha', 'Dhanbad', 'Jharkhand', 'coal', 10, 4, 1, TRUE),
  ('00000000-0000-0000-0000-0000000000b2', 'Test Mine Beta', 'Bokaro', 'Jharkhand', 'steel', 1, 0, 0, TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, current_streak, longest_streak, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'WKR-JH-9101', 'sync.worker.one', 'Sync Worker One', '00000000-0000-0000-0000-0000000000a1', 'hi', 0, 0, 0, TRUE),
  ('22222222-2222-2222-2222-222222222222', 'WKR-JH-9102', 'sync.worker.two', 'Sync Worker Two', '00000000-0000-0000-0000-0000000000b2', 'sat', 0, 0, 0, TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO supervisors (id, username, full_name, mine_id, role, is_active)
VALUES
  ('33333333-3333-3333-3333-333333333333', 'sync.sup.alpha', 'Supervisor Alpha', '00000000-0000-0000-0000-0000000000a1', 'supervisor', TRUE),
  ('44444444-4444-4444-4444-444444444444', 'sync.sup.beta', 'Supervisor Beta', '00000000-0000-0000-0000-0000000000b2', 'supervisor', TRUE)
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- TEST 1: Sync Passing Session (Fire, score 88 -> 2 stars, passed=TRUE)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111111';

DO $$
DECLARE
  v_res JSONB;
  v_session_id UUID;
  v_cert_code TEXT;
  v_action_count INT;
  v_safety_score INT;
  v_streak INT;
BEGIN
  v_res := sync_training_session(
    p_module => 'fire',
    p_difficulty => 'hard',
    p_score => 88,
    p_mine_id => '00000000-0000-0000-0000-0000000000a1',
    p_weak_areas => ARRAY['alarm_delayed'],
    p_levels_completed => 3,
    p_duration_seconds => 480,
    p_local_session_id => 'local-sess-uuid-001',
    p_synced_from_local => TRUE,
    p_actions => '[
      {"action_name": "alarm_switch", "is_correct": true, "response_time_ms": 1200},
      {"action_name": "extinguisher_select", "is_correct": false, "response_time_ms": 3400, "mistake_tag": "wrong_extinguisher_class"}
    ]'::JSONB
  );

  v_session_id := (v_res->>'session_id')::UUID;
  v_cert_code := v_res->'certificate'->>'cert_code';

  -- Assertions on session result
  IF (v_res->>'already_synced')::BOOLEAN <> FALSE THEN
    RAISE EXCEPTION 'TEST 1 FAILED: already_synced should be false on first sync.';
  END IF;

  IF (v_res->>'stars')::INT <> 2 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Score 88 must yield 2 stars, got %', v_res->>'stars';
  END IF;

  IF (v_res->>'passed')::BOOLEAN <> TRUE THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Score 88 must be passed = true.';
  END IF;

  IF v_cert_code IS NULL OR v_cert_code NOT LIKE 'SK-%' THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Certificate was not issued properly.';
  END IF;

  -- Verify actions inserted
  SELECT COUNT(*) INTO v_action_count FROM training_actions WHERE session_id = v_session_id;
  IF v_action_count <> 2 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Expected 2 training actions, found %', v_action_count;
  END IF;

  -- Verify worker safety score and streak updated
  SELECT safety_score, current_streak INTO v_safety_score, v_streak
  FROM workers WHERE id = '11111111-1111-1111-1111-111111111111';

  IF v_safety_score <> 88 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Expected safety score 88, got %', v_safety_score;
  END IF;

  IF v_streak <> 1 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: Expected streak 1, got %', v_streak;
  END IF;

  RAISE NOTICE 'TEST 1 PASSED: Passing session synced with cert % and safety_score %', v_cert_code, v_safety_score;
END $$;

-- -----------------------------------------------------------------------------
-- TEST 2: Idempotent Sync (Re-syncing 'local-sess-uuid-001')
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_res JSONB;
  v_session_count INT;
  v_cert_count INT;
BEGIN
  v_res := sync_training_session(
    p_module => 'fire',
    p_difficulty => 'hard',
    p_score => 88,
    p_local_session_id => 'local-sess-uuid-001'
  );

  IF (v_res->>'already_synced')::BOOLEAN <> TRUE THEN
    RAISE EXCEPTION 'TEST 2 FAILED: Expected already_synced = true on duplicate sync.';
  END IF;

  -- Ensure no duplicate sessions
  SELECT COUNT(*) INTO v_session_count
  FROM training_sessions
  WHERE worker_id = '11111111-1111-1111-1111-111111111111'
    AND local_session_id = 'local-sess-uuid-001';

  IF v_session_count <> 1 THEN
    RAISE EXCEPTION 'TEST 2 FAILED: Duplicate session created in training_sessions!';
  END IF;

  -- Ensure no duplicate certificates
  SELECT COUNT(*) INTO v_cert_count
  FROM certificates
  WHERE worker_id = '11111111-1111-1111-1111-111111111111';

  IF v_cert_count <> 1 THEN
    RAISE EXCEPTION 'TEST 2 FAILED: Duplicate certificate created!';
  END IF;

  RAISE NOTICE 'TEST 2 PASSED: Duplicate sync was completely idempotent.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 3: Sync Failed Session (Gas leak, score 45 -> 0 stars, passed=FALSE)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_res JSONB;
  v_safety_score INT;
BEGIN
  v_res := sync_training_session(
    p_module => 'gas_leak',
    p_difficulty => 'medium',
    p_score => 45,
    p_local_session_id => 'local-sess-uuid-002',
    p_actions => '[
      {"action_name": "detector_check", "is_correct": false, "mistake_tag": "delayed_reading"}
    ]'::JSONB
  );

  IF (v_res->>'passed')::BOOLEAN <> FALSE THEN
    RAISE EXCEPTION 'TEST 3 FAILED: Score 45 must be passed = false.';
  END IF;

  IF (v_res->>'stars')::INT <> 0 THEN
    RAISE EXCEPTION 'TEST 3 FAILED: Score 45 must yield 0 stars.';
  END IF;

  IF v_res->'certificate' IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 3 FAILED: Certificate must NOT be issued for failed sessions.';
  END IF;

  -- Safety score should remain 88 because only passed sessions count
  SELECT safety_score INTO v_safety_score
  FROM workers WHERE id = '11111111-1111-1111-1111-111111111111';

  IF v_safety_score <> 88 THEN
    RAISE EXCEPTION 'TEST 3 FAILED: Failed session corrupted safety score! Expected 88, got %', v_safety_score;
  END IF;

  RAISE NOTICE 'TEST 3 PASSED: Failed session recorded with 0 stars and no cert.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 4: Online Certificate Verification (verify_certificate)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE anon;
SET LOCAL "request.jwt.claim.sub" = '';

DO $$
DECLARE
  v_cert_code TEXT;
  v_found_code TEXT;
  v_is_valid BOOLEAN;
  v_worker_name TEXT;
BEGIN
  SELECT cert_code INTO v_cert_code
  FROM certificates
  WHERE worker_id = '11111111-1111-1111-1111-111111111111'
  LIMIT 1;

  SELECT cert_code, worker_name, is_valid
  INTO v_found_code, v_worker_name, v_is_valid
  FROM verify_certificate(v_cert_code);

  IF v_found_code IS NULL OR v_found_code <> v_cert_code THEN
    RAISE EXCEPTION 'TEST 4 FAILED: verify_certificate could not locate cert %', v_cert_code;
  END IF;

  IF v_is_valid <> TRUE THEN
    RAISE EXCEPTION 'TEST 4 FAILED: Newly issued cert must be valid.';
  END IF;

  IF v_worker_name <> 'Sync Worker One' THEN
    RAISE EXCEPTION 'TEST 4 FAILED: Worker name mismatch, got %', v_worker_name;
  END IF;

  RAISE NOTICE 'TEST 4 PASSED: verify_certificate successfully validated cert %', v_cert_code;
END $$;

-- -----------------------------------------------------------------------------
-- TEST 5: Offline QR Hash Determinism
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_cert RECORD;
  v_computed_hash TEXT;
BEGIN
  SELECT * INTO v_cert
  FROM certificates
  WHERE worker_id = '11111111-1111-1111-1111-111111111111'
  LIMIT 1;

  v_computed_hash := generate_qr_hash(v_cert.cert_code, v_cert.worker_id, v_cert.module, v_cert.score);

  IF v_computed_hash <> v_cert.qr_hash THEN
    RAISE EXCEPTION 'TEST 5 FAILED: QR hash mismatch! Computed: %, Stored: %', v_computed_hash, v_cert.qr_hash;
  END IF;

  RAISE NOTICE 'TEST 5 PASSED: Offline QR hash matches stored hash.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 6: RLS on training_actions (Worker isolation & Supervisor mine scope)
-- -----------------------------------------------------------------------------
-- Worker One sees their own actions
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111111';

DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM training_actions;
  IF v_count < 2 THEN
    RAISE EXCEPTION 'TEST 6a FAILED: Worker One could not read their own training actions.';
  END IF;
  RAISE NOTICE 'TEST 6a PASSED: Worker One read own actions.';
END $$;

-- Worker Two cannot see Worker One's actions
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '22222222-2222-2222-2222-222222222222';

DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM training_actions;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 6b FAILED: Worker Two was able to view Worker One training actions!';
  END IF;
  RAISE NOTICE 'TEST 6b PASSED: Worker Two isolated from Worker One actions.';
END $$;

-- Supervisor Alpha (Mine Alpha) can see Worker One's actions
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '33333333-3333-3333-3333-333333333333';

DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM training_actions;
  IF v_count < 2 THEN
    RAISE EXCEPTION 'TEST 6c FAILED: Supervisor Alpha could not see actions of Worker One.';
  END IF;
  RAISE NOTICE 'TEST 6c PASSED: Supervisor Alpha viewed actions for their mine.';
END $$;

-- Supervisor Beta (Mine Beta) cannot see Worker One's actions
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '44444444-4444-4444-4444-444444444444';

DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM training_actions;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 6d FAILED: Supervisor Beta saw actions of worker in Mine Alpha!';
  END IF;
  RAISE NOTICE 'TEST 6d PASSED: Supervisor Beta correctly blocked from other mine actions.';
END $$;

ROLLBACK;
