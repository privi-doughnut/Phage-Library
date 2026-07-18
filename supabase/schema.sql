-- Phage Receptor Library — Phase 1: table, RLS, indexes, trigger
-- Matches BUILD_SPEC.md §5. Delete policy and phage-uniqueness decisions
-- confirmed with the lab during Phase 0 (auth-delete allowed, no unique
-- constraint on phage — see BUILD_SPEC.md history / session notes).

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

-- Row-Level Security
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

-- only authenticated users may delete
-- (confirmed with the lab: flagging via needs_review is the primary triage
-- mechanism; authenticated members can additionally hard-delete rows they've
-- confirmed are wrong)
create policy "auth delete"
  on public.phages for delete
  to authenticated
  using (true);
