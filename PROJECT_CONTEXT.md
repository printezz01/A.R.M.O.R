# A.R.M.O.R — Project Context

**A**ugmented **R**eality **M**ine **O**perations & **R**escue

> SIH Problem Statement ID: **SIH26041**
> Full Name: *AR-Based Vocational Training Simulator for Industrial Safety*

---

## 1. Product Summary

A.R.M.O.R. is a **mobile AR-based safety training application** targeting mine workers in Jharkhand, India. It transforms mandatory DGMS safety training from static classroom manuals into an action-based AR survival game — accessible, multilingual, and fully offline-capable.

**Core Tagline:** *"Stop reading about fire safety. Survive a fire — on your phone."*

---

## 2. Target Users

| Role | Description |
|---|---|
| **Mine Worker** (Primary) | Young tribal recruit, semi-literate, Santali/Hindi speaker |
| **Mine Supervisor** (Secondary) | Safety officer managing 50-200 workers, needs compliance dashboard |
| **DGMS Inspector** (Tertiary) | Government auditor needing verifiable certificates and audit reports |

---

## 3. Key Features

- **Multilingual** - Hindi, Santali (Ol Chiki script), English
- **AR Training Modules** - Fire & Explosion, Gas Leak (more planned)
- **Mine-Adaptive Difficulty** - difficulty scales based on real DGMS accident history per mine
- **QR Verifiable Certificates** - SHA-256-signed, expiry-aware, sharable via WhatsApp
- **Offline-First** - all training, scores, and certificates work without internet (Hive local DB)
- **Cloud Sync** - syncs to Supabase when WiFi is available
- **Gamification** - safety score (0-100), streak counter, normalized badge system, star ratings
- **Supervisor Web Dashboard** - React + TypeScript, compliance reports, PDF export
- **Push Notifications** - spaced repetition reminders via FCM + Supabase Edge Functions

---

## 4. Authentication Architecture (Locked)

**Auth model: Username + Password via Supabase Auth.**

- Workers log in with a username and password — no phone or OTP required.
- Supervisors log in with a username and password.
- Phone is **optional contact data only** — stored on the profile, not used for login.
- Worker accounts are provisioned server-side (Phase 2) after registration.
- Each user in Supabase Auth (`auth.users`) maps 1:1 to a row in either `workers` or `supervisors`.

> Phone OTP auth was considered and rejected. The locked decision is username/password.

---

## 5. Identity Design

| Identifier | Type | Purpose |
|---|---|---|
| `auth.users.id` (UUID) | Internal | Supabase Auth primary key. Used for all RLS policies. |
| `worker_code` (TEXT) | Human-readable | System-generated (WKR-JH-0001). Shown to workers, supervisors, on certificates. |
| `username` (TEXT) | Login credential | Unique login handle. Set at registration. |
| `cert_code` (TEXT) | Certificate ID | Human-readable cert ID (SK-2026-JH-00001). Encoded in QR code. |

---

## 6. Monorepo Structure

```
A.R.M.O.R/
├── PROJECT_CONTEXT.md
├── API_CONTRACT.md
├── CHANGELOG.md
├── .env.example
├── backend/
│   ├── functions/
│   │   └── _shared/       (cors.ts, errors.ts)
│   ├── scripts/
│   └── README.md
└── supabase/
    ├── config.toml
    ├── migrations/
    │   └── 00000000000000_init.sql
    └── seed.sql
```

---

## 7. Technology Stack

| Layer | Technology |
|---|---|
| Mobile App | Flutter (Dart), Android-only, ARCore |
| Offline DB | Hive (NoSQL, on-device) |
| Cloud DB | Supabase (PostgreSQL + Auth + Storage + RLS) |
| Auth | Supabase username/password (Email auth with username as email is NOT used; custom username field) |
| AR | ARCore via ar_flutter_plugin |
| Voice / TTS | Bhashini API (pre-generated MP3 assets, bundled offline) |
| Map | Custom SVG (Jharkhand), flutter_svg |
| State Mgmt | Riverpod (flutter_riverpod) |
| QR Certs | qr_flutter + dart_pdf |
| Push Notif | Firebase Cloud Messaging (FCM) - Phase 5 |
| Web Dashboard | React + TypeScript + shadcn/ui + Recharts |
| Web Hosting | Vercel |
| Monorepo | GitHub (printezz01/A.R.M.O.R) |

---

## 8. Mine Difficulty Algorithm

| Incident Count (per module) | Difficulty | Levels |
|---|---|---|
| 8+ incidents | HARD | 3 (Easy -> Medium -> Hard) |
| 4-7 incidents | MEDIUM | 2 (Easy -> Medium) |
| < 4 incidents | EASY | 2 (Easy -> Medium - minimum is always 2) |

---

## 9. Star Rating (Locked Thresholds)

| Score | Stars |
|---|---|
| 90-100 | 3 stars |
| 75-89 | 2 stars |
| 60-74 | 1 star (passing) |
| Below 60 | 0 stars (failed) |

---

## 10. Safety Score Algorithm (Locked)

Safety score is a **whole number 0-100** computed as:

```
For each training module with at least one PASSED session:
  module_mean = AVG(score) across ALL passed sessions for that module

safety_score = ROUND(AVG(module_mean across all modules with passed sessions))
```

This reflects improving performance over time, not just peak scores.
A worker with no passed sessions has safety_score = 0.

---

## 11. Badge System (Normalized)

Badges are stored in two tables:
- `badges` — catalogue of all earnable badge definitions
- `worker_badges` — junction table recording which worker earned which badge and when

The `workers` table does NOT contain a badges array. All badge queries go through `worker_badges`.

---

## 12. Certificate Verification

- **Online:** Call `verify_certificate(cert_code)` SECURITY DEFINER function (anon-callable). Returns safe public fields only — no internal UUIDs, no qr_hash.
- **Offline:** Flutter app re-computes SHA-256 hash locally and compares against the embedded hash in the QR code data.
- The `certificates` table has NO anon-readable RLS policy. The function is the only public access path.

---

## 13. Offline Sync Strategy

1. App writes all data to **Hive** locally first
2. A `sync_queue` in Hive tracks pending uploads
3. On WiFi reconnect: flush queue to Supabase (`training_sessions` insert with `synced_from_local=TRUE`)
4. Deduplication: `UNIQUE (worker_id, local_session_id)` partial index prevents double-insert
5. Cloud = source of truth for compliance; Local = source of truth during active training

---

## 14. Phase Roadmap

| Phase | Version | Scope |
|---|---|---|
| Phase 1 (done) | 0.1.0 | Repo structure, schema, RLS, seed data, views/functions |
| Phase 2 | 0.2.0 | Supabase Auth (username/password), worker registration, mine API |
| Phase 3 | 0.3.0 | Training session sync API, certificate generation + QR signing |
| Phase 4 | 0.4.0 | Supervisor dashboard API, compliance report generation |
| Phase 5 | 0.5.0 | FCM push notifications, pg_cron spaced repetition triggers |
| Phase 6 | 0.6.0 | Edge Functions (cert verify, leaderboard) |
| Phase 7 | 1.0.0 | Production hardening, rate limiting, monitoring |

---

*Last updated: Phase 1 v2 revision — September 2026*