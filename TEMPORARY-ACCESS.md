# Temporary login-free test

The existing app opens directly. Supabase read/write access is temporarily enabled **only for Green Peas**, until **2026-09-25 17:53:57 UTC / 20:53:57 Beirut**. No farm facts or quantities were invented.

RLS is still enabled. Temporary policies are named `temporary_test_*`. The existing controlled write functions, relationship checks, immutable history, stock validation, and AI confirmation remain in use. Requests have no verified user identity; new audit actor IDs therefore remain null.

The database administrator alone can change `farm_internal.temporary_access_window`. Every temporary access policy and write permission check uses `farm_test_access()`, which enforces the expiry. Public read/write access stops automatically at expiry; there is no browser timer or background job to keep running. The current login-free frontend will then report that farm data is unavailable until secure sign-in is restored.

## End the test and restore security

1. Run `supabase/rollback/end-temporary-public-access.sql` as a database administrator. It closes the window, removes the temporary policies and grants, and restores the original authorization functions. Existing operational records and audit history are preserved. Anonymous test conversations are assigned to the existing farm owner; anonymous audit actors are not falsely attributed to that owner.
2. Run `git apply --check supabase/rollback/restore-sign-in.patch`, then `git apply supabase/rollback/restore-sign-in.patch`. This reverses only the authentication-related app changes from this test. If subsequent edits cause conflicts, review them instead of replacing whole files.
3. Run `node --test tests/schedule.test.cjs` and `npm run build`, verify the restored owner sign-in, then redeploy the same Vercel project if it was deployed for this test. `tests/login-free.test.cjs` describes the temporary mode and is not applicable after restoring sign-in.

The SQL rollback was executed inside a test transaction and rolled back itself: the 72-hour test remains active. Membership tables are not exposed by the temporary policies.

## Validation

- Eight Node tests pass: direct startup, token-free database requests, AI proposal/confirmation boundaries, origin checking, and calendar recurrence.
- Transactional tests passed for anonymous task creation/completion and multiple assignments, crop stages/history, planting plans, chicken adjustments/transfers, coop records/cleaning, Marketplace sales, Breakfast ingredient deductions, and AI Cancel/Confirm/idempotency. Every fixture was rolled back.
- Expiry was tested against both direct database requests and controlled write functions.
- Browser checks passed for direct loading, 15 confirmed facilities, reload, Today/Week/Month, selectors, desktop/mobile Schedule, and all operational pages. No JavaScript errors were observed.
- Supabase security advisors report the intentional temporary anonymous RPC access. Internal expiry settings remain inaccessible to app roles. Existing password-protection configuration was not changed.

## AI and private keys

Only the Supabase **publishable** key is in the frontend. `OPENAI_API_KEY` remains a server environment variable; no service-role key is used or exposed.

The local server currently has no `OPENAI_API_KEY`, so model replies return a clear configuration message. Database tools and action confirmation are verified. Configure the key in the existing Vercel project `farm-os-rosy`, or in a git-ignored `.env.local` for local testing and start with `node --env-file=.env.local scripts/dev.cjs`. Do not put the key in frontend files or paste it into chat.

This change is verified locally at `http://127.0.0.1:4173`. It has not been deployed to Vercel by this task.
