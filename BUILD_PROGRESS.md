# BUILD PROGRESS — handoff note

This tracks where the Supabase refactor stands so any new Claude Code session
can continue seamlessly. **Read `BUILD_SPEC.md` first** (it's the source of
truth for the plan); this file records what's already done, decisions made, and
what's next. When they conflict, `BUILD_SPEC.md` wins on intent — this file wins
on "what has actually happened so far."

## Current status: Phases 0–2 DONE. Phase 3 (auth) is next.

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

> NOTE on verification environment: the previous work happened in Claude Code on
> the web, whose sandbox browser cannot reach external hosts — so the live
> happy-path render was verified headlessly against a local stub of the real
> data, not a real browser hitting Supabase. **On a local machine you CAN do the
> real check:** `python3 -m http.server 8000` in the repo, open
> `http://localhost:8000/index.html`, confirm it looks identical to the old
> static app and the coverage bar reads 526 / 463 verified / 63 needs revision /
> 97% GenBank / 35% UniProt.

## Decisions made (with the lab / user)
- **Delete policy:** authenticated users CAN hard-delete rows (for genuinely
  wrong entries), in addition to the needs_review flag workflow. The
  `auth delete` RLS policy is live.
- **No unique constraint on `phage`** — a lab may legitimately log two isolates
  under the same name.
- **Auth style (Phase 3):** **magic link** (email one-time link), not
  email+password. Set up Supabase Auth accordingly.

## Next: Phase 3 — auth (magic link)
- Add Supabase Auth magic-link sign-in; a small sign-in control in the masthead.
- Signed-out = read-only (do NOT gate reading behind auth).
- Signed-in lab members unlock editing in Phase 4.
- Keep the existing design/voice.

## Then: Phase 4 (edit mode), Phase 5 (Netlify deploy). See BUILD_SPEC §8.

## Files added by this work
- `supabase/schema.sql`, `supabase/seed.sql` — DB setup (already applied).
- `.mcp.json` — registers the Supabase MCP server (project-scoped). Optional;
  it was left pending OAuth in the web session. On a local machine you can run
  `claude` → `/mcp` → authenticate to enable it, or ignore it and use the
  dashboard/SQL editor as before.
- `BUILD_PROGRESS.md` — this file.
