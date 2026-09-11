# A.R.M.O.R — Backend

This directory contains all server-side logic for the A.R.M.O.R project.

## Structure

```
backend/
├── functions/              # Supabase Edge Functions (Deno/TypeScript)
│   ├── _shared/            # Shared utilities used across multiple functions
│   │   ├── cors.ts         # CORS headers helper
│   │   ├── auth.ts         # Username validation & internal email mapping
│   │   └── errors.ts       # Standardized error response helpers
│   ├── sync-session/       # Phase 3: Receive offline-queued training sessions (Implemented)
│   ├── verify-certificate/ # Phase 6: Public certificate verification & rate-limiting (Implemented)
│   └── leaderboard/        # Phase 6: Multi-tier worker leaderboards & tie-breaking (Implemented)
└── scripts/                # Utility scripts & test harnesses
    ├── test_phase2_rls.sql
    ├── test_phase3_sync_certs.sql
    ├── test_phase4_supervisor_dashboard.sql
    ├── test_phase5_notifications.sql
    ├── test_phase6_verification_and_leaderboard.sql
    └── test_phase7_production_hardening.sql
```

## Edge Functions (Phase 2+)

Edge Functions are located in `supabase/functions/` (standard layout for Supabase CLI deployment) and run on Deno.

### Deployment (Supabase CLI)
```powershell
# 1. Authenticate CLI (one-time)
supabase login

# 2. Link hosted project
supabase link --project-ref ampqcpxpshaiiquqbmmn

# 3. Deploy functions
# verify-certificate is public-safe (deploy with --no-verify-jwt so anon/QR scanners can access)
supabase functions deploy verify-certificate --project-ref ampqcpxpshaiiquqbmmn --no-verify-jwt

# leaderboard requires authenticated user JWT
supabase functions deploy leaderboard --project-ref ampqcpxpshaiiquqbmmn

# sync-session requires authenticated worker JWT
supabase functions deploy sync-session --project-ref ampqcpxpshaiiquqbmmn
```

### Local testing (against hosted Supabase)
```bash
supabase functions serve --env-file .env
```

## Environment Variables

See `.env.example` at the repository root.

Required for server-side functions:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY`
- `CERT_VERIFY_BASE_URL` (Optional: domain for QR verification links, e.g. `https://armor-verify.internal/verify?code=`)

## Phase Status

| Function / API | Phase | Status |
|---|---|---|
| `sync-session` | Phase 3 | ✅ Complete |
| `issue-certificate` (RPC) | Phase 3 | ✅ Complete |
| `supervisor-dashboard` (RPCs) | Phase 4 | ✅ Complete |
| `supabase-notifications` (RPCs & Realtime) | Phase 5 | ✅ Complete |
| `send-reminders` | Phase 5 | ✅ Complete (DB RPCs) |
| `verify-certificate` (RPC & Edge Function) | Phase 6 | ✅ Complete |
| `leaderboard` (RPC & Edge Function) | Phase 6 | ✅ Complete |
| `production-hardening` (Security & Indexes) | Phase 7 | ✅ Complete |
| `flutter-offline-hive` (Mobile Local Storage) | Phase 8 | Deferred |
