# BUILD PROGRESS — handoff note

This tracks where the Supabase refactor stands so any new Claude Code session
can continue seamlessly. **Read `BUILD_SPEC.md` first** (it's the source of
truth for the plan); this file records what's already done, decisions made, and
what's next. When they conflict, `BUILD_SPEC.md` wins on intent — this file wins
on "what has actually happened so far."

## Current status: Phases 0–5 DONE (code-complete). A few human checks remain — see the checklist at the bottom.

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
1. **Auth round-trip:** sign in for real (click an actual received magic-link
   email) and confirm you land back signed in.
2. **Write round-trip:** while genuinely signed in, edit one field, reload,
   confirm it stuck; try Add and Delete on a disposable test row.
3. **Supabase dashboard → Authentication → URL Configuration:** add the
   eventual Cloudflare Pages production URL to Redirect URLs.
4. **Supabase dashboard → Authentication → Settings:** decide on and (if
   desired) disable open signups + invite specific lab member emails (see gap
   above) before sharing the link widely.
5. **Actually deploy to Cloudflare Pages** (`_headers`/`README.md` are ready;
   see Phase 5 above) — I intentionally didn't do this myself.
6. *(Optional, only if you want editor identity shown, not just "You"/a raw
   UUID)*: decide whether to add a small `profiles` table or a
   `SECURITY DEFINER` email-lookup function, and I can wire that up too.

## Files added/changed by this work
- `supabase/schema.sql`, `supabase/seed.sql` — DB setup (already applied).
- `.mcp.json` — registers the Supabase MCP server (project-scoped). Still
  pending OAuth as of this session — `mcp__supabase__authenticate` is
  available but hasn't been completed. On a local machine you can run
  `claude` → `/mcp` → authenticate to enable it, or ignore it and use the
  dashboard/SQL editor as before.
- `index.html` — Phase 3 auth UI/logic, Phase 4 edit/add/delete/toggle UI and
  logic (see above).
- `_headers`, `README.md` — Phase 5 deploy prep (Cloudflare Pages).
- `BUILD_PROGRESS.md` — this file.
