# A.R.M.O.R — Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

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
| Phase 2 — Auth & Worker API | 0.2.0 | Pending |
| Phase 3 — Training & Certificates | 0.3.0 | Pending |
| Phase 4 — Supervisor Dashboard API | 0.4.0 | Pending |
| Phase 5 — FCM + Spaced Repetition | 0.5.0 | Pending |
| Phase 6 — Edge Functions | 0.6.0 | Pending |
| Phase 7 — Production Hardening | 1.0.0 | Pending |

---

[Unreleased]: https://github.com/printezz01/A.R.M.O.R/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/printezz01/A.R.M.O.R/releases/tag/v0.1.0
