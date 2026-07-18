# BUILD SPEC — Phage Receptor Library (Supabase backend)

**Read this whole file before writing any code.** It is the source of truth for what this project is, what every field means, the rules that must not be broken, and the exact plan for the remaining work. When something here conflicts with an assumption you'd otherwise make, this file wins. Ask before deviating.

---

## 1. What this project is

A research database for a phage-biology lab (UNC Charlotte, CIPHER Lab) working toward phage therapy. It catalogs bacteriophages and the **host receptors** they bind — the molecule on the bacterium's surface each phage latches onto. For each phage we record its receptor, the receptor's genetic record (GenBank), the phage's receptor-binding protein (UniProt), a receptor-class label, and a predicted host range.

It is built on and credits **PhReD — The Phage Receptor Database** (Bio-conversion Databank Foundation, https://phred.biodf.org). PhReD supplied the 526 verified phage→receptor rows; this project added the GenBank/UniProt linking, taxonomy resolution, receptor-domain classification, host-range prediction, and an automated verification layer.

The audience is lab scientists, not web users. The design language is **clinical** — precise, legible, data-dense. Two themes: clinical (light) and lab (dark).

**Current state:** a finished, working single-file front end (`phage_receptor_library.html`) with all 526 records baked into the HTML as a JavaScript array. It is feature-complete as a *read-only* tool.

**This task:** replace the baked-in data with a live **Supabase** backend so the lab can read, edit, add, and re-flag records that persist — without editing code. This is a **data-layer refactor, not a redesign.** The UI, interactions, themes, and copy stay as they are.

---

## 2. Files in this folder

- `phage_receptor_library.html` — the current app. **This is the UI to preserve.** Vanilla JS, no framework, no build step. IBM Plex fonts via Google Fonts. Read it fully before changing anything.
- `phage_library_SEED.csv` — 526 rows, snake_case headers, booleans already converted. **Load this into Supabase as the seed data.** Column order matches the schema in §5.
- `phage_library_FULL_526.csv` — the same data with original column names plus extra audit columns (prefixed `_`). Reference only; do not seed from this.
- `BUILD_SPEC.md` — this file.

---

## 3. Rules that must not be broken

These are non-negotiable. They encode trust decisions made with the lab's collaborator (Patrick) over the course of the project.

1. **Every external link is a real, resolved record.** GenBank and UniProt links were pulled live from NCBI/UniProt APIs and verified. Never generate, guess, or synthesize an accession or URL. If a value is absent, it stays absent (`has_genbank=false`, null link). Do not "helpfully" fill blanks.
2. **Host range is PREDICTED, not measured.** `host_range` (Narrow/Broad/Undetermined) is inferred from receptor conservation, not from lab host-range panels. The UI already marks predicted values with a "pred" tag and a basis note. **This honesty marker must survive.** Never present host range as measured fact anywhere in the UI or exports.
3. **The Verified / Needs-revision split is core.** `needs_review=true` means the automated checks weren't fully confident. Patrick will likely discard those rows, but they must stay isolated and clearly labeled, never silently mixed into the verified set. The three-way segment (Verified / Needs revision / All) is a primary navigation control — keep it.
4. **`verified` and `source` reflect provenance.** Every current row came from PhReD (`verified=true`, `source='PhReD'`). If a user adds a row that did NOT come from PhReD, it must NOT be auto-marked verified. New user-added rows default to `verified=false` and `needs_review=true` until a human confirms them.
5. **Don't edit the science to fit the schema.** Receptor descriptions, references, and DOIs are the lab's source data. Store them faithfully. (Example: one row's receptor text legitimately says "lipoteichoic acid" even though its domain label is the generalized "Teichoic Acids" — that is correct, not a bug.)
6. **Preserve the design.** Same layout, fonts, color system, grouping, overview dashboard, detail drawer, help guide, CSV export, and both themes. This refactor changes where data comes from, not how it looks or behaves.

---

## 4. Target architecture

- **Database & auth:** Supabase (Postgres + Supabase Auth + Row-Level Security).
- **Client:** the existing single-file app, using the Supabase JS client (`@supabase/supabase-js` v2) via CDN import. Keep it a static site — no server, no build step if avoidable.
- **Hosting:** Netlify (static deploy). GitHub for the repo.
- **Access model:**
  - **Anonymous / public:** read-only. Can view, search, filter, group, export.
  - **Authenticated (lab members):** everything above, plus edit any field, add a new phage, and move rows between Verified and Needs revision.
- **Secrets:** only the Supabase **anon** key ships in the client (safe with RLS). The **service_role** key is never in client code, never in the repo — server/CLI seeding only. Ask the user for their project URL and anon key when needed; never invent them.

---

## 5. Database schema

Generated from the actual data. Types and nullability reflect real fill rates (e.g. links are null when absent; `domain_class` is null for N/A-domain rows). Booleans are already booleans in the seed CSV.

```sql
-- Enable UUID generation
create extension if not exists "pgcrypto";

create table public.phages (
  id                    uuid primary key default gen_random_uuid(),

  -- identity
  phage                 text not null,
  tailed                boolean not null,
  tail_morphology       text not null,
  family                text not null,

  -- host
  main_host             text not null,
  host_taxid            text,               -- NCBI taxonomy id (kept as text; not an int key)
  host_canonical_name   text,               -- NCBI current name (may differ from main_host)
  gram_stain            text not null,

  -- receptor
  receptor_location     text,
  host_receptor         text not null,
  receptor_domain       text not null,      -- one of the 7 domain labels (see §6)
  domain_class          text,               -- 'Glycan' | 'Protein' | null (N/A rows)

  -- host range (PREDICTED — see rule 2)
  host_range            text not null,      -- 'Narrow' | 'Broad' | 'Undetermined'
  host_range_basis      text not null,      -- 'predicted-from-receptor' | 'insufficient-data'
  host_range_confidence text not null,      -- 'high' | 'medium' | 'low' | 'none'
  host_range_note       text,

  -- reference / provenance
  reference             text,
  doi                   text,
  comments              text,
  source                text not null default 'PhReD',
  source_citation       text,
  date_retrieved        date,
  verified              boolean not null default false,

  -- GenBank (host receptor gene)
  has_genbank           boolean not null default false,
  genbank_link          text,
  genbank_accession     text,
  genbank_tier          text,               -- 'specific gene' | 'host genome (fallback)' | 'none'
  genbank_gene          text,

  -- UniProt (phage RBP)
  has_uniprot           boolean not null default false,
  uniprot_link          text,
  uniprot_accession     text,
  uniprot_tier          text,               -- 'specific RBP' | 'other tail protein' | 'tail protein (internal, low value)' | 'none'
  uniprot_protein       text,

  -- verification layer
  needs_review          boolean not null default false,
  review_reasons        text,               -- ' | '-separated reasons when needs_review
  domain_confidence     text,
  genbank_confidence    text,
  uniprot_confidence    text,

  -- editing metadata
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  updated_by            uuid references auth.users(id)
);

-- keep updated_at fresh
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

create trigger phages_touch_updated
  before update on public.phages
  for each row execute function public.touch_updated_at();

-- helpful indexes for the app's filters/grouping
create index phages_domain_idx     on public.phages (receptor_domain);
create index phages_host_idx       on public.phages (main_host);
create index phages_family_idx     on public.phages (family);
create index phages_needs_review   on public.phages (needs_review);
create index phages_host_range_idx on public.phages (host_range);
```

### Row-Level Security

```sql
alter table public.phages enable row level security;

-- anyone (including anon) may read
create policy "public read"
  on public.phages for select
  using (true);

-- only authenticated users may insert
create policy "auth insert"
  on public.phages for insert
  to authenticated
  with check (true);

-- only authenticated users may update
create policy "auth update"
  on public.phages for update
  to authenticated
  using (true) with check (true);

-- deletes: authenticated only (or omit this policy to forbid deletes entirely — ask the user)
create policy "auth delete"
  on public.phages for delete
  to authenticated
  using (true);
```

### Seeding

Load `phage_library_SEED.csv` (526 rows, headers already match the columns above except `id`/timestamps, which default). Preferred method: Supabase Table Editor → Import CSV, or `psql \copy`. Do **not** seed via the client with the anon key. After seeding, verify: `select count(*)` = 526, and `select count(*) filter (where needs_review)` = 63.

---

## 6. Controlled vocabularies (validate against these)

- **receptor_domain:** `LPS`, `Membrane Proteins`, `Capsular Polysaccharide`, `Pili`, `Flagella`, `Teichoic Acids`, `N/A`
- **domain_class:** `Glycan`, `Protein`, or null
- **host_range:** `Narrow`, `Broad`, `Undetermined`
- **gram_stain:** `Gram negative`, `Gram positive`, `Acid fast`
- **family:** 13 values (Myoviridae, Siphoviridae, Podoviridae, Autographiviridae, Ackermannviridae, Herelleviridae, Drexlerviridae, Inoviridae, Leviviridae, Microviridae, Tectiviridae, Corticoviridae, Cystoviridae)
- **genbank_tier:** `specific gene`, `host genome (fallback)`, `none`
- **uniprot_tier:** `specific RBP`, `other tail protein`, `tail protein (internal, low value)`, `none`

The edit form should offer these as dropdowns where a fixed vocabulary exists, free text otherwise.

---

## 7. How the current app maps to the DB

The app's JS objects use camelCase keys; the DB uses snake_case. Build a thin mapping layer so the rest of the UI keeps its existing field names. Current key → column:

`phage`→phage · `tailed`(yes/no)→tailed(bool) · `tailMorph`→tail_morphology · `family`→family · `host`→main_host · `taxid`→host_taxid · `hostCanon`→host_canonical_name · `gram`→gram_stain · `recLoc`→receptor_location · `receptor`→host_receptor · `domain`→receptor_domain · `domainClass`→domain_class · `hostRange`→host_range · `hostRangeBasis`→host_range_basis · `hrConf`→host_range_confidence · `hostRangeNote`→host_range_note · `ref`→reference · `doi`→doi · `gbHas`(yes/no)→has_genbank(bool) · `gbLink`→genbank_link · `gbAcc`→genbank_accession · `gbTier`→genbank_tier · `gbGene`→genbank_gene · `upHas`(yes/no)→has_uniprot(bool) · `upLink`→uniprot_link · `upAcc`→uniprot_accession · `upTier`→uniprot_tier · `upProtein`→uniprot_protein · `flagged`(bool)→needs_review · `reviewReasons`→review_reasons

Note the boolean conversions: the UI currently uses `'yes'`/`'no'` strings for tailed/gbHas/upHas and a JS boolean for `flagged`. Convert at the mapping layer so you don't have to touch the render functions.

---

## 8. Build plan (phased — get approval on Phase 0 before coding)

**Phase 0 — plan & schema (no code yet).** Read the three files. Confirm the schema in §5 against the seed CSV, flag anything you'd change, and post your plan. Wait for approval.

**Phase 1 — database.** Create the table, RLS, indexes, and trigger. Seed the 526 rows. Verify counts (526 total, 63 needs_review, 512 has_genbank, 185 has_uniprot). Hand back the SQL you actually ran.

**Phase 2 — read path.** Replace the baked-in `DATA` array with a Supabase fetch on load, through the mapping layer in §7, so every existing feature (search, filters, grouping, overview, drawer, export, themes, segment) works unchanged against live data. Add a loading state and a clear error state if the DB is unreachable (in the interface's voice, not an apology). Confirm the app looks and behaves identically to the static version.

**Phase 3 — auth.** Add Supabase Auth (email/password is fine; ask if they want magic-link). A small sign-in control in the masthead. Signed-out = read-only. Do not gate reading behind auth.

**Phase 4 — edit mode (authenticated only).** Edit any field on a record from the detail drawer (dropdowns for the controlled vocabularies in §6, text otherwise); add a new phage via a form; toggle a row between Verified and Needs revision. Writes go through RLS-protected insert/update. Enforce rule 4: user-added rows default `verified=false`, `needs_review=true`. Show who/when via `updated_by`/`updated_at`. Keep the honesty markers (rule 2) intact in any new UI.

**Phase 5 — deploy.** Netlify static deploy, env for the Supabase URL + anon key, notes for the lab on how to add a user. README with run/deploy steps.

At each phase boundary, summarize what changed and what to test before moving on. Don't collapse phases.

---

## 9. Definition of done

- 526 rows live in Supabase; app reads from it; counts match (526 / 63 flagged / 512 GenBank / 185 UniProt).
- Public users read everything; only authenticated users can edit/add.
- Edits and new rows persist and survive reload.
- The entire existing UI, both themes, and all honesty markers are intact.
- No service key in client code or the repo. Anon key only.
- Deployed to Netlify with setup notes.

If anything in this spec seems wrong against the actual data or the current app, stop and ask — don't paper over it.
