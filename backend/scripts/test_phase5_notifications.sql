-- =============================================================================
-- A.R.M.O.R — Phase 5: Supabase Notifications & Spaced Repetition Test Suite
-- File: backend/scripts/test_phase5_notifications.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. FIXTURES
-- -----------------------------------------------------------------------------

INSERT INTO mines (id, name, district, state, type, fire_incidents_3yr, gas_incidents_3yr, electrical_incidents_3yr, is_active)
VALUES 
  ('00000000-0000-0000-0000-0000000000a1', 'Test Mine Alpha', 'Dhanbad', 'Jharkhand', 'coal', 8, 3, 0, TRUE),
  ('00000000-0000-0000-0000-0000000000b2', 'Test Mine Beta', 'Bokaro', 'Jharkhand', 'steel', 2, 0, 0, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Workers in Mine Alpha
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111101', 'WKR-JH-9301', 'notif.worker.one', 'Notif Worker One', '00000000-0000-0000-0000-0000000000a1', 'hi', 85, TRUE),
  ('11111111-1111-1111-1111-111111111102', 'WKR-JH-9302', 'notif.worker.two', 'Notif Worker Two', '00000000-0000-0000-0000-0000000000a1', 'sat', 70, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Worker in Mine Beta
INSERT INTO workers (id, worker_code, username, full_name, mine_id, language, safety_score, is_active)
VALUES
  ('22222222-2222-2222-2222-222222222201', 'WKR-JH-9303', 'notif.worker.three', 'Notif Worker Three', '00000000-0000-0000-0000-0000000000b2', 'en', 60, TRUE)
ON CONFLICT (id) DO NOTHING;

-- Supervisors
INSERT INTO supervisors (id, username, full_name, mine_id, role, is_active)
VALUES
  ('33333333-3333-3333-3333-333333333301', 'sup.alpha', 'Supervisor Alpha', '00000000-0000-0000-0000-0000000000a1', 'supervisor', TRUE),
  ('33333333-3333-3333-3333-333333333302', 'sup.beta', 'Supervisor Beta', '00000000-0000-0000-0000-0000000000b2', 'supervisor', TRUE)
ON CONFLICT (id) DO NOTHING;

-- Drills
INSERT INTO emergency_drills (id, mine_id, title, drill_type, scheduled_date, status)
VALUES
  ('77777777-7777-7777-7777-777777777701', '00000000-0000-0000-0000-0000000000a1', 'Simulated Gas Leak Evacuation', 'gas_leak', CURRENT_DATE + INTERVAL '2 days', 'scheduled'),
  ('77777777-7777-7777-7777-777777777702', '00000000-0000-0000-0000-0000000000b2', 'Beta Fire Response', 'fire', CURRENT_DATE + INTERVAL '3 days', 'scheduled')
ON CONFLICT (id) DO NOTHING;

-- Expiring Certificate for Worker One (expires in 15 days)
INSERT INTO training_sessions (id, worker_id, mine_id, module, difficulty, score, stars, passed)
VALUES ('55555555-5555-5555-5555-555555555501', '11111111-1111-1111-1111-111111111101', '00000000-0000-0000-0000-0000000000a1', 'fire', 'hard', 92, 3, TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO certificates (id, cert_code, worker_id, session_id, module, score, issued_at, expires_at, qr_hash, is_revoked)
VALUES ('66666666-6666-6666-6666-666666666601', 'SK-2025-JH-88001', '11111111-1111-1111-1111-111111111101', '55555555-5555-5555-5555-555555555501', 'fire', 92, NOW() - INTERVAL '350 days', NOW() + INTERVAL '15 days', 'hash', FALSE)
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- TEST 1: Supervisor Alpha Broadcasts Drill Alert to Mine Alpha Workers
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '33333333-3333-3333-3333-333333333301';

DO $$
DECLARE
  v_res JSONB;
BEGIN
  v_res := broadcast_drill_alert('77777777-7777-7777-7777-777777777701');

  IF (v_res->>'broadcast_count')::INT <> 2 THEN
    RAISE EXCEPTION 'TEST 1a FAILED: Expected 2 workers in Mine Alpha to receive alert, got %', v_res->>'broadcast_count';
  END IF;

  -- Ensure Worker Three in Mine Beta received 0 notifications
  IF EXISTS (SELECT 1 FROM notifications WHERE worker_id = '22222222-2222-2222-2222-222222222201') THEN
    RAISE EXCEPTION 'TEST 1b FAILED: Worker Three in Mine Beta received an alert from Mine Alpha drill!';
  END IF;

  RAISE NOTICE 'TEST 1 PASSED: broadcast_drill_alert successfully targeted Mine Alpha workers.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 2: Supervisor Alpha Blocked from Broadcasting Other Mine Drill
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    PERFORM broadcast_drill_alert('77777777-7777-7777-7777-777777777702');
    RAISE EXCEPTION 'TEST 2 FAILED: Supervisor Alpha broadcasted alert for Mine Beta drill!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%UNAUTHORIZED%' THEN
      RAISE NOTICE 'TEST 2 PASSED: Cross-mine drill broadcast properly blocked.';
    ELSE
      RAISE EXCEPTION 'TEST 2 FAILED with unexpected error: %', SQLERRM;
    END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- TEST 3: Worker One Fetches Notifications (Unread Count & Feed)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111101';

DO $$
DECLARE
  v_res JSONB;
  v_notif_id UUID;
BEGIN
  v_res := get_my_notifications();

  IF (v_res->>'unread_count')::INT <> 1 THEN
    RAISE EXCEPTION 'TEST 3a FAILED: Expected 1 unread notification, got %', v_res->>'unread_count';
  END IF;

  IF v_res->'notifications'->0->>'type' <> 'drill_alert' THEN
    RAISE EXCEPTION 'TEST 3b FAILED: Notification type must be drill_alert.';
  END IF;

  RAISE NOTICE 'TEST 3 PASSED: get_my_notifications returned drill alert.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 4: Worker One Marks Notification as Read
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_notif_id UUID;
  v_res JSONB;
  v_check JSONB;
BEGIN
  SELECT id INTO v_notif_id FROM notifications WHERE worker_id = '11111111-1111-1111-1111-111111111101' LIMIT 1;

  v_res := mark_notification_read(v_notif_id);
  IF (v_res->>'success')::BOOLEAN <> TRUE THEN
    RAISE EXCEPTION 'TEST 4a FAILED: mark_notification_read returned false.';
  END IF;

  v_check := get_my_notifications();
  IF (v_check->>'unread_count')::INT <> 0 THEN
    RAISE EXCEPTION 'TEST 4b FAILED: Expected 0 unread notifications after read update.';
  END IF;

  RAISE NOTICE 'TEST 4 PASSED: mark_notification_read updated state.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 5: Worker Two Cannot Mark Worker One's Notification
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111102';

DO $$
DECLARE
  v_worker1_notif_id UUID;
BEGIN
  SELECT id INTO v_worker1_notif_id FROM notifications WHERE worker_id = '11111111-1111-1111-1111-111111111101' LIMIT 1;

  BEGIN
    PERFORM mark_notification_read(v_worker1_notif_id);
    RAISE EXCEPTION 'TEST 5 FAILED: Worker Two altered Worker One notification!';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%NOTIFICATION_NOT_FOUND%' THEN
      RAISE NOTICE 'TEST 5 PASSED: Cross-worker notification update blocked.';
    ELSE
      RAISE EXCEPTION 'TEST 5 FAILED with unexpected error: %', SQLERRM;
    END IF;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- TEST 6: Spaced Repetition Scheduling & Reminder Generation
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111101';

DO $$
DECLARE
  v_res JSONB;
  v_notif JSONB;
BEGIN
  -- Schedule a mistake for review
  PERFORM schedule_spaced_repetition_review('11111111-1111-1111-1111-111111111101', 'fire', 'delayed_alarm');

  -- Force next_review_due into past to simulate expiration
  UPDATE spaced_repetition_schedules
  SET next_review_due = NOW() - INTERVAL '1 hour'
  WHERE worker_id = '11111111-1111-1111-1111-111111111101';

  -- Trigger reminder generator
  v_res := generate_spaced_repetition_reminders();
  IF (v_res->>'reminders_generated')::INT < 1 THEN
    RAISE EXCEPTION 'TEST 6a FAILED: Expected at least 1 spaced reminder generated.';
  END IF;

  -- Worker One checks notification
  v_notif := get_my_notifications(p_unread_only => TRUE);
  IF (v_notif->>'unread_count')::INT <> 1 THEN
    RAISE EXCEPTION 'TEST 6b FAILED: Expected 1 unread reminder.';
  END IF;

  IF v_notif->'notifications'->0->>'type' <> 'spaced_repetition' THEN
    RAISE EXCEPTION 'TEST 6c FAILED: Expected type spaced_repetition, got %', v_notif->'notifications'->0->>'type';
  END IF;

  RAISE NOTICE 'TEST 6 PASSED: Spaced repetition schedule and reminder generated.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 7: Certificate Expiry Reminder Generation
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_res JSONB;
  v_notif JSONB;
BEGIN
  -- Trigger cert expiry generator
  v_res := generate_certificate_expiry_reminders();
  IF (v_res->>'expiry_alerts_generated')::INT < 1 THEN
    RAISE EXCEPTION 'TEST 7a FAILED: Expected at least 1 expiry alert generated.';
  END IF;

  -- Verify worker notification feed includes expiry alert
  v_notif := get_my_notifications(p_unread_only => TRUE);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_notif->'notifications') n WHERE n->>'type' = 'cert_expiry'
  ) THEN
    RAISE EXCEPTION 'TEST 7b FAILED: Expected cert_expiry notification in feed.';
  END IF;

  RAISE NOTICE 'TEST 7 PASSED: Certificate expiry reminder generated.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 8: Mark All Notifications Read
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_res JSONB;
  v_check JSONB;
BEGIN
  v_res := mark_all_notifications_read();
  IF (v_res->>'marked_read_count')::INT < 2 THEN
    RAISE EXCEPTION 'TEST 8a FAILED: Expected multiple notifications marked read.';
  END IF;

  v_check := get_my_notifications(p_unread_only => TRUE);
  IF (v_check->>'unread_count')::INT <> 0 THEN
    RAISE EXCEPTION 'TEST 8b FAILED: Expected 0 unread notifications after mark_all.';
  END IF;

  RAISE NOTICE 'TEST 8 PASSED: mark_all_notifications_read cleared unread count.';
END $$;

-- -----------------------------------------------------------------------------
-- TEST 9: RLS Isolation on notifications table
-- -----------------------------------------------------------------------------
-- Worker Two should only see 1 notification (the drill alert sent to them), not Worker One's 3 notifications
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111102';

DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM notifications;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST 9 FAILED: Worker Two saw % notifications instead of 1.', v_count;
  END IF;

  RAISE NOTICE 'TEST 9 PASSED: notifications table RLS strictly enforced.';
END $$;

ROLLBACK;
