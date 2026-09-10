# A.R.M.O.R — API Contract

> **Version:** 1.0.0-phase1
> **Status:** Draft — Phase 1 (Schema Foundation)
> **Last Updated:** September 2026

This document defines the shared data contracts between the Flutter mobile app, the React web dashboard, and the Supabase backend. All teams MUST treat this as the source of truth for field names, types, and API shapes.

---

## 1. Database Tables (Supabase / PostgreSQL)

### 1.1 `mines`

Stores static mine/plant metadata sourced from DGMS records.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | `uuid` | NO | Primary key |
| `name` | `text` | NO | Mine name (e.g., "Jharia Coalfield") |
| `district` | `text` | NO | District name (e.g., "Dhanbad") |
| `state` | `text` | NO | State (always "Jharkhand" for now) |
| `type` | `mine_type` (enum) | NO | `coal`, `steel`, `mica`, `uranium`, `other` |
| `latitude` | `numeric(9,6)` | YES | GPS latitude |
| `longitude` | `numeric(9,6)` | YES | GPS longitude |
| `worker_count` | `integer` | YES | Approximate worker count |
| `fire_incidents_3yr` | `integer` | NO | Fire incidents in last 3 years |
| `gas_incidents_3yr` | `integer` | NO | Gas leak incidents in last 3 years |
| `electrical_incidents_3yr` | `integer` | NO | Electrical incidents in last 3 years |
| `is_active` | `boolean` | NO | Whether mine is currently active |
| `created_at` | `timestamptz` | NO | Row creation timestamp |
| `updated_at` | `timestamptz` | NO | Last update timestamp |

**Computed difficulty** (via DB function `get_difficulty_mode`):
- `fire_incidents_3yr >= 8` → `hard` (3 levels)
- `fire_incidents_3yr >= 4` → `medium` (2 levels)
- `< 4` → `easy` (2 levels — minimum always 2)

---

### 1.2 `workers`

One row per registered mine worker.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | `uuid` | NO | Primary key, matches `auth.users.id` |
| `phone` | `text` | NO | Phone number (used for OTP auth) |
| `full_name` | `text` | NO | Worker's full name |
| `mine_id` | `uuid` | YES (FK) | References `mines.id` |
| `language` | `language_code` (enum) | NO | `hi` (Hindi), `sat` (Santali), `en` (English) |
| `safety_score` | `integer` | NO | Computed score 0–100, updated after each session |
| `current_streak` | `integer` | NO | Consecutive training days |
| `longest_streak` | `integer` | NO | Historical best streak |
| `last_trained_at` | `timestamptz` | YES | Timestamp of last completed session |
| `badges` | `text[]` | NO | Array of earned badge IDs |
| `avatar_url` | `text` | YES | Supabase Storage URL for profile photo |
| `is_active` | `boolean` | NO | Soft delete flag |
| `created_at` | `timestamptz` | NO | Registration timestamp |
| `updated_at` | `timestamptz` | NO | Last update timestamp |

---

### 1.3 `training_sessions`

Records each completed training attempt.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | `uuid` | NO | Primary key |
| `worker_id` | `uuid` | NO (FK) | References `workers.id` |
| `mine_id` | `uuid` | NO (FK) | References `mines.id` |
| `module` | `training_module` (enum) | NO | `fire`, `gas_leak`, `electrical` |
| `difficulty` | `difficulty_mode` (enum) | NO | `easy`, `medium`, `hard` |
| `score` | `integer` | NO | Final score 0–100 |
| `stars` | `smallint` | NO | 1–3 stars based on score |
| `passed` | `boolean` | NO | `true` if score >= 60 |
| `weak_areas` | `text[]` | YES | Tags of weak performance areas |
| `levels_completed` | `integer` | NO | Number of levels finished |
| `duration_seconds` | `integer` | YES | Total time taken |
| `synced_from_local` | `boolean` | NO | Whether synced from Hive |
| `local_session_id` | `text` | YES | Hive-generated ID for dedup |
| `created_at` | `timestamptz` | NO | Session completion timestamp |

**Star Rating Logic:**
- `score >= 85` → 3 stars
- `score >= 70` → 2 stars
- `score >= 60` → 1 star (passed)
- `score < 60` → 0 stars (failed)

---

### 1.4 `certificates`

Generated after a worker passes a module.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | `uuid` | NO | Primary key |
| `cert_code` | `text` | NO | Human-readable: `SK-YYYY-JH-NNNNN` |
| `worker_id` | `uuid` | NO (FK) | References `workers.id` |
| `session_id` | `uuid` | NO (FK) | References `training_sessions.id` |
| `module` | `training_module` (enum) | NO | Which module this cert covers |
| `score` | `integer` | NO | Score at time of certificate issue |
| `issued_at` | `timestamptz` | NO | Certificate issue timestamp |
| `expires_at` | `timestamptz` | NO | 1 year after `issued_at` |
| `qr_hash` | `text` | NO | SHA-256 hash for offline verification |
| `is_revoked` | `boolean` | NO | Whether cert has been revoked |
| `created_at` | `timestamptz` | NO | Row creation timestamp |

**Unique constraint:** `(worker_id, module)` — one active cert per module per worker (old certs not deleted, just superseded by newest `issued_at`).

---

### 1.5 `supervisors`

Mine supervisors who access the web dashboard.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | `uuid` | NO | Primary key, matches `auth.users.id` |
| `full_name` | `text` | NO | Supervisor name |
| `phone` | `text` | NO | Phone number |
| `mine_id` | `uuid` | NO (FK) | References `mines.id` |
| `role` | `supervisor_role` (enum) | NO | `supervisor`, `dgms_inspector`, `admin` |
| `is_active` | `boolean` | NO | Account active flag |
| `created_at` | `timestamptz` | NO | Registration timestamp |
| `updated_at` | `timestamptz` | NO | Last update timestamp |

---

## 2. Database Enums

```sql
mine_type:      coal | steel | mica | uranium | other
language_code:  hi | sat | en
training_module: fire | gas_leak | electrical
difficulty_mode: easy | medium | hard
supervisor_role: supervisor | dgms_inspector | admin
```

---

## 3. Database Views

### 3.1 `leaderboard_view`

Computed from `training_sessions` — NOT a real table.

| Column | Source |
|---|---|
| `worker_id` | `workers.id` |
| `full_name` | `workers.full_name` |
| `mine_name` | `mines.name` |
| `safety_score` | `workers.safety_score` |
| `total_sessions` | COUNT of sessions |
| `modules_passed` | COUNT of passed sessions |
| `current_streak` | `workers.current_streak` |
| `rank` | `DENSE_RANK()` by safety_score DESC |

### 3.2 `worker_progress_view`

Per-worker, per-module progress summary for the supervisor dashboard.

---

## 4. Database Functions

| Function | Returns | Purpose |
|---|---|---|
| `get_difficulty_mode(incidents int)` | `difficulty_mode` | Compute difficulty from incident count |
| `calculate_stars(score int)` | `smallint` | Return 1–3 stars from score |
| `update_worker_safety_score(worker_uuid uuid)` | `void` | Recalculate and update worker safety_score |
| `generate_cert_code()` | `text` | Generate `SK-YYYY-JH-NNNNN` formatted code |

---

## 5. RLS Policy Summary

| Table | Worker can read | Worker can write | Supervisor can read | Notes |
|---|---|---|---|---|
| `mines` | All rows | No | All rows | Public reference data |
| `workers` | Own row only | Own row only | Mine's workers only | RLS on `mine_id` |
| `training_sessions` | Own rows only | Own rows only | Mine's workers' sessions | RLS on `worker_id` |
| `certificates` | Own rows only | No (server-side) | Mine's workers' certs | Write via function only |
| `supervisors` | No | No | Own row only | — |

---

## 6. Supabase Storage Buckets

| Bucket | Access | Contents |
|---|---|---|
| `certificates` | Private | Generated PDF certificates |
| `avatars` | Public | Worker profile photos |

---

## 7. Future API Endpoints (Phase 2+)

These will be Supabase Edge Functions (Deno/TypeScript):

| Endpoint | Phase | Description |
|---|---|---|
| `POST /functions/v1/sync-session` | Phase 3 | Receive offline-queued training sessions |
| `POST /functions/v1/issue-certificate` | Phase 3 | Generate + sign certificate, return QR hash |
| `GET /functions/v1/verify-certificate` | Phase 6 | Public certificate verification endpoint |
| `POST /functions/v1/send-reminders` | Phase 5 | Trigger FCM push notifications |
| `GET /functions/v1/compliance-report` | Phase 4 | Generate PDF compliance report data |

---

*This contract is version-controlled. All changes must be reflected in CHANGELOG.md.*
