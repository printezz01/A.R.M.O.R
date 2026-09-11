-- =============================================================================
-- A.R.M.O.R — Corrective Migration: Certificate Security Hardening
-- Migration: 00000000000003_cert_security_hardening.sql
-- =============================================================================
-- Security Fix:
--   1. Eliminates any requirement for client-side / Flutter signing secrets.
--      Symmetric secrets must NEVER exist in client APKs or browser code.
--   2. Authoritative issuance remains strictly on the backend.
--   3. QR code payloads encode public verification data (cert_code & URL) only.
--   4. verify_certificate(p_cert_code) is the authoritative online verification source.
--   5. qr_hash is retained as an internal backend tamper-evident checksum.
-- =============================================================================

-- Redefine generate_qr_hash as an internal backend integrity checksum
CREATE OR REPLACE FUNCTION public.generate_qr_hash(
  p_cert_code  TEXT,
  p_worker_id  UUID,
  p_module     public.training_module,
  p_score      INTEGER
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  -- Internal database tamper-detection checksum (no client-side secret dependency)
  RETURN encode(
    digest(
      p_cert_code || ':' || p_worker_id::TEXT || ':' || p_module::TEXT || ':' || p_score::TEXT,
      'sha256'
    ),
    'hex'
  );
END;
$$;

-- Update issue_training_certificate to include public verification URL and payload
CREATE OR REPLACE FUNCTION public.issue_training_certificate(
  p_worker_id   UUID,
  p_session_id  UUID,
  p_module      public.training_module,
  p_score       INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cert_code   TEXT;
  v_qr_hash     TEXT;
  v_issued_at   TIMESTAMPTZ := NOW();
  v_expires_at  TIMESTAMPTZ := NOW() + INTERVAL '1 year';
  v_cert_id     UUID;
  v_result      JSONB;
  v_verify_url  TEXT;
BEGIN
  -- Generate unique cert code (SK-YYYY-JH-XXXXX)
  v_cert_code := public.generate_cert_code();

  -- Compute internal backend integrity hash
  v_qr_hash := public.generate_qr_hash(v_cert_code, p_worker_id, p_module, p_score);

  -- Standard verification URL for QR scanners
  v_verify_url := 'https://armor.gov.in/verify?code=' || v_cert_code;

  INSERT INTO public.certificates (
    cert_code,
    worker_id,
    session_id,
    module,
    score,
    issued_at,
    expires_at,
    qr_hash,
    is_revoked
  ) VALUES (
    v_cert_code,
    p_worker_id,
    p_session_id,
    p_module,
    p_score,
    v_issued_at,
    v_expires_at,
    v_qr_hash,
    FALSE
  ) RETURNING id INTO v_cert_id;

  SELECT jsonb_build_object(
    'id', c.id,
    'cert_code', c.cert_code,
    'worker_id', c.worker_id,
    'session_id', c.session_id,
    'module', c.module,
    'score', c.score,
    'issued_at', c.issued_at,
    'expires_at', c.expires_at,
    'verification_url', v_verify_url,
    'qr_payload', jsonb_build_object(
      'cert_code', c.cert_code,
      'verify_url', v_verify_url,
      'module', c.module,
      'issued_at', c.issued_at
    ),
    'is_revoked', c.is_revoked
  ) INTO v_result
  FROM public.certificates c
  WHERE c.id = v_cert_id;

  RETURN v_result;
END;
$$;
