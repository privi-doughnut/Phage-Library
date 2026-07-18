-- Phage Receptor Library — Phase 1 seed
-- Run after schema.sql, from the repo root, with:
--   psql "<connection string>" -f supabase/seed.sql
-- (psql resolves \copy's file path relative to the *client* machine's cwd,
-- so run this from the repository root so the relative path below resolves.)
--
-- Column list below matches phage_library_SEED.csv's ACTUAL header order,
-- which differs from schema.sql's declaration order (verified/source/
-- source_citation/date_retrieved land in different relative positions) —
-- \copy matches columns positionally, not by name, so this list has to
-- follow the file, not the CREATE TABLE statement.
--
-- NULL '' turns the seed CSV's empty strings into real SQL NULL, matching
-- the schema's stated nullability (e.g. domain_class is NULL, not '', on
-- the 55 N/A-domain rows). Postgres's boolean parser accepts 'True'/'False'
-- case-insensitively, so the seed CSV's Python-style booleans load as-is.

\copy public.phages (phage, tailed, tail_morphology, family, main_host, host_taxid, host_canonical_name, gram_stain, receptor_location, host_receptor, receptor_domain, domain_class, host_range, host_range_basis, host_range_confidence, host_range_note, reference, doi, comments, verified, has_genbank, genbank_link, genbank_accession, genbank_tier, genbank_gene, has_uniprot, uniprot_link, uniprot_accession, uniprot_tier, uniprot_protein, source, source_citation, date_retrieved, needs_review, review_reasons, domain_confidence, genbank_confidence, uniprot_confidence) from 'phage_library_SEED.csv' with (format csv, header true, null '');

-- Verification (expected: 526 / 63 / 512 / 185 per BUILD_SPEC.md §5 and §9)
select count(*) as total_rows from public.phages;
select count(*) as needs_review_rows from public.phages where needs_review;
select count(*) as has_genbank_rows from public.phages where has_genbank;
select count(*) as has_uniprot_rows from public.phages where has_uniprot;
