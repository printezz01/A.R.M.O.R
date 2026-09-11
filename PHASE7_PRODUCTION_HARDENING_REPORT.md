# A.R.M.O.R — Phase 7: Production Hardening & Security Audit Report

> **Date:** September 2026  
> **Status:** Phase 7 Complete — Production Hardened  
> **Repository:** `printezz01/A.R.M.O.R` (Backend)  
> **Hosted Supabase Project:** `ampqcpxpshaiiquqbmmn.supabase.co`  

---

## 1. Executive Summary

Phase 7 executed a complete backend security hardening, secret audit, RLS boundary verification, Edge Function reliability review, and performance index optimization across the A.R.M.O.R backend. 

### Critical Architecture Affirmations:
- **Zero Firebase / FCM**: Completely eradicated from all configurations, schemas, and templates.
- **Offline Layer Deferral**: The Flutter Hive offline storage and local synchronization queue are **strictly deferred to Phase 8**. No Hive or mobile local persistence logic was introduced in Phase 7. All Phase 7 sync validation verified server-side PostgreSQL idempotency independently.
- **Certificate Verification Security Gateway**: Direct anonymous execution of `public.verify_certificate(TEXT)` has been revoked. All public QR verifications must route through the `verify-certificate` Edge Function gateway.

---

## 2. Vulnerabilities Identified & Resolved

| ID | Component | Vulnerability / Risk | Severity | Resolution in Phase 7 |
|---|---|---|---|---|
| **VULN-01** | `verify_certificate(text)` | Direct `anon` execute permissions allowed public users to bypass Edge Function rate-limiting and validation by hitting `/rest/v1/rpc/verify_certificate` directly. | **HIGH** | Revoked `EXECUTE` on `verify_certificate` from `anon` via migration `00000000000008_production_hardening.sql`. Edge Function now acts as the sole public gateway using server-side service key. |
| **VULN-02** | `training_sessions` | Potential direct REST insert could forge `stars` or `passed = TRUE` on low scores ($<60$). | **MEDIUM** | Created `trg_training_session_integrity` trigger. Automatically overrides `stars = calculate_stars(score)` and `passed = (score >= 60)` BEFORE INSERT/UPDATE. |
| **VULN-03** | `verify-certificate` Edge Function | Dashboard single-file editor failed on shared imports (`../_shared/cors.ts`). | **LOW** | Restructured into standard Supabase CLI layout under `supabase/functions/` and enabled `--no-verify-jwt` deployment. |
| **VULN-04** | `.env.example` | Contained stale references to Firebase, FCM, and legacy symmetric `CERT_HASH_SECRET`. | **LOW** | Completely purged all legacy comments; added modern Supabase configuration and public verification URL templates. |
| **VULN-05** | Database Performance | Missing composite indexes on `certificates(session_id)`, `workers(mine_id, is_active)`, and `notifications(worker_id, created_at)`. | **MEDIUM** | Added 4 targeted performance indexes in migration `00000000000008_production_hardening.sql`. |

---

## 3. Database Migrations Created

### [`00000000000008_production_hardening.sql`](file:///c:/Users/Prince/OneDrive/Desktop/A.R.M.O.R_BACKEND/armor_repo/supabase/migrations/00000000000008_production_hardening.sql)
1. **Public Access Revocation**:
   ```sql
   REVOKE EXECUTE ON FUNCTION public.verify_certificate(TEXT) FROM anon;
   GRANT EXECUTE ON FUNCTION public.verify_certificate(TEXT) TO authenticated, service_role;
   ```
2. **Authoritative Session Integrity Trigger**:
   ```sql
   CREATE OR REPLACE FUNCTION public.enforce_training_session_integrity()
   RETURNS TRIGGER AS $$
   BEGIN
     NEW.stars := public.calculate_stars(NEW.score);
     NEW.passed := (NEW.score >= 60);
     IF current_user = 'authenticated' AND NEW.worker_id <> auth.uid() THEN
       RAISE EXCEPTION 'UNAUTHORIZED: Cannot insert or modify training session for another worker.';
     END IF;
     RETURN NEW;
   END;
   $$ LANGUAGE plpgsql SECURITY DEFINER;
   ```
3. **Targeted Performance Indexes**:
   - `idx_certificates_session_id`: Optimizes `certificates` lookup by `session_id` during session sync deduplication.
   - `idx_workers_mine_active`: Optimizes supervisor worker listings, KPI rollups, and drill broadcasts on `(mine_id, is_active)`.
   - `idx_training_sessions_passed_module`: Partial index `(worker_id, module) WHERE passed = TRUE` optimizing `update_worker_safety_score()`.
   - `idx_notifications_worker_created`: Composite index `(worker_id, created_at DESC)` optimizing worker notification feeds.

---

## 4. Edge Functions Architecture & Validation

| Function | Gateway Auth | Downstream DB Auth | Validation & Hardening |
|---|---|---|---|
| **`verify-certificate`** | Public (`--no-verify-jwt`) | Server-Side Service Role Key | Validates regex `^SK-\d{4}-JH-\d{5}$`, enforces IP rate limiting (30 req/min/IP), sets 60s cache headers, returns standardized public JSON. |
| **`leaderboard`** | Authenticated (`verify-jwt`) | Caller Bearer JWT (Anon Key + JWT) | Forwards caller's JWT to PostgreSQL, preserving RLS and tenant scoping (`my_mine`, `my_district`, `all_jharkhand`). |
| **`sync-session`** | Authenticated (`verify-jwt`) | Caller Bearer JWT (Anon Key + JWT) | Enforces worker authentication, score range validation ($0\text{--}100$), and idempotent deduplication via `local_session_id`. |

### Rate Limiting Assessment
- The Edge Function in-memory sliding-window limiter provides instance-level protection against burst abuse.
- **Production Recommendation**: For enterprise multi-region scale under coordinated DDoS attacks, distributed rate limiting should be enforced at the edge/WAF layer (e.g. Cloudflare WAF, Supabase API Gateway rate limits, or Upstash Redis). No extra paid infrastructure was added for the hackathon prototype.

---

## 5. Complete Row Level Security (RLS) Matrix

| Table | Worker Privileges | Supervisor Privileges | DGMS / Admin | Anonymous (`anon`) |
|---|---|---|---|---|
| `workers` | Read own row; Update non-protected fields (`mine_id`, `language`, `phone`, `avatar_url`). System fields locked by trigger. | Read workers in assigned mine. | Read all workers statewide. | Blocked. |
| `supervisors` | Blocked. | Read own profile row. | Read all supervisors. | Blocked. |
| `mines` | Read all active mines. | Read all active mines. | Read / Write all mines. | Read active mines (for splash/onboarding). |
| `training_sessions` | Read own sessions; Insert own sessions (immutable once written). | Read sessions for workers in assigned mine. | Read all sessions statewide. | Blocked. |
| `training_actions` | Read own actions; Insert own session actions. | Read actions for workers in assigned mine. | Read all actions statewide. | Blocked. |
| `certificates` | Read own certificates. Direct table insert/update blocked. | Read certificates for workers in assigned mine. | Read all certificates statewide. | Blocked (public queries route through Edge Function). |
| `emergency_drills` | Read drills scheduled for own mine. | Read, insert, and update drills for assigned mine. | Full access statewide. | Blocked. |
| `notifications` | Read own notifications; Update `is_read`, `read_at` on own rows. | Read/insert drill notifications for workers in assigned mine. | Read all notifications. | Blocked. |
| `spaced_repetition_schedules` | Read own schedules. | Read schedules for workers in assigned mine. | Read all schedules. | Blocked. |
| `badges` & `worker_badges` | Read badges catalogue and own earned badges. | Read earned badges for workers in assigned mine. | Full read access. | Blocked. |

---

## 6. Repository Secret Audit

A complete scan of all files in `armor_repo` was conducted:

| Secret Category | Scan Pattern | Result | File Path / Details |
|---|---|---|---|
| **Supabase Service Role Key** | `service_role` / `eyJ...` | **CLEAN (NOT FOUND)** | Only referenced as an environment variable name (`SUPABASE_SERVICE_ROLE_KEY`) and in RLS policy role identifiers. No actual service-role JWT is present in code or git. |
| **Supabase Anon Key** | `anon` / `eyJ...` | **CLEAN (NOT FOUND)** | No real anon keys committed. Truncated placeholders (`eyJhbGciOi...`) used in documentation examples only. |
| **Database Passwords** | `postgres://...` / `password=...` | **CLEAN (NOT FOUND)** | Zero connection strings or plaintext database passwords committed. |
| **Personal Access Tokens** | `ghp_...` / `sbp_...` | **CLEAN (NOT FOUND)** | No GitHub or Supabase access tokens found. |
| **Private Hash Salt** | `CERT_HASH_SECRET` | **CLEAN (NOT FOUND)** | Completely eliminated in Phase 3/7. |
| **Firebase / GCP Credentials** | `private_key` / `client_email` | **CLEAN (NOT FOUND)** | No Google service accounts or JSON keys exist. |
| **Unversioned `.env` File** | `.env` | **CLEAN (NOT FOUND)** | Only `.env.example` exists. |

---

## 7. Certificate Verification Base URL Configuration

The verification fallback:
`https://armor-verify.internal/verify?code=`
is an internal development fallback template only.

- **Real Domain Requirement**: When the production verification frontend is deployed (e.g. on Vercel), set the base URL via Supabase CLI:
  ```powershell
  supabase secrets set CERT_VERIFY_BASE_URL="https://armor.vercel.app/verify?code=" --project-ref ampqcpxpshaiiquqbmmn
  ```
  and in PostgreSQL:
  ```sql
  ALTER DATABASE postgres SET "app.settings.cert_verify_base_url" = 'https://armor.vercel.app/verify?code=';
  ```
- No government domain (`armor.gov.in`) is claimed or hardcoded.

---

## 8. Automated Test Suite Execution Summary

Test harness: [`backend/scripts/test_phase7_production_hardening.sql`](file:///c:/Users/Prince/OneDrive/Desktop/A.R.M.O.R_BACKEND/armor_repo/backend/scripts/test_phase7_production_hardening.sql)

| Stage | Test Description | Assertions & Validation | Result |
|---|---|---|---|
| **Stage 1** | Direct anon execution of `verify_certificate` | Expects SQLSTATE `42501` (permission denied). Direct RPC bypass closed. | **PASSED** |
| **Stage 2** | Service role execution of `verify_certificate` | Expects successful query return with valid certificate payload. | **PASSED** |
| **Stage 3** | Training session trigger enforcement | Forged insert (`score=45, stars=3, passed=true`) authoritatively overridden to `stars=0, passed=false`. | **PASSED** |
| **Stage 4** | `sync_training_session` idempotency | Identical `local_session_id` retry returns `already_synced: true`, same session ID, no duplicate rows. | **PASSED** |
| **Stage 5** | Cross-worker session insertion denial | Worker 1 cannot insert training session for Worker 2 (blocked by trigger / RLS). | **PASSED** |
| **Stage 6** | Worker profile field protection | Direct UPDATE on `safety_score` raises `IMMUTABLE_FIELD`. | **PASSED** |
| **Stage 7** | Supervisor mine isolation | Supervisor Alpha (Mine Alpha) direct SELECT on Worker Three (Mine Beta) returns 0 rows. | **PASSED** |
| **Stage 8** | Cross-worker notification privacy | Worker Two cannot query or view Worker One's notification records. | **PASSED** |
| **Stage 9** | Leaderboard scopes & privacy audit | Evaluates `my_mine`, verifies tie-breaking (`longest_streak`), confirms absence of UUIDs/phone in JSON. | **PASSED** |
| **Stage 10** | Locked training thresholds | Confirms exact rules: Pass $= 60$; Stars: $<60=0$, $60\text{--}74=1$, $75\text{--}89=2$, $90\text{--}100=3$. | **PASSED** |
| **Stage 11** | Certificate states | Validates `status: valid`, `status: expired`, and `status: revoked`. | **PASSED** |
| **Stage 12** | Production indexes verification | Verifies existence of all 4 Phase 7 database performance indexes. | **PASSED** |

---

## 9. Next Steps for Deployment

1. **Apply Migration 00000000000008**:
   - Run [`supabase/migrations/00000000000008_production_hardening.sql`](file:///c:/Users/Prince/OneDrive/Desktop/A.R.M.O.R_BACKEND/armor_repo/supabase/migrations/00000000000008_production_hardening.sql) in the Supabase Dashboard SQL Editor.
2. **Redeploy Edge Functions**:
   ```powershell
   # 1. verify-certificate (Public gateway, no gateway JWT check)
   supabase functions deploy verify-certificate --project-ref ampqcpxpshaiiquqbmmn --no-verify-jwt

   # 2. leaderboard (Authenticated user gateway)
   supabase functions deploy leaderboard --project-ref ampqcpxpshaiiquqbmmn

   # 3. sync-session (Authenticated worker sync)
   supabase functions deploy sync-session --project-ref ampqcpxpshaiiquqbmmn
   ```
3. **Phase 8 (Mobile / Flutter Offline Layer)**:
   - Client-side Hive boxes, sync queue, network detection, and local certificate storage will be implemented in Phase 8.
