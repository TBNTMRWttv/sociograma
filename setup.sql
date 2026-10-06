-- Sociograma: tables and permissions.
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run more than once.

-- Teachers and whether their Go High Level subscription is active.
-- Only the GHL webhook (server side) writes here.
create table if not exists public.teachers (
  email text primary key check (email = lower(email)),
  active boolean not null default false,
  name text,
  updated_at timestamptz not null default now()
);

-- Each teacher's classes, stored as one JSON document per teacher.
create table if not exists public.teacher_data (
  owner uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.teachers enable row level security;
alter table public.teacher_data enable row level security;

-- True when the signed-in teacher's email has an active subscription.
create or replace function public.is_active()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.teachers t
    where t.email = lower(coalesce(auth.jwt() ->> 'email', ''))
      and t.active
  );
$$;
revoke all on function public.is_active() from public, anon;
grant execute on function public.is_active() to authenticated;

-- Table access: nobody signed out; signed-in teachers only through the policies below.
revoke all on public.teachers from anon, authenticated;
revoke all on public.teacher_data from anon, authenticated;
grant select on public.teachers to authenticated;
grant select, insert, update, delete on public.teacher_data to authenticated;
grant all on public.teachers, public.teacher_data to service_role;

-- A teacher can see only her own subscription row.
drop policy if exists "teachers_read_own" on public.teachers;
create policy "teachers_read_own" on public.teachers
  for select to authenticated
  using (email = lower(coalesce(auth.jwt() ->> 'email', '')));

-- A teacher can see and change only her own classes, and only while active.
drop policy if exists "data_select" on public.teacher_data;
drop policy if exists "data_insert" on public.teacher_data;
drop policy if exists "data_update" on public.teacher_data;
drop policy if exists "data_delete" on public.teacher_data;
create policy "data_select" on public.teacher_data
  for select to authenticated
  using (owner = auth.uid() and public.is_active());
create policy "data_insert" on public.teacher_data
  for insert to authenticated
  with check (owner = auth.uid() and public.is_active());
create policy "data_update" on public.teacher_data
  for update to authenticated
  using (owner = auth.uid() and public.is_active())
  with check (owner = auth.uid() and public.is_active());
create policy "data_delete" on public.teacher_data
  for delete to authenticated
  using (owner = auth.uid() and public.is_active());
