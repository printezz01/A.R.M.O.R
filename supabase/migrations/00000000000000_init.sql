-- =============================================================================
-- A.R.M.O.R — Phase 1 Core Schema Migration (v2 — Revised)
-- Migration: 00000000000000_init.sql
-- Project:   ampqcpxpshaiiquqbmmn.supabase.co
-- Revised:   September 2026
-- Changes from v1:
--   - Auth: Phone OTP removed. Username/password is the locked auth model.
--     phone is now nullable optional contact data on workers and supervisors.
--   - workers: added worker_code (WKR-JH-XXXXX), username (for login),
--     removed badges TEXT[] (replaced by normalized badges/worker_badges tables)
--   - supervisors: added username, phone made nullable
--   - calculate_stars: corrected thresholds (60-74=1, 75-89=2, 90-100=3)
--   - update_worker_safety_score: uses AVG of all passed sessions per module,
--     then averages those module means (not MAX per module)
--   - cert_code / worker_code use dedicated sequences (no COUNT race conditions)
--   - Anonymous certificate verification: anon RLS on certificates removed;
--     replaced by a constrained SECURITY DEFINER function verify_certificate()
--     that returns only safe public fields by cert_code
-- =============================================================================

-- =============================================================================
-- EXTENSIONS
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- =============================================================================
-- SEQUENCES
-- =============================================================================

-- Sequential generator for human-readable worker codes (WKR-JH-0001)
CREATE SEQUENCE worker_code_seq START 1 INCREMENT 1 NO CYCLE;

-- Sequential generator for human-readable certificate codes (SK-2026-JH-00001)
CREATE SEQUENCE cert_code_seq START 1 INCREMENT 1 NO CYCLE;

-- =============================================================================
-- ENUMS
-- =============================================================================

CREATE TYPE mine_type AS ENUM (
  'coal',
  'steel',
  'mica',
  'uranium',
  'other'
);

CREATE TYPE language_code AS ENUM (
  'hi',    -- Hindi
  'sat',   -- Santali (Ol Chiki script)
  'en'     -- English
);

CREATE TYPE training_module AS ENUM (
  'fire',
  'gas_leak',
  'electrical'
);

CREATE TYPE difficulty_mode AS ENUM (
  'easy',
  'medium',
  'hard'
);

CREATE TYPE supervisor_role AS ENUM (
  'supervisor',
  'dgms_inspector',
  'admin'
);

-- =============================================================================
-- HELPER: updated_at trigger function
-- =============================================================================

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- HELPER: generate_worker_code
-- Returns WKR-JH-XXXX (zero-padded 4 digits, e.g. WKR-JH-0001)
-- Uses a dedicated sequence — no race conditions.
-- =============================================================================

CREATE OR REPLACE FUNCTION generate_worker_code()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN 'WKR-JH-' || LPAD(nextval('worker_code_seq')::TEXT, 4, '0');
END;
$$;

-- =============================================================================
-- HELPER: generate_cert_code
-- Returns SK-YYYY-JH-NNNNN (zero-padded 5 digits, e.g. SK-2026-JH-00001)
-- Uses a dedicated sequence — no race conditions.
-- =============================================================================

CREATE OR REPLACE FUNCTION generate_cert_code()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN 'SK-' || TO_CHAR(NOW(), 'YYYY') || '-JH-' || LPAD(nextval('cert_code_seq')::TEXT, 5, '0');
END;
$$;

-- =============================================================================
-- TABLE: mines
-- Static mine/plant metadata sourced from DGMS annual reports.
-- Managed by service_role only — workers/supervisors read-only.
-- =============================================================================

CREATE TABLE mines (
  id                        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                      TEXT        NOT NULL,
  district                  TEXT        NOT NULL,
  state                     TEXT        NOT NULL DEFAULT 'Jharkhand',
  type                      mine_type   NOT NULL,
  latitude                  NUMERIC(9, 6),
  longitude                 NUMERIC(9, 6),
  worker_count              INTEGER,
  -- Incident counts over the past 3 years (source: DGMS reports).
  -- These drive per-module training difficulty selection.
  fire_incidents_3yr        INTEGER     NOT NULL DEFAULT 0,
  gas_incidents_3yr         INTEGER     NOT NULL DEFAULT 0,
  electrical_incidents_3yr  INTEGER     NOT NULL DEFAULT 0,
  is_active                 BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER set_mines_updated_at
  BEFORE UPDATE ON mines
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE INDEX idx_mines_district   ON mines (district);
CREATE INDEX idx_mines_name_trgm  ON mines USING GIN (name gin_trgm_ops);
CREATE INDEX idx_mines_type       ON mines (type);

-- =============================================================================
-- TABLE: workers
-- One row per registered mine worker.
-- id = auth.users.id (Supabase internal UUID — the authoritative identity).
-- worker_code = human-readable system-generated ID (WKR-JH-XXXX).
-- username = login credential (username/password auth model).
-- phone = OPTIONAL contact data only — NOT used for authentication.
-- mine_id is nullable: a worker may register before being assigned to a mine.
-- Badges are fully normalized — see badges + worker_badges tables below.
-- =============================================================================

CREATE TABLE workers (
  id                UUID        PRIMARY KEY,  -- = auth.users.id
  worker_code       TEXT        NOT NULL UNIQUE DEFAULT generate_worker_code(),
  username          TEXT        NOT NULL UNIQUE,
  full_name         TEXT        NOT NULL,
  -- phone is optional contact data only. It is NOT used for login or OTP.
  phone             TEXT,
  mine_id           UUID        REFERENCES mines (id) ON DELETE SET NULL,  -- nullable at registration
  language          language_code NOT NULL DEFAULT 'hi',
  safety_score      INTEGER     NOT NULL DEFAULT 0 CHECK (safety_score BETWEEN 0 AND 100),
  current_streak    INTEGER     NOT NULL DEFAULT 0,
  longest_streak    INTEGER     NOT NULL DEFAULT 0,
  last_trained_at   TIMESTAMPTZ,
  avatar_url        TEXT,
  is_active         BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER set_workers_updated_at
  BEFORE UPDATE ON workers
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE INDEX idx_workers_mine_id      ON workers (mine_id);
CREATE INDEX idx_workers_username     ON workers (username);
CREATE INDEX idx_workers_worker_code  ON workers (worker_code);
CREATE INDEX idx_workers_safety_score ON workers (safety_score DESC);

-- =============================================================================
-- TABLE: supervisors
-- Dashboard users: safety officers, DGMS inspectors, system admins.
-- id = auth.users.id.
-- username = login credential (username/password auth model).
-- phone = OPTIONAL contact data only — NOT used for authentication.
-- =============================================================================

CREATE TABLE supervisors (
  id          UUID            PRIMARY KEY,  -- = auth.users.id
  username    TEXT            NOT NULL UNIQUE,
  full_name   TEXT            NOT NULL,
  -- phone is optional contact data only.
  phone       TEXT,
  mine_id     UUID            NOT NULL REFERENCES mines (id) ON DELETE RESTRICT,
  role        supervisor_role NOT NULL DEFAULT 'supervisor',
  is_active   BOOLEAN         NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER set_supervisors_updated_at
  BEFORE UPDATE ON supervisors
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE INDEX idx_supervisors_mine_id  ON supervisors (mine_id);
CREATE INDEX idx_supervisors_username ON supervisors (username);

-- =============================================================================
-- TABLE: training_sessions
-- Immutable record of each training attempt. Workers insert; no updates/deletes.
-- =============================================================================

CREATE TABLE training_sessions (
  id                UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id         UUID           NOT NULL REFERENCES workers (id) ON DELETE CASCADE,
  mine_id           UUID           NOT NULL REFERENCES mines (id) ON DELETE RESTRICT,
  module            training_module NOT NULL,
  difficulty        difficulty_mode NOT NULL,
  score             INTEGER        NOT NULL CHECK (score BETWEEN 0 AND 100),
  stars             SMALLINT       NOT NULL DEFAULT 0 CHECK (stars BETWEEN 0 AND 3),
  passed            BOOLEAN        NOT NULL DEFAULT FALSE,
  weak_areas        TEXT[],
  levels_completed  INTEGER        NOT NULL DEFAULT 0,
  duration_seconds  INTEGER,
  synced_from_local BOOLEAN        NOT NULL DEFAULT FALSE,
  -- Client-generated ID used for offline deduplication on sync.
  local_session_id  TEXT,
  created_at        TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- Deduplication: prevent double-insert when syncing the same offline session.
CREATE UNIQUE INDEX idx_training_sessions_local_dedup
  ON training_sessions (worker_id, local_session_id)
  WHERE local_session_id IS NOT NULL;

CREATE INDEX idx_training_sessions_worker_id  ON training_sessions (worker_id);
CREATE INDEX idx_training_sessions_mine_id    ON training_sessions (mine_id);
CREATE INDEX idx_training_sessions_module     ON training_sessions (module);
CREATE INDEX idx_training_sessions_created_at ON training_sessions (created_at DESC);

-- =============================================================================
-- TABLE: certificates
-- Verifiable, QR-signed training certificates.
-- Write access is service_role only (Phase 3 Edge Function).
-- Anonymous verification is handled exclusively via verify_certificate() function.
-- =============================================================================

CREATE TABLE certificates (
  id          UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  cert_code   TEXT           NOT NULL UNIQUE,  -- e.g. SK-2026-JH-00001
  worker_id   UUID           NOT NULL REFERENCES workers (id) ON DELETE CASCADE,
  session_id  UUID           NOT NULL REFERENCES training_sessions (id) ON DELETE RESTRICT,
  module      training_module NOT NULL,
  score       INTEGER        NOT NULL CHECK (score BETWEEN 0 AND 100),
  issued_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  expires_at  TIMESTAMPTZ    NOT NULL,
  -- SHA-256 hash of (cert_code || worker_id || module || score || CERT_HASH_SECRET)
  -- Used for offline QR verification without a network call.
  qr_hash     TEXT           NOT NULL,
  is_revoked  BOOLEAN        NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_certificates_worker_id  ON certificates (worker_id);
CREATE INDEX idx_certificates_cert_code  ON certificates (cert_code);
CREATE INDEX idx_certificates_module     ON certificates (module);
CREATE INDEX idx_certificates_expires_at ON certificates (expires_at);

-- =============================================================================
-- TABLE: badges
-- Normalized badge definitions — the catalogue of all earnable badges.
-- =============================================================================

CREATE TABLE badges (
  id              TEXT            PRIMARY KEY,  -- e.g. 'first_responder', 'fire_marshal'
  name            TEXT            NOT NULL,
  description     TEXT,
  icon_code       TEXT,                         -- emoji or app icon key
  module          training_module,              -- NULL = module-agnostic badge
  required_stars  SMALLINT        CHECK (required_stars BETWEEN 1 AND 3),
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- TABLE: worker_badges
-- Normalized junction: which badges has each worker earned?
-- UNIQUE(worker_id, badge_id) — each badge earned at most once per worker.
-- =============================================================================

CREATE TABLE worker_badges (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id   UUID        NOT NULL REFERENCES workers (id) ON DELETE CASCADE,
  badge_id    TEXT        NOT NULL REFERENCES badges (id) ON DELETE RESTRICT,
  earned_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_worker_badge UNIQUE (worker_id, badge_id)
);

CREATE INDEX idx_worker_badges_worker_id ON worker_badges (worker_id);
CREATE INDEX idx_worker_badges_badge_id  ON worker_badges (badge_id);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- get_difficulty_mode(incidents)
-- Returns the training difficulty enum value for a given incident count.
-- Thresholds per PRD: 8+ = hard (3 levels), 4-7 = medium (2 levels),
-- <4 = easy (still 2 levels — minimum is always Easy + Medium).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_difficulty_mode(incidents INTEGER)
RETURNS difficulty_mode
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF incidents >= 8 THEN
    RETURN 'hard'::difficulty_mode;
  ELSIF incidents >= 4 THEN
    RETURN 'medium'::difficulty_mode;
  ELSE
    RETURN 'easy'::difficulty_mode;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- calculate_stars(score)
-- Returns star rating (0–3) from a session score.
-- Locked thresholds (approved):
--   score >= 90  → 3 stars
--   score >= 75  → 2 stars
--   score >= 60  → 1 star  (minimum passing)
--   score <  60  → 0 stars (failed)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION calculate_stars(score INTEGER)
RETURNS SMALLINT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF score >= 90 THEN
    RETURN 3::SMALLINT;
  ELSIF score >= 75 THEN
    RETURN 2::SMALLINT;
  ELSIF score >= 60 THEN
    RETURN 1::SMALLINT;
  ELSE
    RETURN 0::SMALLINT;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- update_worker_safety_score(worker_uuid)
-- Recomputes and persists a worker's safety_score.
--
-- Algorithm (locked contract):
--   For each module with at least one passed session:
--     compute the AVERAGE score across all passed sessions for that module.
--   Then take the AVERAGE of those per-module means.
--   Round to the nearest integer. Stored as 0–100.
--
-- This reflects improving performance over time — not just peak performance.
-- SECURITY DEFINER: executes with owner privileges to bypass RLS on workers.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION update_worker_safety_score(worker_uuid UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  new_score INTEGER;
BEGIN
  SELECT COALESCE(ROUND(AVG(module_mean))::INTEGER, 0)
  INTO new_score
  FROM (
    SELECT
      module,
      AVG(score) AS module_mean   -- mean of all passed attempts per module
    FROM training_sessions
    WHERE worker_id = worker_uuid
      AND passed = TRUE
    GROUP BY module
  ) per_module_means;

  UPDATE workers
  SET
    safety_score = new_score,
    updated_at   = NOW()
  WHERE id = worker_uuid;
END;
$$;

-- ---------------------------------------------------------------------------
-- verify_certificate(p_cert_code)
-- PUBLIC-SAFE certificate verification for QR code scanning.
-- Returns limited public fields only — does NOT expose internal UUIDs,
-- qr_hash, or any row from a full-table scan.
-- SECURITY DEFINER: bypasses RLS so anon callers can look up a specific cert.
-- Revoked certificates return no rows (empty result set).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION verify_certificate(p_cert_code TEXT)
RETURNS TABLE (
  cert_code    TEXT,
  worker_name  TEXT,
  worker_code  TEXT,
  mine_name    TEXT,
  module       training_module,
  score        INTEGER,
  issued_at    TIMESTAMPTZ,
  expires_at   TIMESTAMPTZ,
  is_valid     BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.cert_code,
    w.full_name                                     AS worker_name,
    w.worker_code,
    COALESCE(m.name, 'Unassigned')                  AS mine_name,
    c.module,
    c.score,
    c.issued_at,
    c.expires_at,
    (c.expires_at > NOW() AND NOT c.is_revoked)     AS is_valid
  FROM   certificates c
  JOIN   workers      w ON w.id = c.worker_id
  LEFT JOIN mines     m ON m.id = w.mine_id
  WHERE  c.cert_code = p_cert_code
    AND  NOT c.is_revoked;   -- revoked certs return empty result set
END;
$$;

-- Grant execute to anon so QR scanners can verify without logging in.
-- Access is always scoped to a single cert_code — never a table scan.
GRANT EXECUTE ON FUNCTION verify_certificate(TEXT) TO anon;

-- =============================================================================
-- VIEWS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- leaderboard_view
-- Ranked worker safety scores with mine context.
-- Badges column comes from worker_badges (normalized), not TEXT[].
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW leaderboard_view AS
SELECT
  w.id                                                    AS worker_id,
  w.worker_code,
  w.full_name,
  m.name                                                  AS mine_name,
  m.district,
  w.safety_score,
  w.current_streak,
  COALESCE(wb.badge_ids, '{}')                            AS badges,
  COUNT(DISTINCT ts.id)                                   AS total_sessions,
  COUNT(DISTINCT ts.id) FILTER (WHERE ts.passed = TRUE)   AS modules_passed,
  DENSE_RANK() OVER (ORDER BY w.safety_score DESC)        AS rank
FROM workers w
LEFT JOIN mines m ON w.mine_id = m.id
LEFT JOIN training_sessions ts ON ts.worker_id = w.id
LEFT JOIN LATERAL (
  SELECT array_agg(badge_id ORDER BY earned_at) AS badge_ids
  FROM   worker_badges
  WHERE  worker_id = w.id
) wb ON TRUE
WHERE w.is_active = TRUE
GROUP BY
  w.id, w.worker_code, w.full_name, m.name, m.district,
  w.safety_score, w.current_streak, wb.badge_ids;

-- ---------------------------------------------------------------------------
-- worker_progress_view
-- Per-worker, per-module progress summary for the supervisor dashboard.
-- Includes latest certificate per worker+module via LATERAL join.
-- Rows where ts.module IS NULL indicate workers with no training attempts.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW worker_progress_view AS
SELECT
  w.id                                  AS worker_id,
  w.worker_code,
  w.full_name,
  w.mine_id,
  m.name                                AS mine_name,
  w.safety_score,
  w.current_streak,
  w.last_trained_at,
  ts.module,
  MAX(ts.score)                         AS best_score,
  MAX(ts.stars)                         AS best_stars,
  AVG(ts.score) FILTER (
    WHERE ts.passed = TRUE
  )                                     AS avg_passed_score,
  COUNT(ts.id)                          AS attempt_count,
  BOOL_OR(ts.passed)                    AS ever_passed,
  MAX(ts.created_at)                    AS last_attempt_at,
  -- Latest non-revoked certificate for this worker + module
  c.cert_code,
  c.expires_at                          AS cert_expires_at,
  c.is_revoked                          AS cert_revoked,
  (c.expires_at > NOW()
    AND c.is_revoked = FALSE)           AS cert_valid
FROM workers w
LEFT JOIN mines m ON w.mine_id = m.id
LEFT JOIN training_sessions ts ON ts.worker_id = w.id
LEFT JOIN LATERAL (
  SELECT cert_code, expires_at, is_revoked
  FROM   certificates
  WHERE  worker_id = w.id
    AND  (ts.module IS NULL OR module = ts.module)
  ORDER BY issued_at DESC
  LIMIT 1
) c ON TRUE
WHERE w.is_active = TRUE
GROUP BY
  w.id, w.worker_code, w.full_name, w.mine_id, m.name,
  w.safety_score, w.current_streak, w.last_trained_at, ts.module,
  c.cert_code, c.expires_at, c.is_revoked;

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE mines              ENABLE ROW LEVEL SECURITY;
ALTER TABLE workers            ENABLE ROW LEVEL SECURITY;
ALTER TABLE supervisors        ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_sessions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE certificates       ENABLE ROW LEVEL SECURITY;
ALTER TABLE badges             ENABLE ROW LEVEL SECURITY;
ALTER TABLE worker_badges      ENABLE ROW LEVEL SECURITY;

-- =============================================================================
-- RLS: mines
-- All authenticated users read active mines.
-- Only service_role inserts/updates (admin seeding, data corrections).
-- =============================================================================

CREATE POLICY "mines_select_authenticated"
  ON mines FOR SELECT TO authenticated
  USING (is_active = TRUE);

CREATE POLICY "mines_insert_service_only"
  ON mines FOR INSERT TO service_role
  WITH CHECK (TRUE);

CREATE POLICY "mines_update_service_only"
  ON mines FOR UPDATE TO service_role
  USING (TRUE);

-- =============================================================================
-- RLS: workers
-- =============================================================================

-- A worker can read their own row only.
CREATE POLICY "workers_select_own"
  ON workers FOR SELECT TO authenticated
  USING (auth.uid() = id);

-- A worker can update their own allowed fields (language, avatar_url, phone, etc.)
-- Safety_score, worker_code, username updates go through server functions.
CREATE POLICY "workers_update_own"
  ON workers FOR UPDATE TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- Worker rows are created by the server after auth signup (Phase 2 trigger).
CREATE POLICY "workers_insert_service_only"
  ON workers FOR INSERT TO service_role
  WITH CHECK (TRUE);

-- A supervisor can read workers belonging to their mine.
CREATE POLICY "workers_select_supervisor"
  ON workers FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      WHERE s.id = auth.uid()
        AND s.mine_id = workers.mine_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspectors and admins can read all workers.
CREATE POLICY "workers_select_dgms_admin"
  ON workers FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- =============================================================================
-- RLS: supervisors
-- =============================================================================

-- A supervisor can read their own row only.
CREATE POLICY "supervisors_select_own"
  ON supervisors FOR SELECT TO authenticated
  USING (auth.uid() = id);

-- Supervisor rows created by service_role only (admin provisioning).
CREATE POLICY "supervisors_insert_service_only"
  ON supervisors FOR INSERT TO service_role
  WITH CHECK (TRUE);

CREATE POLICY "supervisors_update_service_only"
  ON supervisors FOR UPDATE TO service_role
  USING (TRUE);

-- =============================================================================
-- RLS: training_sessions
-- =============================================================================

-- A worker reads their own sessions.
CREATE POLICY "training_sessions_select_own"
  ON training_sessions FOR SELECT TO authenticated
  USING (auth.uid() = worker_id);

-- A worker inserts their own sessions (online or sync from offline).
CREATE POLICY "training_sessions_insert_own"
  ON training_sessions FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = worker_id);

-- Sessions are immutable — no UPDATE or DELETE for authenticated users.

-- Supervisor reads sessions for workers in their mine.
CREATE POLICY "training_sessions_select_supervisor"
  ON training_sessions FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM supervisors s
      JOIN workers w ON w.mine_id = s.mine_id
      WHERE s.id = auth.uid()
        AND w.id = training_sessions.worker_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspectors and admins read all sessions.
CREATE POLICY "training_sessions_select_dgms_admin"
  ON training_sessions FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- =============================================================================
-- RLS: certificates
-- NOTE: Anonymous certificate verification is handled exclusively by the
-- verify_certificate() SECURITY DEFINER function — not by anon table policies.
-- There is NO anon SELECT policy on this table.
-- =============================================================================

-- A worker reads their own certificates.
CREATE POLICY "certificates_select_own"
  ON certificates FOR SELECT TO authenticated
  USING (auth.uid() = worker_id);

-- Certificates are written only by the server (Phase 3 Edge Function).
CREATE POLICY "certificates_insert_service_only"
  ON certificates FOR INSERT TO service_role
  WITH CHECK (TRUE);

CREATE POLICY "certificates_update_service_only"
  ON certificates FOR UPDATE TO service_role
  USING (TRUE);

-- Supervisor reads certificates for workers in their mine.
CREATE POLICY "certificates_select_supervisor"
  ON certificates FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM supervisors s
      JOIN workers w ON w.mine_id = s.mine_id
      WHERE s.id = auth.uid()
        AND w.id = certificates.worker_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspectors and admins read all certificates.
CREATE POLICY "certificates_select_dgms_admin"
  ON certificates FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- =============================================================================
-- RLS: badges (catalogue — read-only for all authenticated users)
-- =============================================================================

CREATE POLICY "badges_select_authenticated"
  ON badges FOR SELECT TO authenticated
  USING (TRUE);

-- Badge definitions managed by service_role only.
CREATE POLICY "badges_insert_service_only"
  ON badges FOR INSERT TO service_role
  WITH CHECK (TRUE);

CREATE POLICY "badges_update_service_only"
  ON badges FOR UPDATE TO service_role
  USING (TRUE);

-- =============================================================================
-- RLS: worker_badges
-- =============================================================================

-- A worker reads their own earned badges.
CREATE POLICY "worker_badges_select_own"
  ON worker_badges FOR SELECT TO authenticated
  USING (auth.uid() = worker_id);

-- Badge granting is service_role only (Phase 3 logic — not client-writable).
CREATE POLICY "worker_badges_insert_service_only"
  ON worker_badges FOR INSERT TO service_role
  WITH CHECK (TRUE);

-- Supervisor reads badge records for workers in their mine.
CREATE POLICY "worker_badges_select_supervisor"
  ON worker_badges FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM supervisors s
      JOIN workers w ON w.mine_id = s.mine_id
      WHERE s.id = auth.uid()
        AND w.id = worker_badges.worker_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspectors and admins read all badge records.
CREATE POLICY "worker_badges_select_dgms_admin"
  ON worker_badges FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );