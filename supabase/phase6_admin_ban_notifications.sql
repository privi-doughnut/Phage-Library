-- Phase 6: admin roles + invites, a password backup for magic-link auth,
-- a 72-hour delete cooldown, an activity/notification feed, and email bans.
--
-- Run this ONCE in the Supabase SQL editor against the live project. It is
-- purely additive (new tables/columns/functions) except for replacing the
-- phages "delete" policy (see below) — safe to run as-is.
--
-- Password auth needs no SQL — Supabase Auth supports email+password out of
-- the box; the client just calls supabase.auth.updateUser({password}) once
-- signed in, and supabase.auth.signInWithPassword() afterward.

-- ── Helper functions (used inside RLS policies below) ────────────────────
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.is_banned()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.banned_emails b
    join auth.users u on lower(u.email) = lower(b.email)
    where u.id = auth.uid()
  );
$$;

-- ── Profiles: lets admins resolve a uuid (updated_by / activity actor) to
--    an email. Regular users can only ever see their OWN row. ────────────
create table if not exists public.profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  created_at  timestamptz not null default now()
);
alter table public.profiles enable row level security;

create policy "self manage own profile" on public.profiles
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "admins read all profiles" on public.profiles
  for select to authenticated using (public.is_admin());

-- ── Admin roles ──────────────────────────────────────────────────────────
create table if not exists public.admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  granted_by  uuid references auth.users(id),
  created_at  timestamptz not null default now()
);
alter table public.admins enable row level security;

create policy "authenticated read admins" on public.admins
  for select to authenticated using (true);

create policy "admins manage admins" on public.admins
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ── Admin invites: an allow-list an admin adds an email to. No email is
--    sent by us — the person just becomes an admin next time they sign in
--    normally (magic link or password) and the client claims the invite. ──
create table if not exists public.admin_invites (
  email       text primary key,
  invited_by  uuid references auth.users(id),
  created_at  timestamptz not null default now()
);
alter table public.admin_invites enable row level security;

create policy "admins manage invites" on public.admin_invites
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create or replace function public.claim_admin_invite()
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  my_email text;
  inv record;
begin
  select email into my_email from auth.users where id = auth.uid();
  if my_email is null then return false; end if;

  select * into inv from public.admin_invites where lower(email) = lower(my_email);
  if not found then return false; end if;

  -- don't resurrect admin access for an email that's since been banned
  if exists (select 1 from public.banned_emails where lower(email) = lower(my_email)) then
    delete from public.admin_invites where lower(email) = lower(my_email);
    return false;
  end if;

  insert into public.admins(user_id, email, granted_by)
  values (auth.uid(), my_email, inv.invited_by)
  on conflict (user_id) do nothing;

  delete from public.admin_invites where lower(email) = lower(my_email);
  return true;
end;
$$;
grant execute on function public.claim_admin_invite() to authenticated;

-- ── Banned emails: cuts off write access (not read access, which is
--    already public) without needing the service_role Admin API. ────────
create table if not exists public.banned_emails (
  email       text primary key,
  banned_by   uuid references auth.users(id),
  reason      text,
  created_at  timestamptz not null default now()
);
alter table public.banned_emails enable row level security;

create policy "admins manage bans" on public.banned_emails
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- lets a signed-in user's client check "am I banned" without exposing the
-- rest of the ban list to them
create policy "self check own ban" on public.banned_emails
  for select to authenticated
  using (
    exists (select 1 from auth.users u where u.id = auth.uid() and lower(u.email) = lower(banned_emails.email))
  );

-- ── Activity log: one row per phages insert/update/delete, via trigger
--    below so it captures every change regardless of code path. ─────────
create table if not exists public.activity_log (
  id          bigint generated always as identity primary key,
  action      text not null,
  phage_name  text not null,
  phage_id    uuid,
  actor       uuid references auth.users(id),
  created_at  timestamptz not null default now()
);
alter table public.activity_log enable row level security;

create policy "authenticated read activity" on public.activity_log
  for select to authenticated using (true);

create or replace function public.log_phage_activity()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_log(action, phage_name, phage_id, actor)
    values ('added', new.phage, new.id, new.updated_by);
  elsif tg_op = 'UPDATE' then
    if new.pending_deletion_at is not null and old.pending_deletion_at is null then
      insert into public.activity_log(action, phage_name, phage_id, actor)
      values ('flagged_deletion', new.phage, new.id, new.updated_by);
    elsif new.pending_deletion_at is null and old.pending_deletion_at is not null then
      insert into public.activity_log(action, phage_name, phage_id, actor)
      values ('deletion_cancelled', new.phage, new.id, new.updated_by);
    elsif new.needs_review is distinct from old.needs_review then
      insert into public.activity_log(action, phage_name, phage_id, actor)
      values (case when new.needs_review then 'flagged_review' else 'verified' end, new.phage, new.id, new.updated_by);
    else
      insert into public.activity_log(action, phage_name, phage_id, actor)
      values ('edited', new.phage, new.id, new.updated_by);
    end if;
  elsif tg_op = 'DELETE' then
    insert into public.activity_log(action, phage_name, phage_id, actor)
    values ('deleted', old.phage, old.id, auth.uid());
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists phages_log_activity on public.phages;
create trigger phages_log_activity
  after insert or update or delete on public.phages
  for each row execute function public.log_phage_activity();

-- Realtime push for the notification bell (client subscribes to this)
alter publication supabase_realtime add table public.activity_log;

-- ── Delete safeguard on phages: flag now, hard-delete only after 72h,
--    admin-only, and blocked entirely for banned emails. ─────────────────
alter table public.phages
  add column if not exists pending_deletion_at timestamptz,
  add column if not exists pending_deletion_by uuid references auth.users(id);

drop policy if exists "auth delete" on public.phages;
drop policy if exists "auth insert" on public.phages;
drop policy if exists "auth update" on public.phages;

create policy "auth insert" on public.phages
  for insert to authenticated with check (not public.is_banned());

create policy "auth update" on public.phages
  for update to authenticated using (not public.is_banned()) with check (not public.is_banned());

create policy "admin delete after cooldown" on public.phages
  for delete to authenticated
  using (
    public.is_admin()
    and not public.is_banned()
    and pending_deletion_at is not null
    and pending_deletion_at <= now() - interval '72 hours'
  );

-- ── One-time bootstrap: make yourself the first admin ────────────────────
-- Sign in to the app for real at least once first (so your auth.users row
-- exists), then run this with YOUR email:
--
--   insert into public.admins(user_id, email, granted_by)
--   select id, email, id from auth.users where lower(email) = lower('you@example.com')
--   on conflict (user_id) do nothing;
