# Barbershop booking platform

## Phase 1: Supabase foundation

The production database, Supabase Auth/RBAC, Row Level Security, Storage, Realtime, and setup instructions are documented in [docs/PHASE_1_SUPABASE_ARCHITECTURE.md](docs/PHASE_1_SUPABASE_ARCHITECTURE.md).

## Phase 2: professional admin panel

The secured React admin dashboard and its required Phase 2 Supabase migration are documented in [docs/PHASE_2_ADMIN_PANEL.md](docs/PHASE_2_ADMIN_PANEL.md).

```bash
cp .env.example .env
# Add only VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY
npm install
npm run dev
```

Never add a Supabase service-role key or provider secrets to `.env` values prefixed with `VITE_`.
