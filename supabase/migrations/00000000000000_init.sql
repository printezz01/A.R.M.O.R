-- =============================================================================
-- A.R.M.O.R — Phase 1 Core Schema Migration
-- Migration: 00000000000000_init.sql
-- Project: ampqcpxpshaiiquqbmmn.supabase.co
-- =============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

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
  'hi',   -- Hindi
  'sat',  -- Santali (Ol Chiki)
  'en'    -- English
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
-- HELPER FUNCTION: updated_at trigger
-- =============================================================================

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- TABLE: mines
-- Static mine/plant metadata sourced from DGMS records
-- =============================================================================

CREATE TABLE mines (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                      TEXT NOT NULL,
  district                  TEXT NOT NULL,
  state                     TEXT NOT NULL DEFAULT 'Jharkhand',
  type                      mine_type NOT NULL,
  latitude                  NUMERIC(9, 6),
  longitude                 NUMERIC(9, 6),
  worker_count              INTEGER,
  fire_incidents_3yr        INTEGER NOT NULL DEFAULT 0,
  gas_incidents_3yr         INTEGER NOT NULL DEFAULT 0,
  electrical_incidents_3yr  INTEGER NOT NULL DEFAULT 0,
  is_active                 BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER set_mines_updated_at
  BEFORE UPDATE ON mines
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- Index for district lookup and name search
CREATE INDEX idx_mines_district ON mines (district);
CREATE INDEX idx_mines_name_trgm ON mines USING GIN (name gin_trgm_ops);
CREATE INDEX idx_mines_type ON mines (type);

-- =============================================================================
-- TABLE: workers
-- One row per registered mine worker — id matches auth.users.id
-- =============================================================================

CREATE TABLE workers (
  id                UUID PRIMARY KEY,  -- matches auth.users.id
  phone             TEXT NOT NULL UNIQUE,
  full_name         TEXT NOT NULL,
  mine_id           UUID REFERENCES mines (id) ON DELETE SET NULL,
  language          language_code NOT NULL DEFAULT 'hi',
  safety_score      INTEGER NOT NULL DEFAULT 0 CHECK (safety_score BETWEEN 0 AND 100),
  current_streak    INTEGER NOT NULL DEFAULT 0,
  longest_streak    INTEGER NOT NULL DEFAULT 0,
  last_trained_at   TIMESTAMPTZ,
  badges            TEXT[] NOT NULL DEFAULT '{}',
  avatar_url        TEXT,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER set_workers_updated_at
  BEFORE UPDATE ON workers
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE INDEX idx_workers_mine_id ON workers (mine_id);
CREATE INDEX idx_workers_phone ON workers (phone);
CREATE INDEX idx_workers_safety_score ON workers (safety_score DESC);

-- =============================================================================
-- TABLE: supervisors
-- Dashboard users: safety officers and DGMS inspectors
-- id matches auth.users.id
-- =============================================================================

CREATE TABLE supervisors (
  id          UUID PRIMARY KEY,  -- matches auth.users.id
  full_name   TEXT NOT NULL,
  phone       TEXT NOT NULL UNIQUE,
  mine_id     UUID NOT NULL REFERENCES mines (id) ON DELETE RESTRICT,
  role        supervisor_role NOT NULL DEFAULT 'supervisor',
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER set_supervisors_updated_at
  BEFORE UPDATE ON supervisors
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE INDEX idx_supervisors_mine_id ON supervisors (mine_id);

-- =============================================================================
-- TABLE: training_sessions
-- Records each completed training attempt per worker
-- =============================================================================

CREATE TABLE training_sessions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id         UUID NOT NULL REFERENCES workers (id) ON DELETE CASCADE,
  mine_id           UUID NOT NULL REFERENCES mines (id) ON DELETE RESTRICT,
  module            training_module NOT NULL,
  difficulty        difficulty_mode NOT NULL,
  score             INTEGER NOT NULL CHECK (score BETWEEN 0 AND 100),
  stars             SMALLINT NOT NULL DEFAULT 0 CHECK (stars BETWEEN 0 AND 3),
  passed            BOOLEAN NOT NULL DEFAULT FALSE,
  weak_areas        TEXT[],
  levels_completed  INTEGER NOT NULL DEFAULT 0,
  duration_seconds  INTEGER,
  synced_from_local BOOLEAN NOT NULL DEFAULT FALSE,
  local_session_id  TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Deduplication index for offline sync
CREATE UNIQUE INDEX idx_training_sessions_local_dedup
  ON training_sessions (worker_id, local_session_id)
  WHERE local_session_id IS NOT NULL;

CREATE INDEX idx_training_sessions_worker_id ON training_sessions (worker_id);
CREATE INDEX idx_training_sessions_mine_id ON training_sessions (mine_id);
CREATE INDEX idx_training_sessions_module ON training_sessions (module);
CREATE INDEX idx_training_sessions_created_at ON training_sessions (created_at DESC);

-- =============================================================================
-- TABLE: certificates
-- Verifiable QR-signed training certificates
-- =============================================================================

CREATE TABLE certificates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cert_code   TEXT NOT NULL UNIQUE,   -- e.g. SK-2026-JH-00001
  worker_id   UUID NOT NULL REFERENCES workers (id) ON DELETE CASCADE,
  session_id  UUID NOT NULL REFERENCES training_sessions (id) ON DELETE RESTRICT,
  module      training_module NOT NULL,
  score       INTEGER NOT NULL CHECK (score BETWEEN 0 AND 100),
  issued_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at  TIMESTAMPTZ NOT NULL,
  qr_hash     TEXT NOT NULL,
  is_revoked  BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_certificates_worker_id ON certificates (worker_id);
CREATE INDEX idx_certificates_cert_code ON certificates (cert_code);
CREATE INDEX idx_certificates_module ON certificates (module);
CREATE INDEX idx_certificates_expires_at ON certificates (expires_at);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- get_difficulty_mode: compute difficulty from incident count
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

-- calculate_stars: return star rating (0-3) from score
CREATE OR REPLACE FUNCTION calculate_stars(score INTEGER)
RETURNS SMALLINT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF score >= 85 THEN
    RETURN 3::SMALLINT;
  ELSIF score >= 70 THEN
    RETURN 2::SMALLINT;
  ELSIF score >= 60 THEN
    RETURN 1::SMALLINT;
  ELSE
    RETURN 0::SMALLINT;
  END IF;
END;
$$;

-- generate_cert_code: generate human-readable cert ID like SK-2026-JH-00001
CREATE OR REPLACE FUNCTION generate_cert_code()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  year_str    TEXT;
  seq_count   INTEGER;
  padded_seq  TEXT;
BEGIN
  year_str := TO_CHAR(NOW(), 'YYYY');
  SELECT COUNT(*) + 1 INTO seq_count FROM certificates;
  padded_seq := LPAD(seq_count::TEXT, 5, '0');
  RETURN 'SK-' || year_str || '-JH-' || padded_seq;
END;
$$;

-- update_worker_safety_score: recompute and persist safety_score for a worker
-- Safety score = average of best score per module (weighted equally)
CREATE OR REPLACE FUNCTION update_worker_safety_score(worker_uuid UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  new_score INTEGER;
BEGIN
  SELECT COALESCE(ROUND(AVG(best_score)), 0)
  INTO new_score
  FROM (
    SELECT module, MAX(score) AS best_score
    FROM training_sessions
    WHERE worker_id = worker_uuid AND passed = TRUE
    GROUP BY module
  ) per_module;

  UPDATE workers
  SET
    safety_score = new_score,
    updated_at = NOW()
  WHERE id = worker_uuid;
END;
$$;

-- =============================================================================
-- VIEWS
-- =============================================================================

-- leaderboard_view: ranked worker safety scores with mine context
CREATE OR REPLACE VIEW leaderboard_view AS
SELECT
  w.id                                          AS worker_id,
  w.full_name,
  m.name                                        AS mine_name,
  m.district,
  w.safety_score,
  w.current_streak,
  w.badges,
  COUNT(ts.id)                                  AS total_sessions,
  COUNT(ts.id) FILTER (WHERE ts.passed = TRUE)  AS modules_passed,
  DENSE_RANK() OVER (ORDER BY w.safety_score DESC) AS rank
FROM workers w
LEFT JOIN mines m ON w.mine_id = m.id
LEFT JOIN training_sessions ts ON ts.worker_id = w.id
WHERE w.is_active = TRUE
GROUP BY w.id, w.full_name, m.name, m.district, w.safety_score, w.current_streak, w.badges;

-- worker_progress_view: per-worker per-module progress for supervisor dashboard
CREATE OR REPLACE VIEW worker_progress_view AS
SELECT
  w.id                          AS worker_id,
  w.full_name,
  w.mine_id,
  m.name                        AS mine_name,
  w.safety_score,
  w.current_streak,
  w.last_trained_at,
  ts.module,
  MAX(ts.score)                 AS best_score,
  MAX(ts.stars)                 AS best_stars,
  COUNT(ts.id)                  AS attempt_count,
  BOOL_OR(ts.passed)            AS ever_passed,
  MAX(ts.created_at)            AS last_attempt_at,
  -- Latest certificate for this worker+module
  c.cert_code,
  c.expires_at                  AS cert_expires_at,
  c.is_revoked                  AS cert_revoked
FROM workers w
LEFT JOIN mines m ON w.mine_id = m.id
LEFT JOIN training_sessions ts ON ts.worker_id = w.id
LEFT JOIN LATERAL (
  SELECT cert_code, expires_at, is_revoked
  FROM certificates
  WHERE worker_id = w.id AND module = ts.module
  ORDER BY issued_at DESC
  LIMIT 1
) c ON TRUE
WHERE w.is_active = TRUE
GROUP BY w.id, w.full_name, w.mine_id, m.name, w.safety_score,
         w.current_streak, w.last_trained_at, ts.module,
         c.cert_code, c.expires_at, c.is_revoked;

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

-- Enable RLS on all tables
ALTER TABLE mines              ENABLE ROW LEVEL SECURITY;
ALTER TABLE workers            ENABLE ROW LEVEL SECURITY;
ALTER TABLE supervisors        ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_sessions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE certificates       ENABLE ROW LEVEL SECURITY;

-- ---- mines ----
-- All authenticated users can read mines (public reference data)
CREATE POLICY "mines_select_authenticated"
  ON mines FOR SELECT
  TO authenticated
  USING (is_active = TRUE);

-- Only service role can insert/update mines (no direct user writes)
CREATE POLICY "mines_insert_service_only"
  ON mines FOR INSERT
  TO service_role
  WITH CHECK (TRUE);

CREATE POLICY "mines_update_service_only"
  ON mines FOR UPDATE
  TO service_role
  USING (TRUE);

-- ---- workers ----
-- Workers can only read their own row
CREATE POLICY "workers_select_own"
  ON workers FOR SELECT
  TO authenticated
  USING (auth.uid() = id);

-- Workers can update their own row (language, avatar_url, etc.)
CREATE POLICY "workers_update_own"
  ON workers FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- Worker insert is done via server-side function (triggered after auth signup)
CREATE POLICY "workers_insert_service_only"
  ON workers FOR INSERT
  TO service_role
  WITH CHECK (TRUE);

-- Supervisors can read workers belonging to their mine
CREATE POLICY "workers_select_supervisor"
  ON workers FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      WHERE s.id = auth.uid()
        AND s.mine_id = workers.mine_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspectors and admins can read all workers
CREATE POLICY "workers_select_dgms_admin"
  ON workers FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- ---- supervisors ----
-- Supervisors can only read their own row
CREATE POLICY "supervisors_select_own"
  ON supervisors FOR SELECT
  TO authenticated
  USING (auth.uid() = id);

-- Only service role can insert/update supervisors
CREATE POLICY "supervisors_insert_service_only"
  ON supervisors FOR INSERT
  TO service_role
  WITH CHECK (TRUE);

CREATE POLICY "supervisors_update_service_only"
  ON supervisors FOR UPDATE
  TO service_role
  USING (TRUE);

-- ---- training_sessions ----
-- Workers can read their own sessions
CREATE POLICY "training_sessions_select_own"
  ON training_sessions FOR SELECT
  TO authenticated
  USING (auth.uid() = worker_id);

-- Workers can insert their own sessions (offline sync)
CREATE POLICY "training_sessions_insert_own"
  ON training_sessions FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = worker_id);

-- Workers cannot update or delete sessions (immutable record)
-- No UPDATE/DELETE policies = blocked for authenticated users

-- Supervisors can read sessions for workers in their mine
CREATE POLICY "training_sessions_select_supervisor"
  ON training_sessions FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      JOIN workers w ON w.mine_id = s.mine_id
      WHERE s.id = auth.uid()
        AND w.id = training_sessions.worker_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspectors and admins can read all sessions
CREATE POLICY "training_sessions_select_dgms_admin"
  ON training_sessions FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- ---- certificates ----
-- Workers can read their own certificates
CREATE POLICY "certificates_select_own"
  ON certificates FOR SELECT
  TO authenticated
  USING (auth.uid() = worker_id);

-- No direct insert/update from client — must go through server function
CREATE POLICY "certificates_insert_service_only"
  ON certificates FOR INSERT
  TO service_role
  WITH CHECK (TRUE);

CREATE POLICY "certificates_update_service_only"
  ON certificates FOR UPDATE
  TO service_role
  USING (TRUE);

-- Supervisors can read certificates for their mine's workers
CREATE POLICY "certificates_select_supervisor"
  ON certificates FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      JOIN workers w ON w.mine_id = s.mine_id
      WHERE s.id = auth.uid()
        AND w.id = certificates.worker_id
        AND s.is_active = TRUE
    )
  );

-- DGMS inspectors and admins can read all certificates
CREATE POLICY "certificates_select_dgms_admin"
  ON certificates FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM supervisors s
      WHERE s.id = auth.uid()
        AND s.role IN ('dgms_inspector', 'admin')
        AND s.is_active = TRUE
    )
  );

-- Public can verify certificate by cert_code (for QR scan verification — anon)
CREATE POLICY "certificates_select_public_verify"
  ON certificates FOR SELECT
  TO anon
  USING (TRUE);