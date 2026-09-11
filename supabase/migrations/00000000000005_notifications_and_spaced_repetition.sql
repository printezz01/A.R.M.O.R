-- =============================================================================
-- A.R.M.O.R — Phase 5: Supabase Notifications & Spaced Repetition
-- Migration: 00000000000005_notifications_and_spaced_repetition.sql
-- =============================================================================
-- Features:
--   1. Notification type enum (drill_alert, spaced_repetition, cert_expiry, etc.)
--   2. Table: notifications (worker-targeted alerts with read/unread tracking)
--   3. Supabase Realtime enabled on notifications for live in-app streaming
--   4. Table: spaced_repetition_schedules (server-side review interval tracking)
--   5. RPC: get_my_notifications (worker notification feed & reconnect sync)
--   6. RPC: mark_notification_read & mark_all_notifications_read
--   7. RPC: broadcast_drill_alert (supervisor mine-wide live drill alarm)
--   8. RPC: schedule_spaced_repetition_review (tracks errors into review queue)
--   9. RPC: generate_spaced_repetition_reminders (evaluates due reviews)
--  10. RPC: generate_certificate_expiry_reminders (30-day recertification alert)
-- =============================================================================

-- =============================================================================
-- 1. ENUM: notification_type
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_type') THEN
    CREATE TYPE public.notification_type AS ENUM (
      'drill_alert',
      'spaced_repetition',
      'cert_expiry',
      'streak_reminder',
      'system_announcement'
    );
  END IF;
END $$;

-- =============================================================================
-- 2. TABLE: notifications
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.notifications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id   UUID NOT NULL REFERENCES public.workers (id) ON DELETE CASCADE,
  mine_id     UUID REFERENCES public.mines (id) ON DELETE CASCADE,
  type        public.notification_type NOT NULL,
  title       TEXT NOT NULL,
  body        TEXT NOT NULL,
  payload     JSONB NOT NULL DEFAULT '{}'::JSONB,
  is_read     BOOLEAN NOT NULL DEFAULT FALSE,
  read_at     TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_worker_id  ON public.notifications (worker_id);
CREATE INDEX IF NOT EXISTS idx_notifications_unread     ON public.notifications (worker_id, is_read) WHERE is_read = FALSE;
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON public.notifications (created_at DESC);

-- =============================================================================
-- 3. TABLE: spaced_repetition_schedules
-- Tracks individual mistake areas and schedules recurring micro-reviews.
-- Intervals expand over time: 1d -> 3d -> 7d -> 14d -> 30d.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.spaced_repetition_schedules (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id         UUID NOT NULL REFERENCES public.workers (id) ON DELETE CASCADE,
  module            public.training_module NOT NULL,
  mistake_tag       TEXT NOT NULL,
  interval_days     INTEGER NOT NULL DEFAULT 1,
  next_review_due   TIMESTAMPTZ NOT NULL,
  review_count      INTEGER NOT NULL DEFAULT 0,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  last_reviewed_at  TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_worker_module_mistake UNIQUE (worker_id, module, mistake_tag)
);

CREATE INDEX IF NOT EXISTS idx_spaced_rep_worker ON public.spaced_repetition_schedules (worker_id);
CREATE INDEX IF NOT EXISTS idx_spaced_rep_due    ON public.spaced_repetition_schedules (next_review_due) WHERE is_active = TRUE;

-- =============================================================================
-- 4. REALTIME PUBLICATION: notifications
-- Enable live broadcast of new notification inserts to connected mobile clients.
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND tablename = 'notifications'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
    END IF;
  END IF;
END $$;

-- =============================================================================
-- 5. RLS: notifications
-- =============================================================================

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Worker reads own notifications
CREATE POLICY "notifications_select_own"
  ON public.notifications FOR SELECT TO authenticated
  USING (auth.uid() = worker_id);

-- Worker updates own read status
CREATE POLICY "notifications_update_own"
  ON public.notifications FOR UPDATE TO authenticated
  USING (auth.uid() = worker_id)
  WITH CHECK (auth.uid() = worker_id);

-- Supervisor reads notifications sent to workers in their mine
CREATE POLICY "notifications_select_supervisor"
  ON public.notifications FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      JOIN public.workers w ON w.id = notifications.worker_id
      WHERE s.id = auth.uid()
        AND s.mine_id = w.mine_id
        AND s.is_active = TRUE
    )
  );

-- Supervisor can create notifications for workers in their mine
CREATE POLICY "notifications_insert_supervisor"
  ON public.notifications FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      JOIN public.workers w ON w.id = notifications.worker_id
      WHERE s.id = auth.uid()
        AND s.mine_id = w.mine_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspector and admin read/manage all notifications
CREATE POLICY "notifications_all_dgms_admin"
  ON public.notifications FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- Service role full access
CREATE POLICY "notifications_service_role"
  ON public.notifications FOR ALL TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- =============================================================================
-- 6. RLS: spaced_repetition_schedules
-- =============================================================================

ALTER TABLE public.spaced_repetition_schedules ENABLE ROW LEVEL SECURITY;

-- Worker reads own review schedules
CREATE POLICY "spaced_rep_select_own"
  ON public.spaced_repetition_schedules FOR SELECT TO authenticated
  USING (auth.uid() = worker_id);

-- Supervisor reads review schedules for workers in their mine
CREATE POLICY "spaced_rep_select_supervisor"
  ON public.spaced_repetition_schedules FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      JOIN public.workers w ON w.id = spaced_repetition_schedules.worker_id
      WHERE s.id = auth.uid()
        AND s.mine_id = w.mine_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspector and admin read all review schedules
CREATE POLICY "spaced_rep_all_dgms_admin"
  ON public.spaced_repetition_schedules FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- Service role full access
CREATE POLICY "spaced_rep_service_role"
  ON public.spaced_repetition_schedules FOR ALL TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- =============================================================================
-- 7. RPC: get_my_notifications(...)
-- Called by the worker upon app open or reconnecting to network.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_my_notifications(
  p_unread_only BOOLEAN DEFAULT FALSE,
  p_limit       INT DEFAULT 30,
  p_offset      INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_worker_id     UUID;
  v_unread_count  INT;
  v_notifications JSONB;
BEGIN
  v_worker_id := auth.uid();
  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  -- Total unread count for badge indicator
  SELECT COUNT(*) INTO v_unread_count
  FROM public.notifications
  WHERE worker_id = v_worker_id AND is_read = FALSE;

  -- Notifications list
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', n.id,
        'type', n.type::TEXT,
        'title', n.title,
        'body', n.body,
        'payload', n.payload,
        'is_read', n.is_read,
        'read_at', n.read_at,
        'created_at', n.created_at
      )
      ORDER BY n.created_at DESC
    ),
    '[]'::JSONB
  ) INTO v_notifications
  FROM (
    SELECT *
    FROM public.notifications
    WHERE worker_id = v_worker_id
      AND (NOT p_unread_only OR is_read = FALSE)
    ORDER BY created_at DESC
    LIMIT GREATEST(p_limit, 1)
    OFFSET GREATEST(p_offset, 0)
  ) n;

  RETURN jsonb_build_object(
    'unread_count', v_unread_count,
    'notifications', v_notifications
  );
END;
$$;

-- =============================================================================
-- 8. RPC: mark_notification_read(p_notification_id UUID)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.mark_notification_read(p_notification_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_worker_id UUID;
BEGIN
  v_worker_id := auth.uid();
  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  UPDATE public.notifications
  SET is_read = TRUE,
      read_at = NOW()
  WHERE id = p_notification_id AND worker_id = v_worker_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOTIFICATION_NOT_FOUND: Notification not found or not owned by caller.';
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'notification_id', p_notification_id,
    'read_at', NOW()
  );
END;
$$;

-- =============================================================================
-- 9. RPC: mark_all_notifications_read()
-- =============================================================================

CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_worker_id UUID;
  v_count     INT;
BEGIN
  v_worker_id := auth.uid();
  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  WITH updated AS (
    UPDATE public.notifications
    SET is_read = TRUE,
        read_at = NOW()
    WHERE worker_id = v_worker_id AND is_read = FALSE
    RETURNING id
  )
  SELECT COUNT(*) INTO v_count FROM updated;

  RETURN jsonb_build_object(
    'success', TRUE,
    'marked_read_count', v_count
  );
END;
$$;

-- =============================================================================
-- 10. RPC: broadcast_drill_alert(p_drill_id UUID)
-- Dispatches a live emergency drill alert to ALL workers in the supervisor's mine.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.broadcast_drill_alert(p_drill_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_supervisor_id   UUID;
  v_supervisor_mine UUID;
  v_role            TEXT;
  v_drill           RECORD;
  v_broadcast_count INT;
BEGIN
  v_supervisor_id := auth.uid();
  IF v_supervisor_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in.';
  END IF;

  SELECT mine_id, role::TEXT INTO v_supervisor_mine, v_role
  FROM public.supervisors
  WHERE id = v_supervisor_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Supervisor access only.';
  END IF;

  -- Locate drill and verify mine scope
  SELECT id, mine_id, title, drill_type, scheduled_date, status
  INTO v_drill
  FROM public.emergency_drills
  WHERE id = p_drill_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DRILL_NOT_FOUND: Emergency drill not found.';
  END IF;

  IF v_role NOT IN ('dgms_inspector', 'admin') AND v_drill.mine_id <> v_supervisor_mine THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Cannot broadcast drill alerts for another mine.';
  END IF;

  -- Insert notifications for all active workers in target mine
  -- Supabase Realtime streams these inserts instantly to all online worker devices
  WITH inserted AS (
    INSERT INTO public.notifications (
      worker_id,
      mine_id,
      type,
      title,
      body,
      payload
    )
    SELECT
      w.id,
      v_drill.mine_id,
      'drill_alert'::public.notification_type,
      '🚨 EMERGENCY DRILL ALERT: ' || v_drill.title,
      'Mandatory ' || v_drill.drill_type::TEXT || ' drill scheduled on ' || v_drill.scheduled_date::TEXT || '. Open A.R.M.O.R. to review safety protocol.',
      jsonb_build_object(
        'drill_id', v_drill.id,
        'drill_type', v_drill.drill_type,
        'scheduled_date', v_drill.scheduled_date,
        'status', v_drill.status
      )
    FROM public.workers w
    WHERE w.mine_id = v_drill.mine_id AND w.is_active = TRUE
    RETURNING id
  )
  SELECT COUNT(*) INTO v_broadcast_count FROM inserted;

  RETURN jsonb_build_object(
    'success', TRUE,
    'drill_id', v_drill.id,
    'broadcast_count', v_broadcast_count,
    'mine_id', v_drill.mine_id,
    'broadcast_at', NOW()
  );
END;
$$;

-- =============================================================================
-- 11. FUNCTION: schedule_spaced_repetition_review
-- Tracks weak area into review schedule with expanding intervals.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.schedule_spaced_repetition_review(
  p_worker_id    UUID,
  p_module       public.training_module,
  p_mistake_tag  TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_clean_tag TEXT;
BEGIN
  v_clean_tag := TRIM(p_mistake_tag);
  IF v_clean_tag IS NULL OR v_clean_tag = '' THEN
    RETURN;
  END IF;

  INSERT INTO public.spaced_repetition_schedules (
    worker_id,
    module,
    mistake_tag,
    interval_days,
    next_review_due,
    review_count,
    is_active
  ) VALUES (
    p_worker_id,
    p_module,
    v_clean_tag,
    1,
    NOW() + INTERVAL '1 day',
    0,
    TRUE
  )
  ON CONFLICT (worker_id, module, mistake_tag)
  DO UPDATE SET
    -- Advance interval: 1 -> 3 -> 7 -> 14 -> 30
    interval_days = CASE
      WHEN spaced_repetition_schedules.interval_days = 1 THEN 3
      WHEN spaced_repetition_schedules.interval_days = 3 THEN 7
      WHEN spaced_repetition_schedules.interval_days = 7 THEN 14
      ELSE 30
    END,
    next_review_due = NOW() + (
      CASE
        WHEN spaced_repetition_schedules.interval_days = 1 THEN 3
        WHEN spaced_repetition_schedules.interval_days = 3 THEN 7
        WHEN spaced_repetition_schedules.interval_days = 7 THEN 14
        ELSE 30
      END || ' days'
    )::INTERVAL,
    review_count = spaced_repetition_schedules.review_count + 1,
    is_active = TRUE,
    updated_at = NOW();
END;
$$;

-- =============================================================================
-- 12. RPC: generate_spaced_repetition_reminders()
-- Generates in-app notifications for due reviews.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.generate_spaced_repetition_reminders()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_sched       RECORD;
  v_reminders   INT := 0;
BEGIN
  FOR v_sched IN
    SELECT s.id, s.worker_id, s.module, s.mistake_tag, w.mine_id, w.full_name
    FROM public.spaced_repetition_schedules s
    JOIN public.workers w ON w.id = s.worker_id
    WHERE s.is_active = TRUE
      AND s.next_review_due <= NOW()
      AND w.is_active = TRUE
      -- Avoid spamming: do not create if an unread reminder for this tag already exists
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.worker_id = s.worker_id
          AND n.type = 'spaced_repetition'
          AND n.payload->>'mistake_tag' = s.mistake_tag
          AND n.is_read = FALSE
      )
  LOOP
    INSERT INTO public.notifications (
      worker_id,
      mine_id,
      type,
      title,
      body,
      payload
    ) VALUES (
      v_sched.worker_id,
      v_sched.mine_id,
      'spaced_repetition',
      '🎯 Quick Safety Review: ' || INITCAP(v_sched.module::TEXT),
      'Time for a 2-minute refresher on: ' || REPLACE(v_sched.mistake_tag, '_', ' ') || '. Keep your survival streak sharp!',
      jsonb_build_object(
        'schedule_id', v_sched.id,
        'module', v_sched.module,
        'mistake_tag', v_sched.mistake_tag
      )
    );

    UPDATE public.spaced_repetition_schedules
    SET last_reviewed_at = NOW(),
        updated_at = NOW()
    WHERE id = v_sched.id;

    v_reminders := v_reminders + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'success', TRUE,
    'reminders_generated', v_reminders,
    'generated_at', NOW()
  );
END;
$$;

-- =============================================================================
-- 13. RPC: generate_certificate_expiry_reminders()
-- Generates in-app notifications for certificates expiring within 30 days.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.generate_certificate_expiry_reminders()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cert        RECORD;
  v_alerts      INT := 0;
BEGIN
  FOR v_cert IN
    SELECT c.id, c.cert_code, c.worker_id, c.module, c.expires_at, w.mine_id,
           EXTRACT(DAY FROM (c.expires_at - NOW()))::INT AS days_remaining
    FROM public.certificates c
    JOIN public.workers w ON w.id = c.worker_id
    WHERE c.expires_at BETWEEN NOW() AND NOW() + INTERVAL '30 days'
      AND NOT c.is_revoked
      AND w.is_active = TRUE
      -- Avoid duplicate notification within 7 days
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.worker_id = c.worker_id
          AND n.type = 'cert_expiry'
          AND n.payload->>'cert_code' = c.cert_code
          AND n.created_at > NOW() - INTERVAL '7 days'
      )
  LOOP
    INSERT INTO public.notifications (
      worker_id,
      mine_id,
      type,
      title,
      body,
      payload
    ) VALUES (
      v_cert.worker_id,
      v_cert.mine_id,
      'cert_expiry',
      '⚠️ Certificate Expiring in ' || v_cert.days_remaining::TEXT || ' Days',
      'Your ' || v_cert.module::TEXT || ' safety training certificate (' || v_cert.cert_code || ') expires on ' || v_cert.expires_at::DATE::TEXT || '. Retrain now to maintain compliance.',
      jsonb_build_object(
        'cert_id', v_cert.id,
        'cert_code', v_cert.cert_code,
        'module', v_cert.module,
        'expires_at', v_cert.expires_at,
        'days_remaining', v_cert.days_remaining
      )
    );

    v_alerts := v_alerts + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'success', TRUE,
    'expiry_alerts_generated', v_alerts,
    'generated_at', NOW()
  );
END;
$$;
