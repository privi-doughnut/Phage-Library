# Phage Receptor Library

A research database for the UNC Charlotte CIPHER Lab cataloging bacteriophages
and the host receptors they bind. Built on [PhReD — The Phage Receptor
Database](https://phred.biodf.org) (Bio-conversion Databank Foundation).

Single static HTML file (`index.html`, vanilla JS, no build step) backed by
Supabase (Postgres + Auth + Row-Level Security). See `BUILD_SPEC.md` for the
full design spec and `BUILD_PROGRESS.md` for build history and open items.

## Run locally

```
python3 -m http.server 8000
```

Open `http://localhost:8000/index.html`. That's it — no install, no build.

## Deploy to Cloudflare Pages

This is a static site with no build command, so deployment is minimal:

**Option A — Cloudflare dashboard:** Workers & Pages → Create → Pages →
Connect to Git → pick this repo. Leave the build command blank and set the
build output directory to `/` (repo root). The `_headers` file at the repo
root is picked up automatically and adds a few baseline security headers —
no other config needed.

**Option B — Wrangler CLI:**
```
npx wrangler pages deploy .
```
(first run will prompt you to log in and create/pick a Pages project — no
config file required for a plain static site like this one).

Both are free with no meaningful traffic cap for a small lab tool. No
environment variables are required for the deploy itself. The Supabase
project URL and **anon** key are inlined directly in `index.html` — this is
intentional and safe (see BUILD_SPEC.md §4): the anon key only grants what
Row-Level Security already allows (public read, authenticated-only write),
and inlining it keeps the site buildless. The service_role key is never used
client-side and is not present anywhere in this repo.

## Adding a lab member (sign-in)

Sign-in is a Supabase Auth magic link (one-time email link, no password) —
click "Sign in" in the top-right masthead, enter an email, and Supabase
emails a link back to this same page.

**⚠️ Before going live, restrict who can create an account.** As shipped,
Supabase Auth's default "allow new signups" setting means *any* email address
can request a magic link and, once clicked, becomes a fully authenticated
user — and every authenticated user can edit any record, add rows, and
hard-delete rows (per the RLS policies in `supabase/schema.sql`). There is
currently no separate "lab member" allow-list layered on top of Supabase's
generic `authenticated` role. Before publishing this URL anywhere public,
either:

- In the Supabase dashboard → **Authentication → Settings**, turn off "Allow
  new users to sign up," then manually invite each real lab member's email
  from **Authentication → Users → Invite** (they'll still sign in via magic
  link after that — this only stops *strangers* from self-provisioning an
  account); or
- Accept that anyone who learns the URL and signs in gets full write access,
  if that risk is acceptable for this lab's use case.

This is a one-time dashboard setting, not a code change — flagging it here so
it isn't missed at deploy time.

## Project files

- `index.html` — the whole app.
- `_headers` — Cloudflare Pages security headers (picked up automatically on deploy).
- `supabase/schema.sql`, `supabase/seed.sql` — DB setup (already applied to
  the live project; do not re-run the seed).
- `phage_library_SEED.csv` / `phage_library_FULL_526.csv` — source data.
- `BUILD_SPEC.md` — design spec and rules (source of truth for intent).
- `BUILD_PROGRESS.md` — build history, decisions made, and what's left.
