# A.R.M.O.R — API Contract

> **Version:** 1.7.0
> **Status:** Phase 7 Complete — Backend Production Hardened & Validated
> **Last Updated:** September 2026

This document defines the shared data contracts between the Flutter mobile app, the React web dashboard, and the Supabase backend. All teams MUST treat this as the source of truth.

---

## 1. Authentication Architecture (Locked)

**Auth mechanism: Username + Password via Supabase Auth.**

- **NO Phone OTP. NO SMS / DLT gateways. NO Email OTP.**
- All clients (mobile app, supervisor web dashboard) authenticate using `username` and `password`.
- Passwords are never stored in application tables; they are handled strictly by Supabase Auth (`auth.users`).
- Phone numbers are optional profile contact fields only — never used for login or verification.
- Service-role keys are never embedded or exposed to mobile or browser clients.

### 1.1 Deterministic Username Normalization
Before performing any authentication or registration request, the client MUST normalize the username:
1. **Trim whitespace**: Strip leading and trailing spaces (`username.trim()`).
2. **Lowercase**: Convert all characters to lowercase (`username.toLowerCase()`).
3. **Format constraint**: Must match regex `^[a-z0-9._-]{3,30}$` (3 to 30 characters consisting of letters, digits, dots, hyphens, and underscores). No spaces or special symbols allowed.

### 1.2 Deterministic Internal Supabase Auth Mapping
Supabase Auth uses an email-formatted identifier for password-based credentials. To prevent third-party email dependencies while keeping authentication standard and robust, the normalized username is mapped deterministically:

```
internal_email = `${normalized_username}@armor.internal`
```

Example:
- User inputs: ` Raju.Hembram `
- Normalized username: `raju.hembram`
- Internal Supabase Auth identity: `raju.hembram@armor.internal`

Both Worker and Supervisor authentication use this exact deterministic mapping.

---

## 2. Identity & Roles

| Field | Table | Type | Description |
|---|---|---|---|
| `id` | workers, supervisors | UUID | = `auth.users.id`. Internal identity. Used in all RLS checks. |
| `worker_code` | workers | TEXT | System-generated `WKR-JH-XXXX`. Human-readable. Shown on UI and certificates. |
| `username` | workers, supervisors | TEXT | Unique login handle. Lowercase, normalized. |
| `role` | authoritative | TEXT | Determined strictly from backend DB tables: `'worker'` if in `workers`; `'supervisor' \| 'dgms_inspector' \| 'admin'` if in `supervisors`. |
| `cert_code` | certificates | TEXT | Human-readable cert ID: `SK-YYYY-JH-NNNNN`. Encoded in QR code. |

---

## 3. Auth & Worker Onboarding API Contracts

### 3.1 Worker Registration
Workers register on the Flutter app without selecting a mine.

- **Endpoint**: `POST /auth/v1/signup`
- **Request Headers**: `apikey: <anon_key>`, `Content-Type: application/json`
- **Request Payload**:
  ```json
  {
    "email": "raju.hembram@armor.internal",
    "password": "SecurePassword123!",
    "data": {
      "full_name": "Raju Hembram",
      "username": "raju.hembram",
      "language": "sat",
      "phone": "+919876543210",
      "role": "worker"
    }
  }
  ```
- **Backend Execution**:
  1. Supabase Auth creates the user in `auth.users`.
  2. Database trigger `handle_new_auth_user()` runs with `SECURITY DEFINER`.
  3. Validates username uniqueness across `workers` and `supervisors`.
  4. Automatically allocates sequential `worker_code` (e.g. `WKR-JH-0006`).
  5. Inserts into `public.workers` with `mine_id = NULL`, `safety_score = 0`, `current_streak = 0`, `longest_streak = 0`.
- **Response**: Supabase Auth Session object (includes `access_token`, `refresh_token`, and user metadata).

### 3.2 Worker & Supervisor Login
Returning workers and supervisors log in with their username and password.

- **Endpoint**: `POST /auth/v1/token?grant_type=password`
- **Request Headers**: `apikey: <anon_key>`, `Content-Type: application/json`
- **Request Payload**:
  ```json
  {
    "email": "raju.hembram@armor.internal",
    "password": "SecurePassword123!"
  }
  ```
- **Response**:
  ```json
  {
    "access_token": "eyJhbGciOi...",
    "token_type": "bearer",
    "expires_in": 3600,
    "refresh_token": "...",
    "user": { ... }
  }
  ```

### 3.3 Authoritative Profile & Role Resolution
Clients resolve their profile and role immediately after authentication. The role is derived strictly from database tables, never from user input or JWT claims.

- **Endpoint**: `POST /rest/v1/rpc/get_auth_profile`
- **Request Headers**:
  - `apikey: <anon_key>`
  - `Authorization: Bearer <access_token>`
- **Response (Worker)**:
  ```json
  {
    "role": "worker",
    "user_id": "b1b2c3d4-1001-1001-1001-000000000001",
    "worker_code": "WKR-JH-0001",
    "username": "raju.hembram",
    "full_name": "Raju Hembram",
    "phone": null,
    "language": "sat",
    "mine_id": null,
    "mine_name": null,
    "safety_score": 0,
    "current_streak": 0,
    "longest_streak": 0,
    "last_trained_at": null,
    "avatar_url": null,
    "is_active": true
  }
  ```
- **Response (Supervisor)**:
  ```json
  {
    "role": "supervisor",
    "user_id": "33333333-3333-3333-3333-333333333333",
    "username": "rajesh.sharma",
    "full_name": "Rajesh Sharma",
    "phone": "+919800000001",
    "mine_id": "a1b2c3d4-0001-0001-0001-000000000001",
    "mine_name": "Jharia Coalfield",
    "mine_district": "Dhanbad",
    "is_active": true
  }
  ```

### 3.4 Public Mine List (For Onboarding)
Mines are readable by both unauthenticated (`anon`) and authenticated users during onboarding.

- **Endpoint**: `GET /rest/v1/mines?is_active=eq.true&select=id,name,district,state,type,fire_incidents_3yr,gas_incidents_3yr,electrical_incidents_3yr`
- **Request Headers**: `apikey: <anon_key>`

### 3.5 Authenticated Mine Selection
After registration, the worker selects their mine. This requires authentication and modifies only the authenticated worker's row.

- **Endpoint**: `POST /rest/v1/rpc/set_worker_mine`
- **Request Headers**:
  - `apikey: <anon_key>`
  - `Authorization: Bearer <access_token>`
  - `Content-Type: application/json`
- **Request Payload**:
  ```json
  {
    "p_mine_id": "a1b2c3d4-0001-0001-0001-000000000001"
  }
  ```
- **Response**:
  ```json
  {
    "id": "b1b2c3d4-1001-1001-1001-000000000001",
    "worker_code": "WKR-JH-0001",
    "username": "raju.hembram",
    "full_name": "Raju Hembram",
    "language": "sat",
    "mine_id": "a1b2c3d4-0001-0001-0001-000000000001",
    "mine_name": "Jharia Coalfield",
    "mine_district": "Dhanbad",
    "mine_type": "coal",
    "safety_score": 0,
    "updated_at": "2026-09-11T15:30:00Z"
  }
  ```

### 3.6 Field Protection on Worker Updates
Direct updates by workers to `public.workers` are governed by RLS policy `workers_update_own` and guarded by trigger `protect_worker_fields`:
- **Allowed worker updates**: `mine_id`, `language`, `phone`, `avatar_url`, `is_active`.
- **Protected fields (immutable via client)**: `id`, `worker_code`, `username`, `safety_score`, `current_streak`, `longest_streak`, `created_at`.
- Any attempt to alter protected fields raises exception: `IMMUTABLE_FIELD`.

### 3.7 Training Session Sync & Certificate Issuance
Workers sync training attempts either in real time or in batches from Hive local storage when connectivity is restored.

- **RPC Endpoint**: `POST /rest/v1/rpc/sync_training_session`
- **Edge Function Endpoint**: `POST /functions/v1/sync-session`
- **Request Headers**:
  - `apikey: <anon_key>`
  - `Authorization: Bearer <access_token>`
  - `Content-Type: application/json`
- **Request Payload**:
  ```json
  {
    "p_module": "fire",
    "p_difficulty": "hard",
    "p_score": 88,
    "p_mine_id": "a1b2c3d4-0001-0001-0001-000000000001",
    "p_weak_areas": ["extinguisher_selection"],
    "p_levels_completed": 3,
    "p_duration_seconds": 540,
    "p_local_session_id": "hive-uuid-987162-ab3",
    "p_synced_from_local": true,
    "p_actions": [
      {
        "action_name": "alarm_raised",
        "is_correct": true,
        "response_time_ms": 1100
      },
      {
        "action_name": "extinguisher_select",
        "is_correct": false,
        "response_time_ms": 3200,
        "mistake_tag": "wrong_extinguisher_class",
        "details": { "selected": "water", "required": "co2" }
      }
    ]
  }
  ```
- **Sync Behavior & Authoritative Processing**:
  1. **Idempotency**: If `p_local_session_id` already exists for the authenticated worker, returns the existing session and certificate with `"already_synced": true`. No duplicate records, streak updates, or certificates are created.
  2. **Authoritative Stars & Pass Evaluation**:
     - `stars = calculate_stars(score)` ($90+=3\star$, $75\text{--}89=2\star$, $60\text{--}74=1\star$, $<60=0\star$).
     - `passed = (score >= 60)`.
  3. **Weak Areas**: Combined and deduplicated from `p_weak_areas` and any actions where `is_correct = false` having a `mistake_tag`.
  4. **Action Telemetry**: Each action is ingested into `training_actions` for supervisor weak-spot analytics.
  5. **Safety Score**: Automatically recomputed across all passed session means via `update_worker_safety_score()`.
  6. **Streak Management**: Evaluates `last_trained_at` (IST timezone); increments streak if trained consecutive days, preserves streak if same day, resets to 1 if missed.
  7. **Certificate Issuance**: If `passed = true`, automatically issues a SHA-256 signed QR certificate valid for 1 year.
- **Success Response (Passing Attempt)**:
  ```json
  {
    "already_synced": false,
    "session_id": "c1c2c3d4-2001-2001-2001-000000000001",
    "worker_id": "b1b2c3d4-1001-1001-1001-000000000001",
    "mine_id": "a1b2c3d4-0001-0001-0001-000000000001",
    "module": "fire",
    "difficulty": "hard",
    "score": 88,
    "stars": 2,
    "passed": true,
    "weak_areas": ["extinguisher_selection", "wrong_extinguisher_class"],
    "levels_completed": 3,
    "duration_seconds": 540,
    "certificate": {
      "id": "d1d2d3d4-3001-3001-3001-000000000001",
      "cert_code": "SK-2026-JH-00001",
      "worker_id": "b1b2c3d4-1001-1001-1001-000000000001",
      "session_id": "c1c2c3d4-2001-2001-2001-000000000001",
      "module": "fire",
      "score": 88,
      "issued_at": "2026-09-11T20:55:00Z",
      "expires_at": "2027-09-11T20:55:00Z",
      "qr_hash": "a8fbc...",
      "is_revoked": false
    },
    "safety_score": 88,
    "current_streak": 1,
    "longest_streak": 1,
    "created_at": "2026-09-11T20:55:00Z"
  }
  ```
- **Success Response (Duplicate Sync Attempt)**:
  ```json
  {
    "already_synced": true,
    "session_id": "c1c2c3d4-2001-2001-2001-000000000001",
    "module": "fire",
    "score": 88,
    "stars": 2,
    "passed": true,
    "weak_areas": ["extinguisher_selection", "wrong_extinguisher_class"],
    "certificate": { ... },
    "safety_score": 88,
    "current_streak": 1,
    "message": "Session already processed."
  }
  ```

### 3.8 Supervisor Dashboard & Compliance APIs
The React Web Dashboard communicates exclusively with these mine-scoped RPCs using standard authenticated JWTs. All queries enforce supervisor tenant boundaries (`supervisors.mine_id`).

#### 3.8.1 Dashboard Summary KPIs
- **Endpoint**: `POST /rest/v1/rpc/get_supervisor_dashboard_summary`
- **Headers**: `Authorization: Bearer <supervisor_jwt>`, `apikey: <anon_key>`
- **Response**:
  ```json
  {
    "mine_id": "a1b2c3d4-0001-0001-0001-000000000001",
    "mine_name": "Jharia Coalfield",
    "role": "supervisor",
    "total_workers": 120,
    "trained_workers": 85,
    "pending_workers": 15,
    "overdue_workers": 20,
    "average_safety_score": 78,
    "fire_progress": { "passed_count": 82, "percentage": 68.3 },
    "gas_progress": { "passed_count": 74, "percentage": 61.7 },
    "electrical_progress": { "passed_count": 45, "percentage": 37.5 },
    "active_certificates_count": 92,
    "expired_certificates_count": 8,
    "upcoming_drills_count": 2,
    "generated_at": "2026-09-11T21:00:00Z"
  }
  ```

#### 3.8.2 Worker Search & Listing
- **Endpoint**: `POST /rest/v1/rpc/get_supervisor_workers`
- **Payload**:
  ```json
  {
    "p_search": "Raju",
    "p_status": "trained",
    "p_limit": 20,
    "p_offset": 0
  }
  ```
- **Response**: Paginated JSON `{ "total_count": 1, "workers": [ ... ] }`.

#### 3.8.3 Worker Detailed History & Diagnostics
- **Endpoint**: `POST /rest/v1/rpc/get_supervisor_worker_detail`
- **Payload**: `{ "p_worker_id": "b1b2c3d4-1001-1001-1001-000000000001" }`
- **Response**: Complete worker history, training attempts, mistake tag breakdown, and active certificates with `days_to_expiry`.

#### 3.8.4 Mine Weak-Area Failure Analytics
- **Endpoint**: `POST /rest/v1/rpc/get_mine_weak_areas`
- **Response**: Ranked failure patterns across all scenario attempts in the mine (e.g. `wrong_extinguisher_class`, `delayed_alarm`).

#### 3.8.5 Live Training Activity Feed
- **Endpoint**: `POST /rest/v1/rpc/get_mine_recent_activity`
- **Payload**: `{ "p_limit": 15 }`
- **Response**: Latest training sessions completed across the supervisor's mine.

#### 3.8.6 DGMS Audit & Compliance Report
- **Endpoint**: `POST /rest/v1/rpc/get_compliance_report`
- **Payload**: `{ "p_mine_id": null }` (Supervisors audit their own mine; DGMS inspectors may specify any mine ID).
- **Response**: Formal audit document containing compliance rate %, high-risk workers (`safety_score < 60`), overdue workers, and risk tier.

---

### 3.9 Certificate Verification Security Model (Hardened)
- **Authoritative Issuance**: The Supabase backend is the sole authority issuing certificates.
- **Zero Client Secrets**: No symmetric signing secret or private key exists in Flutter, React, Hive, or client environment variables.
- **QR Code Content**: The physical/digital QR code encodes **only public verification information**:
  - `cert_code`: Unique identifier (e.g., `SK-2026-JH-00001`)
  - `verification_url`: Canonical URL (`https://armor.gov.in/verify?code=SK-2026-JH-00001`)
- **Authoritative Online Verification**: QR scanners open or call `verify_certificate(cert_code)` (SECURITY DEFINER, anon-callable), returning official worker, mine, and expiration status.
- **Integrity Checksum**: Database `qr_hash` is an internal backend tamper-evident digest.

---

### 3.10 Notifications & Spaced Repetition APIs (Pure Supabase)

> **Architectural Decision**: Firebase Cloud Messaging (FCM) is completely removed. Notifications operate via **Supabase Realtime** pub/sub for active/in-app delivery and **PostgreSQL tables** (`notifications`) for offline reconnect sync and persistent history.

#### 3.10.1 Realtime In-App Subscription (Flutter)
When the worker app is online and running, subscribe to user-scoped Postgres change events:
```dart
final channel = supabase
    .channel('worker_notifications_${workerId}')
    .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'notifications',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'worker_id',
        value: workerId,
      ),
      callback: (payload) {
        final notification = payload.newRecord;
        // Display in-app banner / emergency alert dialog
      },
    )
    .subscribe();
```

#### 3.10.2 Fetch Pending / Historical Notifications (On Open & Reconnect)
- **Endpoint**: `POST /rest/v1/rpc/get_my_notifications`
- **Headers**: `Authorization: Bearer <worker_jwt>`, `apikey: <anon_key>`
- **Payload**:
  ```json
  {
    "p_limit": 20,
    "p_offset": 0,
    "p_unread_only": false
  }
  ```
- **Response**:
  ```json
  {
    "total_count": 2,
    "unread_count": 1,
    "notifications": [
      {
        "id": "e1e2e3d4-5001-5001-5001-000000000001",
        "type": "drill_alert",
        "title": "URGENT: Mine Safety Drill Scheduled",
        "body": "Mandatory Gas Leak Safety Drill has been scheduled.",
        "payload": {
          "drill_id": "f1f2f3d4-4001-4001-4001-000000000001",
          "drill_type": "gas_leak",
          "scheduled_date": "2026-09-15"
        },
        "is_read": false,
        "read_at": null,
        "created_at": "2026-09-11T21:10:00Z"
      }
    ]
  }
  ```

#### 3.10.3 Mark Notifications Read
- **Single Notification**: `POST /rest/v1/rpc/mark_notification_read` with `{ "p_notification_id": "..." }`
- **All Notifications**: `POST /rest/v1/rpc/mark_all_notifications_read` with `{}`
- **Response**: `{ "success": true, "marked_count": 1 }`

#### 3.10.4 Broadcast Drill Alert (Supervisor RPC)
- **Endpoint**: `POST /rest/v1/rpc/broadcast_drill_alert`
- **Headers**: `Authorization: Bearer <supervisor_jwt>`, `apikey: <anon_key>`
- **Payload**: `{ "p_drill_id": "f1f2f3d4-4001-4001-4001-000000000001" }`
- **Behavior**: Verifies that the supervisor manages the mine assigned to the drill. Atomically creates a `drill_alert` notification for all active workers in that mine. Rows are streamed live over Supabase Realtime to connected mobile apps and queued for disconnected workers.
- **Response**:
  ```json
  {
    "success": true,
    "drill_id": "f1f2f3d4-4001-4001-4001-000000000001",
    "recipients_count": 42,
    "message": "Drill alert broadcast to 42 workers."
  }
  ```

#### 3.10.5 Spaced Repetition Scheduling
- **Progression**: Leitner-style expanding review intervals: $1 \rightarrow 3 \rightarrow 7 \rightarrow 14 \rightarrow 30$ days.
- **Review Triggering**: Ingested automatically during `sync_training_session(...)` based on weak areas and failed actions.
- **Reminder Generation RPC**: `POST /rest/v1/rpc/generate_spaced_repetition_reminders` (can be executed on a schedule or during maintenance). Queues `spaced_repetition` notifications for schedules where `next_review_due <= CURRENT_DATE`.
- **Certificate Expiry Reminder RPC**: `POST /rest/v1/rpc/generate_certificate_expiry_reminders` queues warning notifications for certificates expiring within 30, 14, or 7 days.

---

### 3.11 Public Certificate Verification API

Publicly accessible certificate verification endpoint for physical QR scanners, WhatsApp certificate shares, and DGMS auditors.

- **Edge Function Endpoint**: `GET /functions/v1/verify-certificate?code=SK-YYYY-JH-NNNNN` or `POST /functions/v1/verify-certificate` (Public gateway, `--no-verify-jwt`)
- **Database RPC**: `verify_certificate(text)` (Protected: `anon` execution revoked in Phase 7; executed securely via Edge Function server-side service key or authenticated users)
- **Rate-Limiting**: 30 requests / minute per client IP (sliding window). Standard `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` headers returned.
- **Input Validation**: Must strictly match regex `^SK-\d{4}-JH-\d{5}$`. Malformed inputs return HTTP 400 with `INVALID_CERT_CODE`.
- **Privacy Guarantee**: Exposes **only public verification attributes**. Never returns internal database UUIDs (`worker_id`, `session_id`, `id`), `qr_hash`, phone numbers, or passwords.

#### Responses:
1. **Valid Certificate (HTTP 200)**:
   ```json
   {
     "status": "valid",
     "is_valid": true,
     "message": "Certificate verified successfully.",
     "certificate": {
       "cert_code": "SK-2026-JH-00001",
       "worker_name": "Raju Hembram",
       "worker_code": "WKR-JH-0001",
       "mine_name": "Jharia Coalfield",
       "district": "Dhanbad",
       "module": "fire",
       "score": 88,
       "issued_at": "2026-09-11T20:55:00Z",
       "expires_at": "2027-09-11T20:55:00Z"
     },
     "verified_at": "2026-09-11T21:40:00Z"
   }
   ```
2. **Expired Certificate (HTTP 200)**:
   ```json
   {
     "status": "expired",
     "is_valid": false,
     "message": "This certificate expired on 2026-08-01T00:00:00Z. Mandatory DGMS recertification is required.",
     "certificate": { ... },
     "verified_at": "2026-09-11T21:40:00Z"
   }
   ```
3. **Revoked Certificate (HTTP 200)**:
   ```json
   {
     "status": "revoked",
     "is_valid": false,
     "message": "This certificate has been revoked by safety authorities and is no longer valid.",
     "certificate": { ... },
     "verified_at": "2026-09-11T21:40:00Z"
   }
   ```
4. **Not Found / Unknown (HTTP 404)**:
   ```json
   {
     "status": "not_found",
     "is_valid": false,
     "message": "Certificate not found or invalid certificate identifier.",
     "cert_code": "SK-2026-JH-99999",
     "verified_at": "2026-09-11T21:40:00Z"
   }
   ```

---

### 3.12 Multi-Tier Leaderboard APIs

Authenticated workers and supervisors query multi-scope competitive rankings.

- **Edge Function Endpoint**: `GET /functions/v1/leaderboard?scope=my_mine&limit=20&offset=0`
- **Database RPC**: `POST /rest/v1/rpc/get_leaderboard`
- **Headers**: `Authorization: Bearer <worker_jwt>`, `apikey: <anon_key>`
- **Payload / Query Parameters**:
  - `p_scope` (`scope`): `'my_mine'` | `'my_district'` | `'all_jharkhand'` (Default: `'my_mine'`).
  - `p_limit` (`limit`): Integer 1–100 (Default: 20).
  - `p_offset` (`offset`): Integer >= 0 (Default: 0).

#### 3.12.1 Deterministic Tie-Breaking Algorithm
Leaderboard positions are ordered 100% deterministically by:
1. `safety_score DESC` (Primary: overall safety proficiency 0-100)
2. `longest_streak DESC` (Secondary: training consistency and discipline)
3. `modules_passed DESC` (Tertiary: breadth of training modules passed)
4. `created_at ASC` (Quaternary: seniority / earlier account registration)
5. `worker_code ASC` (Guaranteed unique tie-breaker)

Two rank metrics are provided:
- `rank`: Absolute unique sequential rank ($1, 2, 3...$) using full tie-breaking.
- `score_rank`: Tied group rank using `DENSE_RANK()`.

#### 3.12.2 Privacy Model
- **Exposed Competitive Fields**: `rank`, `score_rank`, `worker_code`, `full_name`, `avatar_url`, `mine_name`, `district`, `safety_score`, `current_streak`, `longest_streak`, `modules_passed`, `badges_count`.
- **Strictly Omitted**: Internal DB UUIDs (`id`, `worker_id`, `mine_id`), phone numbers, usernames, raw actions, mistake tags, notifications.

#### 3.12.3 Response Payload
```json
{
  "status": "ok",
  "scope": "my_mine",
  "total_workers": 42,
  "my_rank": 5,
  "my_score_rank": 3,
  "my_entry": {
    "rank": 5,
    "score_rank": 3,
    "worker_code": "WKR-JH-0012",
    "full_name": "Raju Hembram",
    "avatar_url": null,
    "mine_name": "Jharia Coalfield",
    "district": "Dhanbad",
    "safety_score": 88,
    "current_streak": 4,
    "longest_streak": 9,
    "modules_passed": 2,
    "badges_count": 1
  },
  "limit": 20,
  "offset": 0,
  "leaderboard": [
    {
      "rank": 1,
      "score_rank": 1,
      "worker_code": "WKR-JH-0001",
      "full_name": "Birsa Munda",
      "avatar_url": null,
      "mine_name": "Jharia Coalfield",
      "district": "Dhanbad",
      "safety_score": 96,
      "current_streak": 12,
      "longest_streak": 15,
      "modules_passed": 3,
      "badges_count": 3
    }
  ]
}
```

If a worker hasn't selected a mine yet and queries `my_mine` or `my_district`, returns:
`{ "status": "unassigned_mine", "message": "Worker has not selected a mine yet. Complete mine onboarding or query all_jharkhand.", ... }`

---

## 4. Database Tables

### 4.1 `mines`

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

### 4.2 `workers`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK = auth.users.id |
| `worker_code` | text | NO | UNIQUE. Auto-generated WKR-JH-XXXX |
| `username` | text | NO | UNIQUE. Normalized login handle |
| `full_name` | text | NO | Display name |
| `phone` | text | YES | Optional contact only — NOT used for auth |
| `mine_id` | uuid | YES | FK to mines. NULL at registration, selected in onboarding |
| `language` | language_code | NO | Default 'hi' |
| `safety_score` | integer | NO | 0-100. Computed via `update_worker_safety_score()` |
| `current_streak` | integer | NO | Consecutive training days |
| `longest_streak` | integer | NO | Historical best streak |
| `last_trained_at` | timestamptz | YES | Timestamp of last completed session |
| `avatar_url` | text | YES | Supabase Storage URL |
| `is_active` | boolean | NO | Soft delete |
| `created_at` | timestamptz | NO | |
| `updated_at` | timestamptz | NO | Auto-maintained by trigger |

---

### 4.3 `supervisors`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK = auth.users.id |
| `username` | text | NO | UNIQUE. Normalized login handle |
| `full_name` | text | NO | Display name |
| `phone` | text | YES | Optional contact only — NOT used for auth |
| `mine_id` | uuid | NO | FK to mines. NOT NULL — assigned at provisioning |
| `role` | supervisor_role | NO | supervisor/dgms_inspector/admin |
| `is_active` | boolean | NO | |
| `created_at` | timestamptz | NO | |
| `updated_at` | timestamptz | NO | Auto-maintained by trigger |

---

### 4.4 `training_sessions`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK |
| `worker_id` | uuid | NO | FK to workers |
| `mine_id` | uuid | NO | FK to mines |
| `module` | training_module | NO | fire/gas_leak/electrical |
| `difficulty` | difficulty_mode | NO | easy/medium/hard |
| `score` | integer | NO | 0-100 |
| `stars` | smallint | NO | 0-3 |
| `passed` | boolean | NO | score >= 60 |
| `weak_areas` | text[] | YES | Tags of weak areas |
| `levels_completed` | integer | NO | Levels finished in this session |
| `duration_seconds` | integer | YES | Total session time |
| `synced_from_local` | boolean | NO | TRUE if synced from Hive |
| `local_session_id` | text | YES | Client dedup ID |
| `created_at` | timestamptz | NO | |

---

### 4.5 `training_actions`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK |
| `session_id` | uuid | NO | FK to training_sessions (ON DELETE CASCADE) |
| `action_name` | text | NO | Name of action performed in AR scenario |
| `is_correct` | boolean | NO | Whether action was executed correctly |
| `response_time_ms` | integer | YES | Decision response time in milliseconds |
| `mistake_tag` | text | YES | Standardized mistake identifier |
| `details` | jsonb | YES | Scenario-specific telemetry |
| `created_at` | timestamptz | NO | |

---

### 4.6 `certificates`

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
| `qr_hash` | text | NO | SHA-256 signature |
| `is_revoked` | boolean | NO | |
| `created_at` | timestamptz | NO | |

---

### 4.7 `emergency_drills`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK |
| `mine_id` | uuid | NO | FK to mines |
| `title` | text | NO | Drill title / objective |
| `drill_type` | training_module | NO | fire / gas_leak / electrical |
| `scheduled_date` | date | NO | Scheduled date of drill |
| `completed_at` | timestamptz | YES | Completion timestamp |
| `participants_count` | integer | NO | Number of workers participating |
| `status` | text | NO | scheduled / in_progress / completed / cancelled |
| `notes` | text | YES | Drill outcomes / observations |
| `created_at` | timestamptz | NO | |
| `updated_at` | timestamptz | NO | |

---

### 4.8 `badges` & `worker_badges`

- `badges`: catalogue of badge slugs, titles, icon codes, required stars.
- `worker_badges`: junction table `(worker_id, badge_id, earned_at)` tracking earned achievements.

---

### 4.9 `notifications`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK |
| `worker_id` | uuid | NO | FK to workers (ON DELETE CASCADE) |
| `type` | notification_type | NO | drill_alert / spaced_repetition / cert_expiry / streak_reminder / system_announcement |
| `title` | text | NO | Notification header |
| `body` | text | NO | Notification message |
| `payload` | jsonb | NO | Context metadata (drill_id, cert_id, module, etc.) |
| `is_read` | boolean | NO | Read indicator (default FALSE) |
| `read_at` | timestamptz | YES | Timestamp when read |
| `created_at` | timestamptz | NO | |

*Realtime enabled: added to `supabase_realtime` publication.*

---

### 4.10 `spaced_repetition_schedules`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NO | PK |
| `worker_id` | uuid | NO | FK to workers (ON DELETE CASCADE) |
| `module` | training_module | NO | Training module requiring review |
| `mistake_tag` | text | NO | Specific mistake pattern identified |
| `interval_days` | integer | NO | Spaced interval ($1 \rightarrow 3 \rightarrow 7 \rightarrow 14 \rightarrow 30$ days) |
| `review_count` | integer | NO | Number of reviews completed |
| `next_review_due` | date | NO | Scheduled date for review prompt |
| `last_reviewed_at` | timestamptz | YES | Timestamp of last training review |
| `created_at` | timestamptz | NO | |
| `updated_at` | timestamptz | NO | Auto-maintained by trigger |

---

## 5. Database Enums

```sql
mine_type:         coal | steel | mica | uranium | other
language_code:     hi | sat | en
training_module:   fire | gas_leak | electrical
difficulty_mode:   easy | medium | hard
supervisor_role:   supervisor | dgms_inspector | admin
notification_type: drill_alert | spaced_repetition | cert_expiry | streak_reminder | system_announcement
```

---

## 6. Database Functions & Procedures

| Function | Returns | Purpose |
|---|---|---|
| `handle_new_auth_user()` | trigger | Automatic worker provisioning on `auth.users` insert |
| `protect_worker_fields()` | trigger | Prevents tampering with protected worker fields |
| `set_worker_mine(uuid)` | jsonb | Authenticated mine selection RPC |
| `get_auth_profile()` | jsonb | Authoritative profile & role retrieval RPC |
| `sync_training_session(...)` | jsonb | Atomic idempotent session sync, action telemetry, streak, cert issuance, and spaced repetition queueing |
| `issue_training_certificate(...)` | jsonb | Server-side certificate issuance with SHA-256 integrity hash & verification URL |
| `generate_qr_hash(...)` | text | Internal backend tamper-evident checksum calculation |
| `get_supervisor_dashboard_summary()` | jsonb | Mine KPI overview (workers, module progress, cert counts, drills) |
| `get_supervisor_workers(...)` | jsonb | Paginated search, filter, and listing of mine workers |
| `get_supervisor_worker_detail(uuid)` | jsonb | Detailed worker diagnostics, session history, and weak areas |
| `get_mine_weak_areas()` | jsonb | Mine-wide aggregate scenario failure analysis |
| `get_mine_recent_activity(int)` | jsonb | Live training activity feed for supervisor mine |
| `get_compliance_report(uuid)` | jsonb | Formal DGMS safety audit and compliance report generator |
| `get_my_notifications(...)` | jsonb | Worker notification retrieval with unread filtering and pagination |
| `mark_notification_read(uuid)` | jsonb | Mark individual notification as read (worker-scoped) |
| `mark_all_notifications_read()` | jsonb | Bulk mark all pending notifications read for authenticated worker |
| `broadcast_drill_alert(uuid)` | jsonb | Broadcast drill notification to all workers in supervisor mine |
| `schedule_spaced_repetition_review(...)` | void | Update expanding Leitner intervals on mistake tags |
| `generate_spaced_repetition_reminders()` | jsonb | Batch generator creating notifications for due spaced-repetition reviews |
| `generate_certificate_expiry_reminders()` | jsonb | Batch generator creating notifications for expiring certificates |
| `get_leaderboard(scope, limit, offset)` | jsonb | Multi-tier leaderboard with deterministic tie-breaking and privacy |
| `get_difficulty_mode(incidents int)` | difficulty_mode | Compute difficulty from incident count |
| `calculate_stars(score int)` | smallint | 0-3 stars from score |
| `update_worker_safety_score(uuid)` | void | Recompute + persist safety_score |
| `generate_worker_code()` | text | Generate WKR-JH-XXXX from sequence |
| `generate_cert_code()` | text | Generate SK-YYYY-JH-NNNNN from sequence |
| `verify_certificate(cert_code text)` | TABLE | Public-safe online cert verification with valid/expired/revoked status (service_role / authenticated) |
| `enforce_training_session_integrity()` | trigger | Enforces authoritative stars and passed=TRUE/FALSE on training_sessions |
| `trigger_set_updated_at()` | trigger | Auto-update updated_at timestamp |

---

## 7. RLS Policy Summary

| Table | Worker (own) | Supervisor (mine scope) | DGMS/Admin | Anon | Service Role |
|---|---|---|---|---|---|
| mines | SELECT | SELECT | SELECT | SELECT | INSERT, UPDATE |
| workers | SELECT, UPDATE* | SELECT | SELECT | - | INSERT |
| supervisors | SELECT (own) | - | SELECT | - | INSERT, UPDATE |
| training_sessions | SELECT, INSERT | SELECT | SELECT | - | - |
| training_actions | SELECT, INSERT | SELECT | SELECT | - | ALL |
| emergency_drills | - | SELECT, INSERT, UPDATE | ALL | - | ALL |
| certificates | SELECT | SELECT | SELECT | - (use verify_certificate) | INSERT, UPDATE |
| badges | SELECT | SELECT | SELECT | - | INSERT, UPDATE |
| worker_badges | SELECT | SELECT | SELECT | - | INSERT |
| notifications | SELECT, UPDATE (read)* | SELECT, INSERT | SELECT | - | ALL |
| spaced_repetition_schedules | SELECT | SELECT | SELECT | - | ALL |

*\*Worker updates on `workers` are restricted to allowed fields only (`mine_id`, `language`, `phone`, `avatar_url`, `is_active`).*
*\*Worker updates on `notifications` are restricted to `is_read` and `read_at` on own rows.*

---

*This contract is version-controlled. All changes reflected in CHANGELOG.md.*