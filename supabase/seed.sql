-- =============================================================================
-- A.R.M.O.R — Seed Data (Synthetic / Development Only)
-- File: supabase/seed.sql
-- =============================================================================
-- All data is synthetic. Phone numbers and worker IDs are fictional.
-- Mine incident counts are inspired by DGMS annual report patterns
-- but are NOT exact historical figures.
-- =============================================================================

-- =============================================================================
-- MINES — 10 major Jharkhand mines/plants
-- =============================================================================

INSERT INTO mines (id, name, district, state, type, latitude, longitude, worker_count, fire_incidents_3yr, gas_incidents_3yr, electrical_incidents_3yr, is_active)
VALUES
  -- Coal mines (high fire/gas risk)
  ('a1b2c3d4-0001-0001-0001-000000000001', 'Jharia Coalfield', 'Dhanbad', 'Jharkhand', 'coal', 23.7793, 86.4268, 2400, 12, 5, 2, TRUE),
  ('a1b2c3d4-0002-0002-0002-000000000002', 'BCCL Bastacolla Colliery', 'Dhanbad', 'Jharkhand', 'coal', 23.7956, 86.4621, 1800, 8, 6, 1, TRUE),
  ('a1b2c3d4-0003-0003-0003-000000000003', 'ECL Rajmahal Area', 'Godda', 'Jharkhand', 'coal', 24.6512, 87.8425, 950, 4, 3, 2, TRUE),
  ('a1b2c3d4-0004-0004-0004-000000000004', 'CCL Kathara Colliery', 'Bokaro', 'Jharkhand', 'coal', 23.7214, 85.9453, 1200, 6, 7, 3, TRUE),
  ('a1b2c3d4-0005-0005-0005-000000000005', 'CCL Hazaribagh Area', 'Hazaribagh', 'Jharkhand', 'coal', 23.9915, 85.3632, 780, 2, 1, 4, TRUE),

  -- Steel plants (moderate fire, lower gas risk)
  ('a1b2c3d4-0006-0006-0006-000000000006', 'Tata Steel Jamshedpur', 'East Singhbhum', 'Jharkhand', 'steel', 22.8046, 86.2029, 35000, 5, 1, 8, TRUE),
  ('a1b2c3d4-0007-0007-0007-000000000007', 'SAIL Bokaro Steel Plant', 'Bokaro', 'Jharkhand', 'steel', 23.6693, 86.1511, 18000, 3, 0, 9, TRUE),

  -- Uranium mine (radiation + gas risk)
  ('a1b2c3d4-0008-0008-0008-000000000008', 'UCIL Jaduguda Uranium Mine', 'East Singhbhum', 'Jharkhand', 'uranium', 22.6592, 86.3496, 640, 2, 4, 3, TRUE),

  -- Mica mines (lower incident rates but still active)
  ('a1b2c3d4-0009-0009-0009-000000000009', 'Koderma Mica Belt', 'Koderma', 'Jharkhand', 'mica', 24.4634, 85.5969, 320, 1, 0, 1, TRUE),
  ('a1b2c3d4-0010-0010-0010-000000000010', 'Giridih Mica Mines', 'Giridih', 'Jharkhand', 'mica', 24.1882, 86.3001, 280, 1, 0, 2, TRUE)
;

-- =============================================================================
-- WORKERS — 5 synthetic worker profiles (NO real phone numbers)
-- IDs are placeholder UUIDs — in production, id = auth.users.id
-- =============================================================================

INSERT INTO workers (id, phone, full_name, mine_id, language, safety_score, current_streak, longest_streak, last_trained_at, badges, is_active)
VALUES
  (
    'b1b2c3d4-1001-1001-1001-000000000001',
    '+919900000001',
    'Raju Hembram',
    'a1b2c3d4-0001-0001-0001-000000000001',  -- Jharia Coalfield
    'sat',
    82,
    3,
    5,
    NOW() - INTERVAL '1 day',
    ARRAY['first_responder', 'fire_fighter'],
    TRUE
  ),
  (
    'b1b2c3d4-1002-1002-1002-000000000002',
    '+919900000002',
    'Suresh Mahto',
    'a1b2c3d4-0001-0001-0001-000000000001',  -- Jharia Coalfield
    'hi',
    65,
    1,
    3,
    NOW() - INTERVAL '2 days',
    ARRAY['first_responder'],
    TRUE
  ),
  (
    'b1b2c3d4-1003-1003-1003-000000000003',
    '+919900000003',
    'Lalita Devi',
    'a1b2c3d4-0002-0002-0002-000000000002',  -- BCCL Bastacolla
    'hi',
    91,
    7,
    12,
    NOW() - INTERVAL '1 day',
    ARRAY['first_responder', 'fire_marshal', 'gas_guardian', 'streak_7'],
    TRUE
  ),
  (
    'b1b2c3d4-1004-1004-1004-000000000004',
    '+919900000004',
    'Prakash Oraon',
    'a1b2c3d4-0004-0004-0004-000000000004',  -- CCL Kathara
    'en',
    48,
    0,
    2,
    NOW() - INTERVAL '5 days',
    ARRAY['first_responder'],
    TRUE
  ),
  (
    'b1b2c3d4-1005-1005-1005-000000000005',
    '+919900000005',
    'Anita Tudu',
    'a1b2c3d4-0003-0003-0003-000000000003',  -- ECL Rajmahal
    'sat',
    0,
    0,
    0,
    NULL,
    ARRAY[]::TEXT[],
    TRUE
  )
;

-- =============================================================================
-- TRAINING SESSIONS — Sample completed sessions for demo workers
-- =============================================================================

INSERT INTO training_sessions (id, worker_id, mine_id, module, difficulty, score, stars, passed, weak_areas, levels_completed, duration_seconds, synced_from_local, created_at)
VALUES
  -- Raju: Fire training (hard mode - Jharia has 12 fire incidents)
  (
    'c1c2c3d4-2001-2001-2001-000000000001',
    'b1b2c3d4-1001-1001-1001-000000000001',
    'a1b2c3d4-0001-0001-0001-000000000001',
    'fire', 'hard', 78, 2, TRUE,
    ARRAY['ppe_selection', 'extinguisher_type'],
    3, 960, TRUE,
    NOW() - INTERVAL '4 days'
  ),
  -- Raju: Gas leak training (medium mode - Jharia has 5 gas incidents)
  (
    'c1c2c3d4-2002-2002-2002-000000000002',
    'b1b2c3d4-1001-1001-1001-000000000001',
    'a1b2c3d4-0001-0001-0001-000000000001',
    'gas_leak', 'medium', 86, 2, TRUE,
    ARRAY['evacuation_route'],
    2, 720, TRUE,
    NOW() - INTERVAL '4 days'
  ),
  -- Raju: Fire re-attempt (improved score)
  (
    'c1c2c3d4-2003-2003-2003-000000000003',
    'b1b2c3d4-1001-1001-1001-000000000001',
    'a1b2c3d4-0001-0001-0001-000000000001',
    'fire', 'hard', 92, 3, TRUE,
    ARRAY[]::TEXT[],
    3, 840, FALSE,
    NOW() - INTERVAL '1 day'
  ),

  -- Suresh: Fire only (partial progress)
  (
    'c1c2c3d4-2004-2004-2004-000000000004',
    'b1b2c3d4-1002-1002-1002-000000000002',
    'a1b2c3d4-0001-0001-0001-000000000001',
    'fire', 'hard', 65, 1, TRUE,
    ARRAY['alarm_first', 'ppe_selection'],
    2, 1140, TRUE,
    NOW() - INTERVAL '2 days'
  ),

  -- Lalita: Fire (hard mode - BCCL has 8 fire incidents)
  (
    'c1c2c3d4-2005-2005-2005-000000000005',
    'b1b2c3d4-1003-1003-1003-000000000003',
    'a1b2c3d4-0002-0002-0002-000000000002',
    'fire', 'hard', 95, 3, TRUE,
    ARRAY[]::TEXT[],
    3, 660, TRUE,
    NOW() - INTERVAL '10 days'
  ),
  -- Lalita: Gas leak (hard mode - BCCL has 6 gas incidents = medium)
  (
    'c1c2c3d4-2006-2006-2006-000000000006',
    'b1b2c3d4-1003-1003-1003-000000000003',
    'a1b2c3d4-0002-0002-0002-000000000002',
    'gas_leak', 'medium', 88, 2, TRUE,
    ARRAY[]::TEXT[],
    2, 590, TRUE,
    NOW() - INTERVAL '9 days'
  ),

  -- Prakash: Fire (medium mode - CCL Kathara has 6 fire incidents = medium)
  (
    'c1c2c3d4-2007-2007-2007-000000000007',
    'b1b2c3d4-1004-1004-1004-000000000004',
    'a1b2c3d4-0004-0004-0004-000000000004',
    'fire', 'medium', 48, 0, FALSE,
    ARRAY['alarm_first', 'ppe_selection', 'evacuation_route'],
    1, 1320, TRUE,
    NOW() - INTERVAL '5 days'
  )
;

-- =============================================================================
-- CERTIFICATES — For workers who passed modules
-- =============================================================================

INSERT INTO certificates (id, cert_code, worker_id, session_id, module, score, issued_at, expires_at, qr_hash, is_revoked)
VALUES
  -- Raju: Fire certificate (based on latest best attempt)
  (
    'd1d2d3d4-3001-3001-3001-000000000001',
    'SK-2026-JH-00001',
    'b1b2c3d4-1001-1001-1001-000000000001',
    'c1c2c3d4-2003-2003-2003-000000000003',
    'fire', 92,
    NOW() - INTERVAL '1 day',
    NOW() - INTERVAL '1 day' + INTERVAL '1 year',
    encode(digest('SK-2026-JH-00001:b1b2c3d4-1001-1001-1001-000000000001:fire:92:seed', 'sha256'), 'hex'),
    FALSE
  ),
  -- Raju: Gas leak certificate
  (
    'd1d2d3d4-3002-3002-3002-000000000002',
    'SK-2026-JH-00002',
    'b1b2c3d4-1001-1001-1001-000000000001',
    'c1c2c3d4-2002-2002-2002-000000000002',
    'gas_leak', 86,
    NOW() - INTERVAL '4 days',
    NOW() - INTERVAL '4 days' + INTERVAL '1 year',
    encode(digest('SK-2026-JH-00002:b1b2c3d4-1001-1001-1001-000000000001:gas_leak:86:seed', 'sha256'), 'hex'),
    FALSE
  ),
  -- Suresh: Fire certificate
  (
    'd1d2d3d4-3003-3003-3003-000000000003',
    'SK-2026-JH-00003',
    'b1b2c3d4-1002-1002-1002-000000000002',
    'c1c2c3d4-2004-2004-2004-000000000004',
    'fire', 65,
    NOW() - INTERVAL '2 days',
    NOW() - INTERVAL '2 days' + INTERVAL '1 year',
    encode(digest('SK-2026-JH-00003:b1b2c3d4-1002-1002-1002-000000000002:fire:65:seed', 'sha256'), 'hex'),
    FALSE
  ),
  -- Lalita: Fire certificate
  (
    'd1d2d3d4-3004-3004-3004-000000000004',
    'SK-2026-JH-00004',
    'b1b2c3d4-1003-1003-1003-000000000003',
    'c1c2c3d4-2005-2005-2005-000000000005',
    'fire', 95,
    NOW() - INTERVAL '10 days',
    NOW() - INTERVAL '10 days' + INTERVAL '1 year',
    encode(digest('SK-2026-JH-00004:b1b2c3d4-1003-1003-1003-000000000003:fire:95:seed', 'sha256'), 'hex'),
    FALSE
  ),
  -- Lalita: Gas leak certificate
  (
    'd1d2d3d4-3005-3005-3005-000000000005',
    'SK-2026-JH-00005',
    'b1b2c3d4-1003-1003-1003-000000000003',
    'c1c2c3d4-2006-2006-2006-000000000006',
    'gas_leak', 88,
    NOW() - INTERVAL '9 days',
    NOW() - INTERVAL '9 days' + INTERVAL '1 year',
    encode(digest('SK-2026-JH-00005:b1b2c3d4-1003-1003-1003-000000000003:gas_leak:88:seed', 'sha256'), 'hex'),
    FALSE
  )
;