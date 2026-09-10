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
| **Mine Supervisor** (Secondary) | Safety officer managing 50–200 workers, needs compliance dashboard |
| **DGMS Inspector** (Tertiary) | Government auditor needing verifiable certificates and audit reports |

---

## 3. Key Features

- **Multilingual** — Hindi, Santali (Ol Chiki script), English
- **AR Training Modules** — Fire & Explosion, Gas Leak (more planned)
- **Mine-Adaptive Difficulty** — difficulty scales based on real DGMS accident history per mine
- **QR Verifiable Certificates** — SHA-256-signed, expiry-aware, sharable via WhatsApp
- **Offline-First** — all training, scores, and certificates work without internet (Hive local DB)
- **Cloud Sync** — syncs to Supabase when WiFi is available
- **Gamification** — safety score (0–100), streak counter, badge system, star ratings
- **Supervisor Web Dashboard** — React + TypeScript, compliance reports, PDF export
- **Push Notifications** — spaced repetition reminders via FCM + Supabase Edge Functions

---

## 4. Monorepo Structure

```
A.R.M.O.R/
├── PROJECT_CONTEXT.md
├── API_CONTRACT.md
├── CHANGELOG.md
├── .env.example
├── backend/
│   ├── functions/
│   │   └── _shared/
│   ├── scripts/
│   └── README.md
└── supabase/
    ├── config.toml
    ├── migrations/
    │   └── 00000000000000_init.sql
    └── seed.sql
```

---

## 5. Technology Stack

| Layer | Technology |
|---|---|
| Mobile App | Flutter (Dart), Android-only, ARCore |
| Offline DB | Hive (NoSQL, on-device) |
| Cloud DB | Supabase (PostgreSQL + Auth + Storage + RLS) |
| Auth | Supabase Phone OTP |
| AR | ARCore via ar_flutter_plugin |
| Voice / TTS | Bhashini API (pre-generated MP3 assets) |
| Map | Custom SVG (Jharkhand), flutter_svg |
| State Mgmt | Riverpod (flutter_riverpod) |
| QR Certs | qr_flutter + dart_pdf |
| Push Notif | Firebase Cloud Messaging (FCM) |
| Web Dashboard | React + TypeScript + shadcn/ui + Recharts |
| Web Hosting | Vercel |
| Monorepo | GitHub (printezz01/A.R.M.O.R) |

---

## 6. Mine Difficulty Algorithm

| Incident Count | Difficulty Mode | Levels Played |
|---|---|---|
| 8+ incidents | HARD | 3 (Easy -> Medium -> Hard) |
| 4-7 incidents | MEDIUM | 2 (Easy -> Medium) |
| < 4 incidents | EASY | 2 (Easy -> Medium) |

---

## 7. Certificate Schema

Each certificate encodes: cert_id + worker_id + module + score + issued_date + sha256_hash
Valid for 1 year. QR code verifiable online (Supabase) and offline (local hash).

---

## 8. Offline Sync Strategy

1. App writes to Hive locally first
2. sync_queue in Hive tracks pending uploads
3. On WiFi reconnect: flush queue to Supabase
4. Cloud = source of truth for compliance; Local = source of truth for training

---

## 9. Phase Roadmap

| Phase | Scope |
|---|---|
| Phase 1 (done) | Repo structure, Supabase schema, RLS, seed data, foundational views |
| Phase 2 | Supabase Auth (Phone OTP), worker registration API, mine data API |
| Phase 3 | Training session recording API, certificate generation + QR signing |
| Phase 4 | Supervisor dashboard backend, compliance report generation |
| Phase 5 | FCM push notifications, pg_cron spaced repetition triggers |
| Phase 6 | Edge Functions for certificate verification, leaderboard |
| Phase 7 | Production hardening, rate limiting, monitoring |

---

*Last updated: Phase 1 — September 2026*
