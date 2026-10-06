-- Sociograma: sharing a class with a link (view only, or view and edit).
-- Run this AFTER setup.sql. Paste the whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run more than once.
--
-- How it works:
-- - A shared class moves out of the teacher's private document (teacher_data) into shared_classes.
-- - share_links holds the secret link tokens. Only the owner can see them.
-- - Opening a link calls join_shared_class(), which adds the person to class_members with that link's role.
-- - People who join do not need their own subscription, but the owner's subscription must be active.

create table if not exists public.shared_classes (
  id text primary key,
  owner uuid not null references auth.users(id) on delete cascade,
  owner_email text not null default '',
  data jsonb not null default '{}'::jsonb,
  version integer not null default 1,
  updated_at timestamptz not null default now()
);

create table if not exists public.class_members (
  class_id text not null references public.shared_classes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null default '',
  role text not null check (role in ('view', 'edit')),
  joined_at timestamptz not null default now(),
  primary key (class_id, user_id)
);

create table if not exists public.share_links (
  token text primary key,
  class_id text not null references public.shared_classes(id) on delete cascade,
  role text not null check (role in ('view', 'edit')),
  created_at timestamptz not null default now(),
  unique (class_id, role)
);

alter table public.shared_classes enable row level security;
alter table public.class_members enable row level security;
alter table public.share_links enable row level security;

-- True when that user's email has an active subscription.
create or replace function public.user_active(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.teachers t
    join auth.users u on lower(u.email) = t.email
    where u.id = uid and t.active
  );
$$;

-- The signed-in person's role in a shared class: 'owner', 'edit', 'view', or null.
create or replace function public.class_role(cid text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when exists (select 1 from public.shared_classes s where s.id = cid and s.owner = auth.uid()) then 'owner'
    else (select m.role from public.class_members m where m.class_id = cid and m.user_id = auth.uid())
  end;
$$;

-- True when the owner of that shared class has an active subscription.
create or replace function public.class_open(cid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select public.user_active(s.owner) from public.shared_classes s where s.id = cid), false);
$$;

revoke all on function public.user_active(uuid) from public, anon;
revoke all on function public.class_role(text) from public, anon;
revoke all on function public.class_open(text) from public, anon;
grant execute on function public.user_active(uuid) to authenticated;
grant execute on function public.class_role(text) to authenticated;
grant execute on function public.class_open(text) to authenticated;

-- Open a share link: adds the signed-in person to the class with the link's role.
-- Someone who already can edit keeps edit when opening a view link.
create or replace function public.join_shared_class(p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  l public.share_links%rowtype;
  s public.shared_classes%rowtype;
  me uuid := auth.uid();
  em text := lower(coalesce(auth.jwt() ->> 'email', ''));
  r text;
begin
  if me is null then
    return json_build_object('ok', false, 'reason', 'signed_out');
  end if;
  select * into l from public.share_links where token = p_token;
  if not found then
    return json_build_object('ok', false, 'reason', 'invalid');
  end if;
  select * into s from public.shared_classes where id = l.class_id;
  if not public.user_active(s.owner) then
    return json_build_object('ok', false, 'reason', 'inactive');
  end if;
  if s.owner = me then
    return json_build_object('ok', true, 'id', s.id, 'role', 'owner');
  end if;
  insert into public.class_members (class_id, user_id, email, role)
  values (s.id, me, em, l.role)
  on conflict (class_id, user_id) do update
    set role = case when public.class_members.role = 'edit' then 'edit' else excluded.role end,
        email = excluded.email;
  select m.role into r from public.class_members m where m.class_id = s.id and m.user_id = me;
  return json_build_object('ok', true, 'id', s.id, 'role', r);
end;
$$;
revoke all on function public.join_shared_class(text) from public, anon;
grant execute on function public.join_shared_class(text) to authenticated;

-- Table access. Members are only added through join_shared_class().
revoke all on public.shared_classes from anon, authenticated;
revoke all on public.class_members from anon, authenticated;
revoke all on public.share_links from anon, authenticated;
grant select, insert, delete on public.shared_classes to authenticated;
grant update (data, version, updated_at) on public.shared_classes to authenticated;
grant select, delete on public.class_members to authenticated;
grant update (role) on public.class_members to authenticated;
grant select, insert, delete on public.share_links to authenticated;
grant all on public.shared_classes, public.class_members, public.share_links to service_role;

drop policy if exists "shared_select" on public.shared_classes;
drop policy if exists "shared_insert" on public.shared_classes;
drop policy if exists "shared_update" on public.shared_classes;
drop policy if exists "shared_delete" on public.shared_classes;
-- Owner and members can read, while the owner is active.
create policy "shared_select" on public.shared_classes
  for select to authenticated
  using (public.class_role(id) is not null and public.user_active(owner));
-- Only an active teacher can share her own class.
create policy "shared_insert" on public.shared_classes
  for insert to authenticated
  with check (owner = auth.uid() and public.is_active());
-- Owner and edit members can change it, while the owner is active.
create policy "shared_update" on public.shared_classes
  for update to authenticated
  using (public.class_role(id) in ('owner', 'edit') and public.user_active(owner))
  with check (public.class_role(id) in ('owner', 'edit') and public.user_active(owner));
-- Only the owner can delete it.
create policy "shared_delete" on public.shared_classes
  for delete to authenticated
  using (owner = auth.uid());

drop policy if exists "members_select" on public.class_members;
drop policy if exists "members_update" on public.class_members;
drop policy if exists "members_delete" on public.class_members;
-- You see your own membership; the owner sees everyone in her class.
create policy "members_select" on public.class_members
  for select to authenticated
  using (user_id = auth.uid() or public.class_role(class_id) = 'owner');
-- Only the owner changes someone's role.
create policy "members_update" on public.class_members
  for update to authenticated
  using (public.class_role(class_id) = 'owner')
  with check (public.class_role(class_id) = 'owner');
-- The owner can remove anyone; anyone can leave.
create policy "members_delete" on public.class_members
  for delete to authenticated
  using (user_id = auth.uid() or public.class_role(class_id) = 'owner');

drop policy if exists "links_select" on public.share_links;
drop policy if exists "links_insert" on public.share_links;
drop policy if exists "links_delete" on public.share_links;
-- Only the owner sees, makes, or turns off links.
create policy "links_select" on public.share_links
  for select to authenticated
  using (public.class_role(class_id) = 'owner');
create policy "links_insert" on public.share_links
  for insert to authenticated
  with check (public.class_role(class_id) = 'owner' and public.class_open(class_id));
create policy "links_delete" on public.share_links
  for delete to authenticated
  using (public.class_role(class_id) = 'owner');
