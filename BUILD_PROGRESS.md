# BUILD PROGRESS — handoff note

This tracks where the Supabase refactor stands so any new Claude Code session
can continue seamlessly. **Read `BUILD_SPEC.md` first** (it's the source of
truth for the plan); this file records what's already done, decisions made, and
what's next. When they conflict, `BUILD_SPEC.md` wins on intent — this file wins
on "what has actually happened so far."

## Current status: Phases 0–6 DONE (code-complete). **A SQL migration must be run before Phase 6 works** — see below and the checklist at the bottom.

## Phase 6 — password auth, admin roles, delete safeguard, notifications, bans

Requested directly by the user after Phase 5, beyond BUILD_SPEC's original
plan. Summary of what changed and why:

**1. Password as a backup sign-in option.** The sign-in popover now has two
tabs, "Email link" and "Password". Password needs no schema change — Supabase
Auth supports it natively. A signed-in user sets a password for the first
time from "Set / change password" in the signed-in menu
(`supabase.auth.updateUser({password})`); after that they can use either
method going forward (`supabase.auth.signInWithPassword`). There's
deliberately no separate "forgot password" flow — the email-link path is
always available as the de facto recovery path, so building a second reset
flow would be redundant.

**2. Admin roles + an invite allow-list.** New `public.admins` table (one row
per admin, storing their email too so it can be displayed without a separate
lookup). New `public.admin_invites` table an admin adds an email to; a
`claim_admin_invite()` Postgres function (SECURITY DEFINER) runs after every
sign-in and auto-promotes the caller to admin **if and only if their own
email is on the invite list** — no email is sent by us; the person just uses
the existing sign-in flow (link or password) and gets upgraded on arrival.
This was the user's explicit choice over a real "invite email" (which would
have needed a Supabase Edge Function + the service_role Admin API — more
infra, still free, but a real departure from "just a static HTML file").
Admins can also remove other admins from the panel (blocked from removing
the last remaining admin, to avoid locking everyone out).

**3. Delete safeguard: flag → 72-hour cooldown → admin-only hard delete.**
The old immediate "Delete" button is gone. Any signed-in user can **flag** a
record for deletion (sets `pending_deletion_at`/`pending_deletion_by`) or
**cancel** a flag (any signed-in user, not just the original flagger or an
admin — deliberately kept permissive here since cancelling is low-stakes: the
real safeguard is that nobody, admin included, can actually delete before the
cooldown). The **actual hard delete** is enforced **server-side by RLS**, not
just hidden in the UI: `phages` DELETE policy now requires the caller to be
in `public.admins` *and* `pending_deletion_at <= now() - interval '72 hours'`.
Flagged rows show a small "flagged for deletion" tag in the table and a
warning banner + countdown in the drawer; admins get an extra filter
dropdown ("Pending deletion") to review the queue.

**4. Activity/notification feed.** A `phages` trigger
(`log_phage_activity()`) writes one row to `public.activity_log` on every
insert/update/delete, capturing added/edited/verified/flagged-for-review/
flagged-for-deletion/deletion-cancelled/deleted — this happens at the
database level via a trigger, so it captures every change regardless of code
path (even a future direct SQL edit). The masthead gets a 🔔 bell (visible
when signed in) with an unread badge (tracked via `localStorage`, per
browser, not per account — a deliberately simple choice) and a dropdown
feed, live-updated via a Supabase Realtime subscription on `activity_log`
(no polling). **Regular signed-in users see what changed but not who** (per
the user's explicit instruction — "reg users dont, they have no reason to");
**admins additionally see the actor's email**, resolved via a new
`public.profiles` table that every user's client upserts
(`user_id → email`) right after their own sign-in — this is also what now
lets the drawer's existing "Updated by" field show a real email to admins
instead of just "You" or a raw UUID fragment (a limitation flagged back in
Phase 4). When a user is newly granted admin, they get a one-time client-side
toast: "Welcome — you've been granted admin access…" (not stored anywhere,
just shown once at the moment `isAdmin` flips true in that session).

**5. Ban an email from writing.** New `public.banned_emails` table, admin-only
to manage. Enforcement is entirely RLS-based (no service_role/Admin API
involved, keeping this in the "in-app only" bucket): every `phages`
insert/update/delete policy now also requires `not public.is_banned()`,
where `is_banned()` checks whether the *currently authenticated user's real
email* (via `auth.users`, joined by `auth.uid()`) appears in
`banned_emails`. **Important nuance to know**: a banned person can still
technically *sign in* (we have no way to block that without the service-role
Admin API) — but every write they attempt is rejected at the database level,
so in practice they retain read-only access and nothing else. The UI also
proactively checks ban status after sign-in and, if banned, replaces the
signed-in menu with a plain restriction notice instead of showing edit
controls that would just fail.

### ⚠️ You must run a SQL migration before any of this works
`supabase/phase6_admin_ban_notifications.sql` has everything (new tables,
RLS policies, functions, the activity trigger, and enabling Realtime on
`activity_log`). **Run it once, in full, in the Supabase SQL editor.** It's
purely additive — safe against the live 526-row table — except that it
replaces the phages insert/update/delete policies (intentional: that's how
the ban check and the delete cooldown get enforced).

**Then bootstrap yourself as the first admin** (there's a chicken-and-egg
problem otherwise: granting admin requires being an admin). Sign in to the
app for real at least once first, then run the commented snippet at the
bottom of that SQL file with your own email:
```sql
insert into public.admins(user_id, email, granted_by)
select id, email, id from auth.users where lower(email) = lower('you@example.com')
on conflict (user_id) do nothing;
```
After that, you can invite further admins from the app itself.

### How this was verified (and what wasn't)
Tested in a real (Playwright-driven) browser against the live project:
- Confirmed Phases 1–5 still work unchanged after all these edits (526/463/63
  counts, search, drawer, both themes) — no regressions.
- **Found and fixed a real bug**: switching the sign-in popover's tab
  (Email link ↔ Password) synchronously re-rendered the popover mid-click,
  which detached the clicked button from the DOM before the click event
  finished bubbling — so the "click outside closes the popover" handler saw
  it as an outside click and closed the popover instantly. Fixed with
  `e.stopPropagation()` on the tab buttons. Caught by testing the interaction
  directly rather than assuming it worked.
- Verified the password sign-in path makes a real call to Supabase and fails
  gracefully with a real "invalid credentials" style error for a bogus
  account (expected, since no real account/password exists to test against).
- Verified every Phase 6 UI surface (admin panel, notification bell, the
  "Flag for deletion" button, the admin-only pending-deletion filter) renders
  correctly and **fails gracefully** — clear inline error text, no crash, no
  console pageerrors — against the live project *before* the migration is
  run, since the underlying tables/columns don't exist yet.
- **Not verified (needs the migration run first, then a human)**: the actual
  admin-invite claim flow, banning someone and confirming their next write
  attempt is rejected, the full 72-hour delete cooldown end-to-end, and the
  live Realtime notification push. All of this requires the SQL file to be
  run before it can be tested at all — do that first, then re-test each
  workflow once.

### Phase 0 — plan & schema review ✅
Schema in BUILD_SPEC §5 confirmed field-by-field against `phage_library_SEED.csv`.
No schema design changes needed. Only doc/import caveats (column order, empty-vs-null).

### Phase 1 — database ✅ (live in Supabase, do NOT re-run)
- Project ref: `uezraodulwvtenkbemta` · URL: `https://uezraodulwvtenkbemta.supabase.co`
- `supabase/schema.sql` was run: table `public.phages`, RLS, trigger, indexes.
- `supabase/seed.sql` logic was applied via the dashboard (Table Editor CSV
  import of `phage_library_SEED.csv`), then whitespace-only `comments`
  normalized to NULL.
- **Verified live:** 526 rows · 63 needs_review · 512 has_genbank · 185 has_uniprot.
  `domain_class` NULL on all 55 N/A-domain rows; all 526 `comments` NULL.
- The table already holds the data. Re-seeding is not needed and would duplicate.

### Phase 2 — read path ✅ (committed)
- `index.html`: baked-in 526-record `DATA` array replaced with a live Supabase
  fetch on load, through the snake_case→camelCase mapping layer (`mapRow`, §7).
- `@supabase/supabase-js` v2 loaded via CDN. **Anon key only**, inline in
  `index.html` (RLS-safe per §4). No service_role key anywhere.
- Client is created inside `init()` behind a guard, so a CDN/library load
  failure shows the "library is unreachable" state instead of a blank page.
- Loading + error states added in the interface's clinical voice.
- Every render function is unchanged — only the data source changed.
- **Verified:** live anon read returns all 526 rows; `mapRow` reproduces the
  pre-refactor object shape exactly (K8, 30/30 keys); a headless render of the
  real dataset showed correct coverage (526/463/63, 97% GenBank, 35% UniProt),
  7 domain groups, intact "pred" honesty markers, working
  segment/search/drawer/theme, zero page errors.

> NOTE on verification environment: Phase 2 was originally built in Claude Code
> on the web, whose sandbox browser cannot reach external hosts — so its
> happy-path render was verified headlessly against a local stub. **This has
> since been re-verified for real** (see Phase 2 re-verification below).

### Phase 2 re-verification — done on a local machine, real browser ✅
Ran `python3 -m http.server 8000` and drove a real (Playwright-controlled)
Chromium against `http://localhost:8000/index.html`, hitting the live Supabase
project — no stub. Confirmed:
- Network tab shows a real request to
  `https://uezraodulwvtenkbemta.supabase.co/rest/v1/phages?select=*&order=phage.asc`;
  no baked-in `DATA` array.
- Coverage bar reads 526 phages / 463 verified / 63 needs revision / 97%
  GenBank linked / 35% UniProt RBP — matches spec.
- Search, grouping/expand, detail drawer (with the "predicted" host-range
  honesty marker and low-confidence basis note intact), and both themes
  (clinical light / lab dark) all render and behave correctly.
- Zero console errors across the session.

## Decisions made (with the lab / user)
- **Delete policy:** authenticated users CAN hard-delete rows (for genuinely
  wrong entries), in addition to the needs_review flag workflow. The
  `auth delete` RLS policy is live.
- **No unique constraint on `phage`** — a lab may legitimately log two isolates
  under the same name.
- **Auth style (Phase 3):** **magic link** (email one-time link), not
  email+password. Set up Supabase Auth accordingly.

### Phase 3 — auth (magic link) ✅
- Added a `Sign in` control to the masthead (`#authWrap`/`#authBtn`/`#authPop`
  in `index.html`), styled to match the existing pill-button/popover language
  in both themes.
- Signed-out: clicking it opens a small popover with an email field and
  "Send magic link", which calls
  `supabaseClient.auth.signInWithOtp({ email, options: { emailRedirectTo } })`.
  Success/error messages render inline in the interface's voice.
- Signed-in: the button shows the user's email (truncated if long) and the
  popover shows "Signed in as …" plus a "Sign out" button
  (`supabaseClient.auth.signOut()`).
- State is driven entirely by `supabaseClient.auth.onAuthStateChange`,
  registered once in `init()` right after the client is created — this also
  picks up the session automatically when a user lands back on the page via
  the magic-link redirect (supabase-js's default `detectSessionInUrl` handles
  parsing the token out of the URL).
- **Reading is never gated on auth** — `loadData()` runs unconditionally in
  `init()`, auth only adds the sign-in control on top.
- **Verified in a real browser:** submitting a syntactically-valid email
  (`phage-lab-test-user@gmail.com`) produced a real 200 from Supabase's OTP
  endpoint and the "Check your email for the sign-in link" message; a
  known-fake domain (`example.com`) was correctly rejected by Supabase with an
  inline error, proving the error path also works. Signed-in visual state,
  dark-theme rendering, outside-click-to-close, and Escape-to-close were all
  checked. Zero console errors.
- **Not yet verified (needs a human with a real inbox):** actually clicking a
  received magic-link email and landing back signed in. The send path and the
  redirect-parsing code are both confirmed independently, but the full
  round-trip hasn't been exercised by a human. Do that once handed off.
- **Dashboard check the lab should make:** Supabase Dashboard → Authentication
  → URL Configuration — confirm both `http://localhost:8000` (or whatever you
  test from) and the eventual Cloudflare Pages production URL are in **Redirect URLs**.
  The local test didn't error, suggesting localhost is currently allowed, but
  the production domain will need adding before Phase 5 deploy.

### Phase 4 — edit mode (authenticated only) ✅
- **Detail drawer, signed-in only:** three new actions appear above the
  existing content — "Edit record", "Mark as verified"/"Mark as needs
  revision", and "Delete". None of these render at all when signed out
  (`bindDrawerViewEvents` short-circuits if `currentUser` is null) — read-only
  visitors see exactly the pre-Phase-4 drawer.
- **Edit record** swaps the drawer into a form (`drawerEditHTML`/
  `bindDrawerEditEvents`) covering every field the read view already shows,
  grouped into the same sections (Identity, Host, Receptor, Host range,
  Reference/provenance, GenBank, UniProt) — 29 fields total. Controlled
  vocabularies (BUILD_SPEC §6: family, gram stain, receptor domain, domain
  class, host range + basis + confidence, GenBank/UniProt tier) render as
  `<select>`; everything else is free text. Required selects get an explicit
  "Select…" placeholder so the form can't silently submit a same-as-first-item
  default. Save does a real Supabase `update(...).eq('id',...).select().single()`,
  and on success swaps the local `DATA` entry and re-renders coverage/overview/
  table/drawer from the row Supabase actually returned (not the local form
  values) — so what you see afterward is what's really in the DB.
- **Verified / Needs revision toggle** flips only `needs_review` — it
  deliberately leaves `verified`/`source` untouched, since those two encode
  *provenance* (rule 4: "did this literally come from PhReD"), a different
  concept than the automated-confidence flag rule 3 describes. Toggling review
  status on a PhReD row doesn't retroactively change where the data came from.
- **Delete** asks for confirmation (`confirm()`) before calling
  `.delete().eq('id',...).select()`. Same RLS-awareness bug described below
  was caught and fixed here.
- **Add a phage:** a `+ Add phage` button (hidden unless signed in) opens a
  modal reusing the identical field config as the edit form. On submit,
  `needs_review: true` and `verified: false` are set **explicitly in code**,
  not left to the table's column defaults — this matters because the schema's
  actual defaults are `needs_review default false` / no default stated for
  `verified` beyond `not null`, i.e. the DB defaults alone do *not* implement
  rule 4. The client now enforces it directly.
- **Who/when:** `updated_at`/`updated_by` are now read (`mapRow` maps
  `created_at`/`updated_at`/`updated_by`) and shown in a new "Editing" section
  in the drawer. `updated_by` is a bare `auth.users` UUID with no public
  column to resolve it to an email from the client (that table isn't exposed
  via PostgREST) — so today it shows "You" when it matches the current
  session, otherwise a truncated UUID fragment. **If the lab wants this to
  show a real name/email for every editor**, that needs either a `profiles`
  table the lab maintains itself, or a `SECURITY DEFINER` Postgres function
  exposing just `auth.users.email` by id — deliberately not added without
  asking, since it's a small but real expansion of what's queryable from the
  anon/authenticated role.
- Source (which was hardcoded to the literal string `"PhReD"` in the drawer
  from Phase 2, since 100% of the seeded data really is PhReD) now reads the
  real `source` column, which `mapRow` didn't even map before this phase — a
  latent gap Phase 2 didn't need to care about yet, but Phase 4's "Add phage"
  flow does, since new rows must NOT claim `source='PhReD'` (rule 4).

**Bug found and fixed during testing:** the first version of `deletePhage()`
called `.delete().eq('id', d.id)` with no `.select()`. When RLS blocks a
delete (e.g. an unauthenticated/anon-role request), PostgREST reports **zero
rows affected but no error** — so the original code treated a silently-blocked
delete as a success and removed the row from the local `DATA` array anyway,
even though the live database was untouched. Caught this by testing with a
client-side-only spoofed sign-in (no real JWT, so RLS correctly rejects the
write) and noticing `DATA.length` dropped from 526→525 in the browser while a
fresh reload still showed 526 — i.e., the UI would have lied about a delete
succeeding. Fixed by chaining `.select()` onto the delete and treating a
zero-row response as a thrown error (see the comment at `deletePhage` in
`index.html`). Re-tested: now correctly shows "Not permitted, or the record
was already removed," and the DB was confirmed intact (526 rows, including
the row I'd tried to delete) both before and after the fix.

**How this was verified (and what's NOT yet verified):** everything above was
exercised in a real (Playwright-driven) Chromium browser against the live
Supabase project, with a client-side-simulated `currentUser` (there's no way
to complete a real magic-link email round-trip in this environment). This
setup is actually the strictest possible test of the write paths: since the
simulated session carries no real Supabase JWT, every write is still sent as
the `anon` role, so **RLS should reject all of it** — and it did, cleanly, for
edit, toggle, add, and (after the fix) delete, each surfacing a readable error
and leaving `DATA`/the live DB unchanged. What this setup *cannot* test is the
happy path of a genuinely authenticated lab member successfully saving an
edit, adding a phage, or deleting a row — that needs a human who has actually
clicked a real magic-link email and holds a real session. **Do that check
once you're signed in for real** — pick a low-stakes record, edit one field,
confirm it persists after a reload, then try Add and Delete on a throwaway
test row you don't mind removing again.

### Phase 5 — deploy (prepped, not executed) ✅ code / ⬜ actual deploy
- **Switched target platform from Netlify to Cloudflare Pages** (user's call —
  wanted to move off Netlify; Cloudflare Pages was picked for the best free
  tier and the closest match to Netlify's git-connected static-deploy
  ergonomics, including the same `_headers`/`_redirects` file convention).
  `netlify.toml` was removed; `_headers` (Cloudflare Pages' equivalent for the
  same baseline security headers) added instead. No build step either way —
  this project has never needed one.
- `README.md` updated with Cloudflare Pages deploy instructions (dashboard
  path and `npx wrangler pages deploy .` CLI path) and the lab-member note
  below.
- I did not actually run the deploy — I don't have your Cloudflare account
  and shouldn't create hosting resources on your behalf without you driving
  that step. The repo is ready for it whenever you are.

## ⚠️ Access-control gap to resolve before any public deploy
This isn't a bug in the Phase 3/4 code — it's a property of the RLS policies
exactly as written in BUILD_SPEC.md §5, which I implemented as given — but it
becomes a real risk the moment this URL is public, so flagging it clearly:

**Every RLS write policy is scoped `to authenticated`, and Supabase Auth's
default project setting allows *any* email address to self-provision an
account via magic link.** There is no separate "lab member" allow-list layered
on top of Supabase's generic `authenticated` role. Concretely: right now,
anyone who finds the URL, clicks "Sign in," and enters any email they control
receives a real magic link, and clicking it makes them a fully authenticated
user — with full edit/add/hard-delete rights over all 526 records, per the
`auth insert`/`auth update`/`auth delete` policies already live in
`supabase/schema.sql`. "Signed in" and "trusted lab member" are being treated
as the same thing, and today they aren't.

**Before sharing the deployed URL outside a small trusted circle**, do one of:
1. In the Supabase dashboard → **Authentication → Settings**, turn off "Allow
   new users to sign up," then invite each real lab member's email from
   **Authentication → Users → Invite** (dashboard-only change, no code). They
   still get the same magic-link sign-in experience afterward.
2. Consciously accept the current open-signup behavior if that's an
   acceptable risk for how this will actually be shared/used.

I didn't make this change myself — it's a Supabase dashboard setting, and
flipping "who can create an account" felt like a call you should make
explicitly rather than one I should make silently. Also see the still-open
Phase 3 item above (Redirect URLs allow-list needs the production Cloudflare
Pages domain added once you deploy).

## Full checklist of what's left for a human
1. ✅ ~~Deploy to Cloudflare~~ — done: live at
   `https://prl.its-the-prithivi-show.workers.dev/` (renamed project from the
   original `piadd`; deployed via Workers +
   static assets, `main` branch, auto-deploys on push).
2. ✅ ~~Add the production URL to Supabase Redirect URLs~~ — done.
3. **Run `supabase/phase6_admin_ban_notifications.sql`** in the Supabase SQL
   editor — required before password/admin/ban/notification features work at
   all (see Phase 6 above for exactly what it does).
4. **Bootstrap yourself as the first admin** — sign in for real once, then
   run the one-line `insert into public.admins...` snippet at the bottom of
   that same SQL file with your own email.
5. **Auth round-trip:** sign in for real (click an actual received magic-link
   email, or set/use a password) and confirm you land back signed in.
6. **Write round-trip:** while genuinely signed in, edit one field, reload,
   confirm it stuck; try Add on a disposable test row; try the full flag →
   wait 72h (or manually backdate `pending_deletion_at` in the SQL editor to
   test sooner) → delete flow as an admin.
7. **Ban round-trip:** as an admin, ban a second test account's email, then
   confirm that account's next write attempt is rejected while it can still
   read.
8. **Supabase dashboard → Authentication → Settings:** decide on and (if
   desired) disable open signups + invite specific lab member emails (see the
   access-control gap above) before sharing the link widely — this is
   independent of and in addition to the ban system, which only helps once
   someone already has an account.

## Files added/changed by this work
- `supabase/schema.sql`, `supabase/seed.sql` — Phase 1 DB setup (already applied).
- `supabase/phase6_admin_ban_notifications.sql` — Phase 6 migration
  (**not yet applied — see checklist above**).
- `.mcp.json` — registers the Supabase MCP server (project-scoped). Still
  pending OAuth as of this session — `mcp__supabase__authenticate` is
  available but hasn't been completed. On a local machine you can run
  `claude` → `/mcp` → authenticate to enable it, or ignore it and use the
  dashboard/SQL editor as before.
- `index.html` — Phase 3 auth UI/logic, Phase 4 edit/add/delete/toggle UI,
  Phase 6 password auth/admin panel/notifications/ban UI (see above).
- `_headers`, `README.md`, `wrangler.jsonc` — Phase 5 deploy config (Cloudflare).
- `BUILD_PROGRESS.md` — this file.
