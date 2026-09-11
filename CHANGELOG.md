# A.R.M.O.R — Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

---

## [1.0.0] — 2026-09-12 — Phase 7: Backend Production Hardening & Final Validation

### Security Hardening
- **Public RPC Revocation (`00000000000008_production_hardening.sql`)**: Revoked direct `anon` execute permissions on `verify_certificate(TEXT)` to prevent external callers from bypassing Edge Function rate limiting and validation. Public verification traffic is strictly routed through the `verify-certificate` Edge Function gateway.
- **Authoritative Session Integrity Trigger**: Added `trg_training_session_integrity` on `training_sessions` to automatically enforce `stars = calculate_stars(score)` and `passed = (score >= 60)` on every INSERT/UPDATE, preventing client-side forgery of pass status.
- **Repository Secret Audit**: Performed complete repository audit verifying zero committed service-role JWTs, passwords, private keys, or personal access tokens.
- **Legacy Cleanup**: Purged all stale references to Firebase, FCM, and legacy symmetric hash salts from `.env.example`.

### Added
- **Production Performance Indexes**:
  - `idx_certificates_session_id`: Optimizes `certificates` lookups by `session_id` during session sync deduplication.
  - `idx_workers_mine_active`: Composite index on `(mine_id, is_active)` optimizing supervisor dashboard listings, worker queries, and drill broadcasts.
  - `idx_training_sessions_passed_module`: Partial index `(worker_id, module) WHERE passed = TRUE` optimizing `update_worker_safety_score()`.
  - `idx_notifications_worker_created`: Composite index `(worker_id, created_at DESC)` optimizing worker notification feeds.
- **Automated Test Suite**:
  - Created `backend/scripts/test_phase7_production_hardening.sql`: 12-stage validation suite testing anon RPC denial, service-role verification, trigger integrity, sync idempotency, cross-worker denial, supervisor mine isolation, notification privacy, leaderboard privacy, and index presence.
- **Comprehensive Audit Report**:
  - Created `PHASE7_PRODUCTION_HARDENING_REPORT.md` documenting security findings, RLS policies, performance index justifications, and test execution details.

---

## [0.6.0] — 2026-09-11 — Phase 6: Public Verification + Leaderboards

### Added

#### Database Migrations
- `00000000000006_public_verification_and_leaderboards.sql`: Initial Phase 6 migration.
- `00000000000007_fix_verify_certificate_signature.sql`: Corrective migration explicitly dropping prior `verify_certificate(text)` definition to resolve Postgres `ERROR: 42P13: cannot change return type of existing function`, recreating it with the 11-column signature and ensuring `issue_training_certificate` and `get_leaderboard` are safely established.
- Enhanced `verify_certificate(p_cert_code)`:
  - Supports explicit certificate states (`valid`, `expired`, `revoked`).
  - Strict privacy protections: returns public verification fields (`cert_code`, `worker_name`, `worker_code`, `mine_name`, `district`, `module`, `score`, `issued_at`, `expires_at`, `status`, `is_valid`) while omitting internal UUIDs, phone numbers, and secrets.
  - Granted to `anon`, `authenticated`, and `service_role`.
- Updated `issue_training_certificate(...)`:
  - Replaced hardcoded government domain with dynamic configuration fallback (`current_setting('app.settings.cert_verify_base_url', true)` with fallback to internal template).
- Added `get_leaderboard(p_scope, p_limit, p_offset)` RPC:
  - Scopes: `my_mine` (mine workforce), `my_district` (district-wide), and `all_jharkhand` (statewide).
  - Deterministic tie-breaking: `safety_score DESC` $\rightarrow$ `longest_streak DESC` $\rightarrow$ `modules_passed DESC` $\rightarrow$ `created_at ASC` $\rightarrow$ `worker_code ASC`.
  - Computes worker's personal position (`my_rank`, `my_score_rank`, `my_entry`) and total workforce count.
  - Privacy preserved: excludes auth UUIDs, phone numbers, raw telemetry, and private notifications.

#### Edge Functions
- `backend/functions/verify-certificate/index.ts`:
  - Public verification endpoint supporting GET and POST requests.
  - Strict format validation via regex (`^SK-\d{4}-JH-\d{5}$`).
  - Abuse protection with in-memory IP rate-limiting (30 requests/min/IP) and `X-RateLimit-*` headers.
  - Standardized JSON responses for valid, expired, revoked, and not-found certificates with HTTP caching headers.
- `backend/functions/leaderboard/index.ts`:
  - Authenticated HTTP wrapper for `get_leaderboard` enforcing Bearer JWT authorization.
  - Forwards user context to preserve PostgreSQL RLS and caller mine scope.

#### Testing Harness
- Created `backend/scripts/test_phase6_verification_and_leaderboard.sql`:
  - 9-test automated transaction suite verifying valid, expired, revoked, and missing certs, `my_mine`, `my_district`, and `all_jharkhand` scopes, deterministic tie-breaking, unassigned mine handling, and privacy audits.

---

## [0.5.0] — 2026-09-11 — Phase 5: Supabase Notifications & Spaced Repetition

### Architectural Changes
- **Firebase/FCM Eradication**: Firebase Cloud Messaging, Firestore, and Google service account keys have been completely removed from the A.R.M.O.R backend architecture.
- **Supabase Realtime Pub/Sub**: Enabled real-time notification streaming via Supabase Realtime replication on `public.notifications` for active/in-app emergency drill and training alerts.
- **Offline / Reconnect Synchronization**: Persistent PostgreSQL notification queue allowing mobile workers to fetch pending reminders and unread alerts on app launch or network reconnection.

### Added

#### Database Migration (`00000000000005_notifications_and_spaced_repetition.sql`)
- Created `notification_type` enum (`drill_alert`, `spaced_repetition`, `cert_expiry`, `streak_reminder`, `system_announcement`).
- Created `notifications` table: stores worker notifications with read states (`is_read`, `read_at`) and metadata payloads. Added to `supabase_realtime` publication.
- Created `spaced_repetition_schedules` table: tracks mistake tags, review intervals ($1 \rightarrow 3 \rightarrow 7 \rightarrow 14 \rightarrow 30$ days), and due dates for adaptive review prompts.
- Added `get_my_notifications(limit, offset, unread_only)` RPC: worker-scoped notification feed with total and unread counts.
- Added `mark_notification_read(notification_id)` and `mark_all_notifications_read()` RPCs: individual and bulk read status modifiers.
- Added `broadcast_drill_alert(drill_id)` RPC: supervisor-triggered broadcast generating emergency drill alerts for all active workers in their assigned mine.
- Added `schedule_spaced_repetition_review(...)` procedure: updates expanding review intervals upon training session completion.
- Updated `sync_training_session(...)` to automatically enqueue spaced repetition review intervals whenever a worker records scenario mistakes.
- Added `generate_spaced_repetition_reminders()` RPC: batch processor creating notifications for overdue reviews.
- Added `generate_certificate_expiry_reminders()` RPC: batch processor creating warnings for certificates expiring within 30, 14, or 7 days.
- RLS Policies: strict worker isolation for notification reading and marking read; supervisor mine-level scoping for drill broadcasts and diagnostics; admin/DGMS audit visibility.

#### Testing Harness
- Created `backend/scripts/test_phase5_notifications.sql`: 9-step automated SQL test suite verifying drill alert broadcast, worker notifications feed, read/unread state updates, cross-worker isolation, spaced repetition scheduling, certificate expiry reminder generation, and RLS.

---

## [0.4.0] — 2026-09-11 — Phase 4: Supervisor Dashboard & Compliance

### Security Fixes (Phase 3 Hardening)
- Created corrective migration `00000000000003_cert_security_hardening.sql`.
- Completely removed symmetric secret dependency from client/Flutter architecture.
- Re-scoped QR code payloads to strictly non-secret verification information (`cert_code` and verification URL).
- Established `verify_certificate(cert_code)` as the single authoritative online verification source.

### Added

#### Database Migration (`00000000000004_supervisor_dashboard.sql`)
- Created `emergency_drills` table for scheduling and recording mine safety evacuation and fire drills, protected by mine-scoped supervisor RLS policies.
- Added `get_supervisor_dashboard_summary()` RPC: computes mine-level KPI cards including total workforce, trained vs. pending vs. overdue counts, average Safety Score, module progress rates (Fire, Gas Leak, Electrical), active and expired certificate totals, and upcoming scheduled drills.
- Added `get_supervisor_workers(search, status, module, limit, offset)` RPC: paginated worker search with status filtering (`trained`, `pending`, `overdue`) and module badges.
- Added `get_supervisor_worker_detail(worker_id)` RPC: detailed worker diagnostics, complete session attempt history, certificate expiry countdowns (`days_to_expiry`), and action mistake telemetry.
- Added `get_mine_weak_areas()` RPC: mine-wide aggregate failure telemetry identifying top hazard points across all AR scenarios.
- Added `get_mine_recent_activity(limit)` RPC: live training activity feed scoped to the supervisor's mine.
- Added `get_compliance_report(mine_id)` RPC: formal DGMS safety training compliance audit generator reporting workforce compliance %, high-risk workers (`safety_score < 60`), and overdue certification lists.

#### Testing Harness
- Created `backend/scripts/test_phase4_supervisor_dashboard.sql`: 10-step automated SQL test suite verifying supervisor tenant boundaries, metric calculations, worker diagnostics, drill RLS, and DGMS audit access.

---

## [0.3.0] — 2026-09-11 — Phase 3: Training & Certificates

### Added

#### Database Migration (`00000000000002_training_and_certs.sql`)
- Created `training_actions` table: granular in-scenario telemetry recording decision name, correctness, response time (ms), standardized mistake tags, and scenario details.
- Added RLS policies for `training_actions`: worker access to own session actions; supervisor access scoped to workers in their assigned mine; DGMS inspector / admin read access.
- Added `generate_qr_hash(p_cert_code, p_worker_id, p_module, p_score)` function: deterministic SHA-256 calculation for offline and online QR code validation.
- Added `issue_training_certificate(p_worker_id, p_session_id, p_module, p_score)` function: server-side certificate issuance allocating unique `SK-YYYY-JH-XXXXX` codes, 1-year expiry, and QR signatures.
- Added `sync_training_session(...)` atomic RPC:
  - Idempotent deduplication on `local_session_id` returning existing records with `already_synced: true`.
  - Authoritative calculation of stars (`calculate_stars`) and passing status (`score >= 60`).
  - Automatic extraction and merging of mistake tags into `weak_areas`.
  - Transactional ingestion of `training_actions`.
  - Automatic Safety Score recomputation via `update_worker_safety_score()`.
  - Automatic consecutive-day streak counter maintenance and `last_trained_at` tracking.
  - Automatic certificate issuance upon passing.

#### Edge Functions & Scripts
- Created `backend/functions/sync-session/index.ts`: HTTP REST wrapper for session ingestion with CORS and error handling.
- Created `backend/scripts/test_phase3_sync_certs.sql`: 6-step automated SQL test suite verifying session sync, deduplication idempotency, fail handling, QR hash determinism, and `training_actions` RLS isolation.

---

## [0.2.0] — 2026-09-11 — Phase 2: Authentication & Worker API

### Added

#### Authentication & Mapping
- Deterministic username normalization: `username.trim().toLowerCase()` with regex `^[a-z0-9._-]{3,30}$`.
- Deterministic internal Supabase Auth identity mapping: `<normalized_username>@armor.internal`.
- Shared TypeScript auth utilities in `backend/functions/_shared/auth.ts`: `normalizeUsername`, `validateUsername`, `usernameToInternalEmail`, `validatePassword`, `sanitizeLanguage`.

#### Database Migration (`00000000000001_auth_and_worker_api.sql`)
- `mines_select_anon` RLS policy: allows unauthenticated reading of active mines during mobile splash/onboarding.
- `handle_new_auth_user()` trigger function: automatic server-side provisioning on `auth.users` insert. Validates username, generates sequential `worker_code` (`WKR-JH-XXXX`), initializes `mine_id = NULL` and `safety_score = 0`. Prevents supervisor self-provisioning via public signup.
- `protect_worker_fields()` trigger function: guards system fields (`id`, `worker_code`, `username`, `safety_score`, `current_streak`, `longest_streak`, `created_at`) from direct alteration by `authenticated` users, raising `IMMUTABLE_FIELD`.
- `set_worker_mine(p_mine_id uuid)` RPC: authenticated worker mine selection/update after registration. Validates mine activity and updates `auth.uid()` worker record only.
- `get_auth_profile()` RPC: authoritative profile and role retrieval. Derives identity strictly from database tables (`supervisors` vs `workers`), never trusting client input.

#### Testing & Security Harness
- `backend/scripts/test_phase2_rls.sql`: automated test script verifying worker profile isolation, supervisor mine filtering, protected field tamper prevention, anonymous restrictions, and RPC behavior.

---

## [0.1.0] — 2026-09-11 — Phase 1: Foundation

### Added

#### Repository Structure
- Initialized GitHub monorepo at `printezz01/A.R.M.O.R`
- Created `backend/` directory for Supabase Edge Functions and server-side scripts
- Created `supabase/` directory for Supabase CLI configuration and migrations
- Added `PROJECT_CONTEXT.md` — full product context, architecture, and phase roadmap
- Added `API_CONTRACT.md` — shared data contracts for all teams
- Added `.env.example` — environment variable template with no secrets
- Linked repository to hosted Supabase project (`ampqcpxpshaiiquqbmmn.supabase.co`)

#### Database Schema (Migration: `00000000000000_init.sql`)
- Created custom enums: `mine_type`, `language_code`, `training_module`, `difficulty_mode`, `supervisor_role`
- Created `mines` table — mine/plant metadata with DGMS incident counts
- Created `workers` table — worker profiles linked to `auth.users`
- Created `training_sessions` table — per-attempt training records
- Created `certificates` table — verifiable QR-signed training certificates
- Created `supervisors` table — dashboard users (supervisors, DGMS inspectors)
- Enabled `pgcrypto` and `pg_trgm` extensions

#### Row Level Security
- Enabled RLS on all 5 tables
- Workers: can only read/write own row
- Training sessions: workers see own sessions; supervisors see their mine's workers
- Certificates: workers see own certs; no direct write access (reserved for server)
- Mines: readable by all authenticated users
- Supervisors: own row only

#### Database Functions
- `get_difficulty_mode(incidents int)` — returns difficulty enum from incident count
- `calculate_stars(score int)` — returns 1–3 star rating from score
- `update_worker_safety_score(worker_uuid uuid)` — recomputes and persists safety_score
- `generate_cert_code()` — generates human-readable `SK-YYYY-JH-NNNNN` certificate ID

#### Database Views
- `leaderboard_view` — ranked worker scores with mine context
- `worker_progress_view` — per-worker, per-module progress for supervisor dashboard

#### Triggers
- `set_updated_at` trigger on `workers`, `mines`, `supervisors` tables

#### Seed Data (`seed.sql`)
- 10 synthetic mines across Jharkhand (coal, steel, mica, uranium types)
- Incident counts derived from DGMS annual report patterns
- 5 synthetic worker profiles (no real phone numbers)
- Sample training sessions and certificates for demonstration

### Infrastructure
- Supabase hosted project configured (no local `supabase start`)
- `supabase/config.toml` linked to hosted project ID

### Security
- No secrets committed to repository
- All configuration via environment variables
- `.env.example` documents required variables without values
- Service-role key NOT included (will be added server-side only when needed in Phase 5+)

---

## Phase Roadmap

| Phase | Version | Status |
|---|---|---|
| Phase 1 — Foundation | 0.1.0 | ✅ Complete |
| Phase 2 — Auth & Worker API | 0.2.0 | ✅ Complete |
| Phase 3 — Training & Certificates | 0.3.0 | ✅ Complete |
| Phase 4 — Supervisor Dashboard API | 0.4.0 | ✅ Complete |
| Phase 5 — Supabase Notifications & Spaced Repetition | 0.5.0 | ✅ Complete |
| Phase 6 — Public Verification & Leaderboards | 0.6.0 | ✅ Complete |
| Phase 7 — Production Hardening | 1.0.0 | ✅ Complete |
| Phase 8 — Flutter Hive Offline Layer (Deferred) | 1.1.0 | Pending |

---

[Unreleased]: https://github.com/printezz01/A.R.M.O.R/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/printezz01/A.R.M.O.R/compare/v0.6.0...v1.0.0
[0.6.0]: https://github.com/printezz01/A.R.M.O.R/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/printezz01/A.R.M.O.R/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/printezz01/A.R.M.O.R/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/printezz01/A.R.M.O.R/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/printezz01/A.R.M.O.R/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/printezz01/A.R.M.O.R/releases/tag/v0.1.0
