# A.R.M.O.R — Backend

This directory contains all server-side logic for the A.R.M.O.R project.

## Structure

```
backend/
├── functions/              # Supabase Edge Functions (Deno/TypeScript)
│   ├── _shared/            # Shared utilities used across multiple functions
│   │   ├── cors.ts         # CORS headers helper
│   │   ├── supabase.ts     # Supabase admin client initializer
│   │   └── errors.ts       # Standardized error response helpers
│   ├── sync-session/       # Phase 3: Receive offline-queued training sessions
│   ├── issue-certificate/  # Phase 3: Generate + sign certificate
│   ├── verify-certificate/ # Phase 6: Public certificate verification
│   ├── send-reminders/     # Phase 5: Trigger FCM push notifications
│   └── compliance-report/  # Phase 4: Generate compliance report data
└── scripts/                # Utility scripts
    ├── seed.ts             # Run seed data (development only)
    └── check-schema.ts     # Validate schema matches API_CONTRACT.md
```

## Edge Functions (Phase 2+)

Edge Functions are deployed to Supabase and run on Deno.

### Deployment
```bash
supabase functions deploy <function-name> --project-ref ampqcpxpshaiiquqbmmn
```

### Local testing (against hosted Supabase)
```bash
supabase functions serve --env-file .env
```

## Environment Variables

See `.env.example` at the repository root.

Required for server-side functions:
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY` (Phase 5+ only — do NOT use the publishable key here)

## Phase Status

| Function | Phase | Status |
|---|---|---|
| `sync-session` | Phase 3 | Not implemented |
| `issue-certificate` | Phase 3 | Not implemented |
| `verify-certificate` | Phase 6 | Not implemented |
| `send-reminders` | Phase 5 | Not implemented |
| `compliance-report` | Phase 4 | Not implemented |
