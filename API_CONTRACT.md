# A.R.M.O.R — API Contract

> **Version:** 1.1.0-phase1-rev2
> **Status:** Revised — Phone OTP removed, username/password auth, normalized badges
> **Last Updated:** September 2026

This document defines the shared data contracts between the Flutter mobile app, the React web dashboard, and the Supabase backend. All teams MUST treat this as the source of truth.

---

## 1. Authentication Model (Locked)

**Auth mechanism: Username + Password via Supabase Auth.**

- NO phone OTP. NO SMS. NO email OTP.
- Workers and supervisors authenticate with `username` + password.
- Phone numbers are optional contact fields stored on the profile — not used for login.
- Worker accounts are created server-side after signup (Phase 2 `handle_new_user` trigger).

---

## 2. Identity Fields

| Field | Table | Type | Description |
|---|---|---|---|
| `id` | workers, supervisors | UUID | = auth.users.id. Internal identity. Used in all RLS checks. |
| `worker_code` | workers | TEXT | System-generated WKR-JH-XXXX. Human-readable. Shown on UI and certificates. |
| `username` | workers, supervisors | TEXT | Unique login handle. NOT an email address. |
| `cert_code` | certificates | TEXT | Human-readable cert ID: SK-YYYY-JH-NNNNN. Encoded in QR code. |

---

## 3. Database Tables

### 3.1 `mines`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK |
| `name` | text | NO | Mine name |
| `district` | text | NO | District |
| `state` | text | NO | Default 'Jharkhand' |
| `type` | mine_type | NO | coal/steel/mica/uranium/other |
| `latitude` | numeric(9,6) | YES | Approx GPS lat |
| `longitude` | numeric(9,6) | YES | Approx GPS lng |
| `worker_count` | integer | YES | Approx headcount |
| `fire_incidents_3yr` | integer | NO | Fire incidents, last 3 years |
| `gas_incidents_3yr` | integer | NO | Gas incidents, last 3 years |
| `electrical_incidents_3yr` | integer | NO | Electrical incidents, last 3 years |
| `is_active` | boolean | NO | Active flag |
| `created_at` | timestamptz | NO | |
| `updated_at` | timestamptz | NO | Auto-maintained by trigger |

---

### 3.2 `workers`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK = auth.users.id |
| `worker_code` | text | NO | UNIQUE. Auto-generated WKR-JH-XXXX |
| `username` | text | NO | UNIQUE. Login handle |
| `full_name` | text | NO | Display name |
| `phone` | text | YES | Optional contact only — NOT used for auth |
| `mine_id` | uuid | YES | FK to mines. Nullable — may be unset at registration |
| `language` | language_code | NO | Default 'hi' |
| `safety_score` | integer | NO | 0-100. See algorithm below |
| `current_streak` | integer | NO | Consecutive training days |
| `longest_streak` | integer | NO | Historical best streak |
| `last_trained_at` | timestamptz | YES | Timestamp of last completed session |
| `avatar_url` | text | YES | Supabase Storage URL |
| `is_active` | boolean | NO | Soft delete |
| `created_at` | timestamptz | NO | |
| `updated_at` | timestamptz | NO | Auto-maintained by trigger |

> workers.badges is NOT a column — badges are in the normalized worker_badges table.

---

### 3.3 `supervisors`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK = auth.users.id |
| `username` | text | NO | UNIQUE. Login handle |
| `full_name` | text | NO | Display name |
| `phone` | text | YES | Optional contact only — NOT used for auth |
| `mine_id` | uuid | NO | FK to mines. NOT NULL — must be assigned at provisioning |
| `role` | supervisor_role | NO | supervisor/dgms_inspector/admin |
| `is_active` | boolean | NO | |
| `created_at` | timestamptz | NO | |
| `updated_at` | timestamptz | NO | Auto-maintained by trigger |

---

### 3.4 `training_sessions`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK |
| `worker_id` | uuid | NO | FK to workers |
| `mine_id` | uuid | NO | FK to mines |
| `module` | training_module | NO | fire/gas_leak/electrical |
| `difficulty` | difficulty_mode | NO | easy/medium/hard |
| `score` | integer | NO | 0-100 |
| `stars` | smallint | NO | 0-3 (see star thresholds) |
| `passed` | boolean | NO | score >= 60 |
| `weak_areas` | text[] | YES | Tags of weak areas |
| `levels_completed` | integer | NO | Levels finished in this session |
| `duration_seconds` | integer | YES | Total session time |
| `synced_from_local` | boolean | NO | TRUE if synced from Hive |
| `local_session_id` | text | YES | Client dedup ID |
| `created_at` | timestamptz | NO | |

**Star rating thresholds (locked):**
- score >= 90 → 3 stars
- score >= 75 → 2 stars
- score >= 60 → 1 star
- score <  60 → 0 stars (failed)

---

### 3.5 `certificates`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK (internal only) |
| `cert_code` | text | NO | UNIQUE. SK-YYYY-JH-NNNNN |
| `worker_id` | uuid | NO | FK to workers |
| `session_id` | uuid | NO | FK to training_sessions |
| `module` | training_module | NO | |
| `score` | integer | NO | Score at cert issue |
| `issued_at` | timestamptz | NO | |
| `expires_at` | timestamptz | NO | issued_at + 1 year |
| `qr_hash` | text | NO | SHA-256(cert_code + worker_id + module + score + CERT_HASH_SECRET) |
| `is_revoked` | boolean | NO | |
| `created_at` | timestamptz | NO | |

> There is NO anon RLS policy on this table. Public verification uses verify_certificate() only.

---

### 3.6 `badges`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | text | NO | PK. Slug e.g. 'first_responder' |
| `name` | text | NO | Display name |
| `description` | text | YES | |
| `icon_code` | text | YES | App icon key or emoji |
| `module` | training_module | YES | NULL = not module-specific |
| `required_stars` | smallint | YES | Minimum stars to earn |
| `created_at` | timestamptz | NO | |

---

### 3.7 `worker_badges`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK |
| `worker_id` | uuid | NO | FK to workers |
| `badge_id` | text | NO | FK to badges |
| `earned_at` | timestamptz | NO | When the badge was granted |

UNIQUE constraint: `(worker_id, badge_id)` — each badge earned once per worker.

---

## 4. Database Enums

```sql
mine_type:       coal | steel | mica | uranium | other
language_code:   hi | sat | en
training_module: fire | gas_leak | electrical
difficulty_mode: easy | medium | hard
supervisor_role: supervisor | dgms_inspector | admin
```

---

## 5. Database Functions

| Function | Returns | Purpose |
|---|---|---|
| `get_difficulty_mode(incidents int)` | difficulty_mode | Compute difficulty from incident count |
| `calculate_stars(score int)` | smallint | 0-3 stars from score (locked thresholds) |
| `update_worker_safety_score(uuid)` | void | Recompute + persist safety_score (avg of module means) |
| `generate_worker_code()` | text | Generate WKR-JH-XXXX from sequence |
| `generate_cert_code()` | text | Generate SK-YYYY-JH-NNNNN from sequence |
| `verify_certificate(cert_code text)` | TABLE | Public-safe cert lookup. Anon-callable SECURITY DEFINER. |
| `trigger_set_updated_at()` | trigger | Auto-update updated_at on row update |

---

## 6. Safety Score Algorithm (Locked Contract)

```
safety_score = ROUND(
  AVG(
    AVG(score) per module   -- averaging all PASSED sessions per module
    across all modules with at least one passed session
  )
)
```

Examples:
- Fire sessions: 78, 92 (both passed) → fire_mean = 85.0
- Gas sessions: 86 (passed) → gas_mean = 86.0
- safety_score = ROUND((85.0 + 86.0) / 2) = ROUND(85.5) = 86

NOT the maximum score per module. All passed attempts count.

---

## 7. Certificate Verification Contract

### Online (via SECURITY DEFINER function):
```
SELECT * FROM verify_certificate('SK-2026-JH-00001');
```
Returns: cert_code, worker_name, worker_code, mine_name, module, score, issued_at, expires_at, is_valid
Does NOT return: id, worker_id (UUID), qr_hash, session_id
Revoked certs return 0 rows.

### Offline (Flutter):
```
expected_hash = SHA256(cert_code + worker_id + module + score + CERT_HASH_SECRET)
compare against qr_hash embedded in QR code data
```

---

## 8. RLS Policy Summary

| Table | Worker (own) | Supervisor (mine scope) | DGMS/Admin | Anon | Service Role |
|---|---|---|---|---|---|
| mines | SELECT | SELECT | SELECT | - | INSERT, UPDATE |
| workers | SELECT, UPDATE | SELECT | SELECT | - | INSERT |
| supervisors | SELECT (own) | - | SELECT | - | INSERT, UPDATE |
| training_sessions | SELECT, INSERT | SELECT | SELECT | - | - |
| certificates | SELECT | SELECT | SELECT | - (use function) | INSERT, UPDATE |
| badges | SELECT | SELECT | SELECT | - | INSERT, UPDATE |
| worker_badges | SELECT | SELECT | SELECT | - | INSERT |

---

## 9. Supabase Storage Buckets (Phase 3+)

| Bucket | Access | Contents |
|---|---|---|
| `certificates` | Private | Generated PDF certificate files |
| `avatars` | Public | Worker profile photos (resized) |

---

## 10. Future Edge Functions (Phase 3+)

| Function | Phase | Description |
|---|---|---|
| `POST /functions/v1/sync-session` | 3 | Receive offline-queued training sessions |
| `POST /functions/v1/issue-certificate` | 3 | Generate + sign certificate, return QR data |
| `POST /functions/v1/send-reminders` | 5 | Trigger FCM push notifications |
| `GET /functions/v1/compliance-report` | 4 | Generate compliance report data |

> verify_certificate is a DB function (not Edge Function) — callable via Supabase RPC.

---

*This contract is version-controlled. All changes reflected in CHANGELOG.md.*