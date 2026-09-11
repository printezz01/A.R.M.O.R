-- =============================================================================
-- A.R.M.O.R — Phase 2: Authentication & Worker API
-- Migration: 00000000000001_auth_and_worker_api.sql
-- =============================================================================
-- Features:
--   1. Public read for active mines during onboarding (mines_select_anon)
--   2. Worker provisioning trigger on auth.users (handle_new_auth_user)
--   3. Worker field update protection trigger (protect_worker_fields)
--   4. Authenticated mine selection RPC (set_worker_mine)
--   5. Authoritative role & profile resolution RPC (get_auth_profile)
-- =============================================================================

-- =============================================================================
-- 1. RLS: Allow anon to read active mines during onboarding
-- =============================================================================

CREATE POLICY "mines_select_anon"
  ON mines FOR SELECT TO anon
  USING (is_active = TRUE);

-- =============================================================================
-- 2. TRIGGER FUNCTION: handle_new_auth_user
-- Runs with SECURITY DEFINER when a user registers in auth.users.
-- Ensures worker accounts are provisioned server-side with WKR-JH-XXXX code,
-- mine_id = NULL, and safety_score = 0.
-- Enforces that self-registration ONLY provisions worker profiles.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_raw_username  TEXT;
  v_username      TEXT;
  v_full_name     TEXT;
  v_language      public.language_code;
  v_phone         TEXT;
  v_role          TEXT;
BEGIN
  -- Extract metadata provided during auth.signUp
  v_raw_username := NEW.raw_user_meta_data->>'username';
  v_full_name    := NULLIF(TRIM(NEW.raw_user_meta_data->>'full_name'), '');
  v_phone        := NULLIF(TRIM(NEW.raw_user_meta_data->>'phone'), '');
  v_role         := LOWER(COALESCE(NEW.raw_user_meta_data->>'role', 'worker'));

  -- Normalize username: lowercase, trimmed
  IF v_raw_username IS NOT NULL AND TRIM(v_raw_username) <> '' THEN
    v_username := LOWER(TRIM(v_raw_username));
  ELSE
    -- Fallback from email prefix if username wasn't in metadata
    v_username := LOWER(SPLIT_PART(NEW.email, '@', 1));
  END IF;

  -- Validate username format: 3-30 chars, alphanumeric, dots, hyphens, underscores
  IF v_username !~ '^[a-z0-9._-]{3,30}$' THEN
    RAISE EXCEPTION 'INVALID_USERNAME: Username must be 3-30 characters long and contain only lowercase letters, numbers, dots, hyphens, and underscores.';
  END IF;

  -- Validate full_name
  IF v_full_name IS NULL THEN
    RAISE EXCEPTION 'INVALID_FULL_NAME: Full name is required.';
  END IF;

  -- Validate and cast language
  BEGIN
    v_language := COALESCE((NEW.raw_user_meta_data->>'language')::public.language_code, 'hi'::public.language_code);
  EXCEPTION WHEN OTHERS THEN
    v_language := 'hi'::public.language_code;
  END;

  -- Enforce authoritative role: self-signup is strictly for workers.
  -- Supervisor accounts cannot be self-provisioned via public signup.
  IF v_role = 'worker' THEN
    -- Check for duplicate username across workers and supervisors
    IF EXISTS (SELECT 1 FROM public.workers WHERE username = v_username) OR
       EXISTS (SELECT 1 FROM public.supervisors WHERE username = v_username) THEN
      RAISE EXCEPTION 'USERNAME_TAKEN: The username % is already taken.', v_username;
    END IF;

    -- Insert worker profile: mine_id is strictly NULL at registration
    INSERT INTO public.workers (
      id,
      worker_code,
      username,
      full_name,
      phone,
      mine_id,
      language,
      safety_score,
      current_streak,
      longest_streak,
      is_active
    ) VALUES (
      NEW.id,
      public.generate_worker_code(),
      v_username,
      v_full_name,
      v_phone,
      NULL,  -- mine_id is strictly NULL at registration
      v_language,
      0,
      0,
      0,
      TRUE
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Register trigger on auth.users
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- =============================================================================
-- 3. TRIGGER FUNCTION: protect_worker_fields
-- Enforces that authenticated workers cannot alter protected system fields:
-- id, worker_code, username, safety_score, streaks, created_at.
-- Only mine_id, language, phone, avatar_url, is_active can be updated by workers.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.protect_worker_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Only enforce restrictions for regular authenticated users, not service_role
  IF auth.role() = 'authenticated' THEN
    IF NEW.id <> OLD.id THEN
      RAISE EXCEPTION 'IMMUTABLE_FIELD: Worker ID cannot be altered.';
    END IF;
    IF NEW.worker_code <> OLD.worker_code THEN
      RAISE EXCEPTION 'IMMUTABLE_FIELD: Worker code cannot be altered.';
    END IF;
    IF NEW.username <> OLD.username THEN
      RAISE EXCEPTION 'IMMUTABLE_FIELD: Username cannot be altered.';
    END IF;
    IF NEW.safety_score <> OLD.safety_score THEN
      RAISE EXCEPTION 'IMMUTABLE_FIELD: Safety score is computed automatically and cannot be directly updated.';
    END IF;
    IF NEW.current_streak <> OLD.current_streak OR NEW.longest_streak <> OLD.longest_streak THEN
      RAISE EXCEPTION 'IMMUTABLE_FIELD: Streak counters are managed by the training system and cannot be directly updated.';
    END IF;
    IF NEW.created_at <> OLD.created_at THEN
      RAISE EXCEPTION 'IMMUTABLE_FIELD: Registration timestamp cannot be altered.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_worker_fields ON public.workers;
CREATE TRIGGER trg_protect_worker_fields
  BEFORE UPDATE ON public.workers
  FOR EACH ROW EXECUTE FUNCTION public.protect_worker_fields();

-- =============================================================================
-- 4. RPC: set_worker_mine(p_mine_id UUID)
-- Authenticated worker selects or updates their mine after registration.
-- Guarantees the mine exists and is active, and only updates auth.uid().
-- =============================================================================

CREATE OR REPLACE FUNCTION public.set_worker_mine(p_mine_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_worker_id  UUID;
  v_mine_name  TEXT;
  v_result     JSONB;
BEGIN
  v_worker_id := auth.uid();
  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: Must be logged in to select a mine.';
  END IF;

  -- Ensure the worker exists and is active
  IF NOT EXISTS (SELECT 1 FROM public.workers WHERE id = v_worker_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'WORKER_NOT_FOUND: Active worker profile not found.';
  END IF;

  -- Validate that the mine exists and is active
  SELECT name INTO v_mine_name
  FROM public.mines
  WHERE id = p_mine_id AND is_active = TRUE;

  IF v_mine_name IS NULL THEN
    RAISE EXCEPTION 'MINE_NOT_FOUND: The specified mine does not exist or is inactive.';
  END IF;

  -- Update worker mine
  UPDATE public.workers
  SET mine_id = p_mine_id,
      updated_at = NOW()
  WHERE id = v_worker_id;

  -- Return updated worker profile with mine summary
  SELECT jsonb_build_object(
    'id', w.id,
    'worker_code', w.worker_code,
    'username', w.username,
    'full_name', w.full_name,
    'language', w.language,
    'mine_id', w.mine_id,
    'mine_name', m.name,
    'mine_district', m.district,
    'mine_type', m.type,
    'safety_score', w.safety_score,
    'updated_at', w.updated_at
  ) INTO v_result
  FROM public.workers w
  JOIN public.mines m ON m.id = w.mine_id
  WHERE w.id = v_worker_id;

  RETURN v_result;
END;
$$;

-- =============================================================================
-- 5. RPC: get_auth_profile()
-- Authoritative profile retrieval for authenticated users.
-- Determines role purely from database tables (supervisors vs workers), never frontend input.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_auth_profile()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id   UUID;
  v_profile   JSONB;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: No active session found.';
  END IF;

  -- Check if user is a supervisor / DGMS inspector / admin
  SELECT jsonb_build_object(
    'role', s.role::TEXT,
    'user_id', s.id,
    'username', s.username,
    'full_name', s.full_name,
    'phone', s.phone,
    'mine_id', s.mine_id,
    'mine_name', m.name,
    'mine_district', m.district,
    'is_active', s.is_active
  ) INTO v_profile
  FROM public.supervisors s
  JOIN public.mines m ON m.id = s.mine_id
  WHERE s.id = v_user_id AND s.is_active = TRUE;

  IF v_profile IS NOT NULL THEN
    RETURN v_profile;
  END IF;

  -- Check if user is a worker
  SELECT jsonb_build_object(
    'role', 'worker',
    'user_id', w.id,
    'worker_code', w.worker_code,
    'username', w.username,
    'full_name', w.full_name,
    'phone', w.phone,
    'language', w.language,
    'mine_id', w.mine_id,
    'mine_name', m.name,
    'safety_score', w.safety_score,
    'current_streak', w.current_streak,
    'longest_streak', w.longest_streak,
    'last_trained_at', w.last_trained_at,
    'avatar_url', w.avatar_url,
    'is_active', w.is_active
  ) INTO v_profile
  FROM public.workers w
  LEFT JOIN public.mines m ON m.id = w.mine_id
  WHERE w.id = v_user_id AND w.is_active = TRUE;

  IF v_profile IS NOT NULL THEN
    RETURN v_profile;
  END IF;

  RAISE EXCEPTION 'PROFILE_NOT_FOUND: No active profile registered for this account.';
END;
$$;
