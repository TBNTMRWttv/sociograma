-- Sociograma: sharing a class.
-- Run this AFTER setup.sql. Paste the whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run more than once.
--
-- How it works:
-- - A shared class moves out of the owner's private document (teacher_data) into shared_classes.
-- - Private by default: only people the owner adds by email (class_invites) can open it.
--   Each invited person gets a personal link by email (sent by the share-email function).
-- - The owner can switch to "anyone with the link" (link_access 'view' or 'edit').
-- - Viewing needs no account. Editing always needs a login with an active subscription.
-- - The owner's subscription must be active for anyone to open the class.
-- - Tables are closed to the app; everything goes through the functions below, which check access.

-- Clean up the first version of this file, if it was run.
drop table if exists public.share_links cascade;
drop table if exists public.class_members cascade;
do $$ begin
  if to_regclass('public.shared_classes') is not null then
    drop policy if exists "shared_select" on public.shared_classes;
    drop policy if exists "shared_insert" on public.shared_classes;
    drop policy if exists "shared_update" on public.shared_classes;
    drop policy if exists "shared_delete" on public.shared_classes;
  end if;
end $$;
drop function if exists public.join_shared_class(text);
drop function if exists public.class_role(text);
drop function if exists public.class_open(text);

create or replace function public.new_token()
returns text
language sql
volatile
as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
$$;

create table if not exists public.shared_classes (
  id text primary key,
  owner uuid not null references auth.users(id) on delete cascade,
  owner_email text not null default '',
  data jsonb not null default '{}'::jsonb,
  version integer not null default 1,
  updated_at timestamptz not null default now()
);
alter table public.shared_classes add column if not exists link_token text not null default public.new_token();
alter table public.shared_classes add column if not exists link_access text not null default 'private';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'shared_classes_link_token_key') then
    alter table public.shared_classes add constraint shared_classes_link_token_key unique (link_token);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'shared_classes_link_access_check') then
    alter table public.shared_classes add constraint shared_classes_link_access_check check (link_access in ('private', 'view', 'edit'));
  end if;
end $$;

create table if not exists public.class_invites (
  class_id text not null references public.shared_classes(id) on delete cascade,
  email text not null check (email = lower(email)),
  role text not null check (role in ('view', 'edit')),
  token text not null unique default public.new_token(),
  invited_at timestamptz not null default now(),
  notified_at timestamptz,
  primary key (class_id, email)
);

-- No direct access from the app. Only the functions below (and the server) touch these tables.
alter table public.shared_classes enable row level security;
alter table public.class_invites enable row level security;
revoke all on public.shared_classes from anon, authenticated;
revoke all on public.class_invites from anon, authenticated;
grant all on public.shared_classes, public.class_invites to service_role;

create or replace function public.my_email()
returns text
language sql
stable
as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

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

-- What the current person may do with a class: role is 'owner', 'edit', 'view' or null.
-- want_edit is true when they would be an editor but are not logged in or not subscribed.
create or replace function public.share_access(cid text, p_token text, out role text, out want_edit boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.shared_classes%rowtype;
  inv public.class_invites%rowtype;
  me uuid := auth.uid();
  em text := public.my_email();
begin
  role := null; want_edit := false;
  select * into s from public.shared_classes where id = cid;
  if not found or not public.user_active(s.owner) then return; end if;
  if me is not null and s.owner = me then role := 'owner'; return; end if;
  -- invited by email, while logged in with that email
  if me is not null and em <> '' then
    select * into inv from public.class_invites where class_id = cid and email = em;
    if found then role := inv.role; end if;
  end if;
  if p_token is not null and p_token <> '' then
    if p_token = s.link_token then
      -- the class link works for anyone only when it is not private
      if s.link_access <> 'private' and (role is null or (role = 'view' and s.link_access = 'edit')) then
        role := s.link_access;
      end if;
    else
      -- a personal link from the email: anyone holding it can view; editing needs that person's login
      select * into inv from public.class_invites where class_id = cid and token = p_token;
      if found then
        if inv.role = 'edit' and role is distinct from 'edit' then
          if me is not null and em = inv.email then role := 'edit';
          else want_edit := true; role := coalesce(role, 'view'); end if;
        elsif role is null then
          role := 'view';
        end if;
      end if;
    end if;
  end if;
  -- editing needs an account with an active subscription
  if role = 'edit' and (me is null or not public.user_active(me)) then
    role := 'view'; want_edit := true;
  end if;
end;
$$;

-- Everything this person can open: their own shared classes, classes shared with their email,
-- and classes behind the links opened on this device (p_tokens).
-- p_known maps class id to the version the app already has; data is sent only when it changed.
create or replace function public.sync_shared(p_tokens text[], p_known jsonb)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  em text := public.my_email();
  toks jsonb := '{}';
  bad jsonb := '[]';
  out_rows jsonb := '[]';
  t text;
  cid text;
  best_role text;
  best_tok text;
  best_want boolean;
  a record;
  s public.shared_classes%rowtype;
  rank_new int;
  rank_old int;
begin
  -- which class each link belongs to
  foreach t in array coalesce(p_tokens, '{}'::text[]) loop
    cid := null;
    select id into cid from public.shared_classes where link_token = t;
    if cid is null then select class_id into cid from public.class_invites where token = t; end if;
    if cid is null then
      bad := bad || jsonb_build_object('token', t, 'status', 'invalid');
    else
      toks := jsonb_set(toks, array[cid], coalesce(toks -> cid, '[]'::jsonb) || to_jsonb(t));
    end if;
  end loop;

  for cid in
    select id from public.shared_classes where me is not null and owner = me
    union select class_id from public.class_invites where em <> '' and email = em
    union select jsonb_object_keys(toks)
  loop
    best_role := null; best_tok := null; best_want := false; rank_old := 0;
    select * into a from public.share_access(cid, null);
    if a.role is not null then best_role := a.role; best_want := a.want_edit;
      rank_old := case a.role when 'owner' then 3 when 'edit' then 2 else 1 end; end if;
    for t in select jsonb_array_elements_text(coalesce(toks -> cid, '[]'::jsonb)) loop
      if best_tok is null then best_tok := t; end if;
      select * into a from public.share_access(cid, t);
      rank_new := case a.role when 'owner' then 3 when 'edit' then 2 when 'view' then 1 else 0 end;
      if rank_new > rank_old then best_role := a.role; best_tok := t; rank_old := rank_new; best_want := a.want_edit;
      elsif rank_new = rank_old and rank_new > 0 then best_want := best_want or a.want_edit;
      end if;
    end loop;
    select * into s from public.shared_classes where id = cid;
    if best_role is null then
      if best_tok is not null then
        bad := bad || jsonb_build_object('token', best_tok,
          'status', case when public.user_active(s.owner) then 'private' else 'inactive' end);
      end if;
      continue;
    end if;
    out_rows := out_rows || jsonb_build_object(
      'id', s.id, 'token', best_tok, 'role', best_role, 'edit_if_login', best_want,
      'owner_email', s.owner_email, 'version', s.version,
      'data', case when (p_known ->> s.id) is distinct from s.version::text then s.data else null end);
  end loop;
  return json_build_object('classes', out_rows, 'tokens', bad);
end;
$$;

-- Save edits. Fails with 'conflict' (and the newer copy) if someone else saved first.
create or replace function public.save_shared(p_id text, p_token text, p_data jsonb, p_version integer)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  a record;
  v integer;
  cur public.shared_classes%rowtype;
begin
  select * into a from public.share_access(p_id, p_token);
  if a.role is null or a.role = 'view' then
    return json_build_object('ok', false, 'reason', 'forbidden');
  end if;
  if pg_column_size(p_data) > 2000000 then
    return json_build_object('ok', false, 'reason', 'too_big');
  end if;
  update public.shared_classes set data = p_data, version = version + 1, updated_at = now()
    where id = p_id and version = p_version returning version into v;
  if v is not null then return json_build_object('ok', true, 'version', v); end if;
  select * into cur from public.shared_classes where id = p_id;
  return json_build_object('ok', false, 'reason', 'conflict', 'version', cur.version, 'data', cur.data);
end;
$$;

-- Owner: start sharing one of her classes (stays private until she adds people or opens the link).
create or replace function public.share_class(p_id text, p_data jsonb)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  s public.shared_classes%rowtype;
begin
  if me is null or not public.is_active() then return json_build_object('ok', false, 'reason', 'inactive'); end if;
  select * into s from public.shared_classes where id = p_id;
  if found then
    if s.owner = me then return json_build_object('ok', true, 'version', s.version); end if;
    return json_build_object('ok', false, 'reason', 'taken');
  end if;
  insert into public.shared_classes (id, owner, owner_email, data) values (p_id, me, public.my_email(), p_data);
  return json_build_object('ok', true, 'version', 1);
end;
$$;

create or replace function public.is_class_owner(cid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.shared_classes where id = cid and owner = auth.uid());
$$;

-- Owner: link, general access and the people list.
create or replace function public.share_info(p_id text)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare s public.shared_classes%rowtype;
begin
  if not public.is_class_owner(p_id) then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  select * into s from public.shared_classes where id = p_id;
  return json_build_object('ok', true, 'link_token', s.link_token, 'link_access', s.link_access,
    'invites', coalesce((select json_agg(json_build_object('email', email, 'role', role, 'token', token, 'notified_at', notified_at) order by invited_at)
      from public.class_invites where class_id = p_id), '[]'::json));
end;
$$;

-- Owner: add someone by email (or change the role of someone already added).
create or replace function public.share_invite(p_id text, p_email text, p_role text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare em text := lower(trim(coalesce(p_email, '')));
begin
  if not public.is_class_owner(p_id) or not public.is_active() then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  if em !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' or length(em) > 200 then return json_build_object('ok', false, 'reason', 'email'); end if;
  if p_role not in ('view', 'edit') then return json_build_object('ok', false, 'reason', 'role'); end if;
  if em = public.my_email() then return json_build_object('ok', false, 'reason', 'self'); end if;
  if (select count(*) from public.class_invites where class_id = p_id) >= 50
     and not exists (select 1 from public.class_invites where class_id = p_id and email = em) then
    return json_build_object('ok', false, 'reason', 'too_many');
  end if;
  insert into public.class_invites (class_id, email, role) values (p_id, em, p_role)
    on conflict (class_id, email) do update set role = excluded.role;
  return json_build_object('ok', true, 'email', em);
end;
$$;

create or replace function public.share_remove(p_id text, p_email text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_class_owner(p_id) then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  delete from public.class_invites where class_id = p_id and email = lower(trim(p_email));
  return json_build_object('ok', true);
end;
$$;

-- Owner: 'private' (only people added), 'view' or 'edit' (anyone with the link).
create or replace function public.share_link(p_id text, p_access text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_class_owner(p_id) then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  if p_access not in ('private', 'view', 'edit') then return json_build_object('ok', false, 'reason', 'access'); end if;
  update public.shared_classes set link_access = p_access where id = p_id;
  return json_build_object('ok', true);
end;
$$;

-- Owner: stop sharing. Returns the latest copy so the app can keep it as a private class.
create or replace function public.unshare_class(p_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare d jsonb;
begin
  if not public.is_class_owner(p_id) then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  delete from public.shared_classes where id = p_id returning data into d;
  return json_build_object('ok', true, 'data', d);
end;
$$;

-- Someone who was added by email takes the class off their list.
create or replace function public.leave_shared(p_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.class_invites where class_id = p_id and email = public.my_email() and public.my_email() <> '';
  return json_build_object('ok', true);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'new_token()', 'my_email()', 'user_active(uuid)', 'share_access(text,text)', 'sync_shared(text[],jsonb)',
    'save_shared(text,text,jsonb,integer)', 'share_class(text,jsonb)', 'is_class_owner(text)', 'share_info(text)',
    'share_invite(text,text,text)', 'share_remove(text,text)', 'share_link(text,text)', 'unshare_class(text)', 'leave_shared(text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
-- Signed-in teachers and helpers.
grant execute on function public.my_email(), public.user_active(uuid), public.is_class_owner(text),
  public.share_access(text, text), public.sync_shared(text[], jsonb), public.save_shared(text, text, jsonb, integer),
  public.share_class(text, jsonb), public.share_info(text), public.share_invite(text, text, text),
  public.share_remove(text, text), public.share_link(text, text), public.unshare_class(text), public.leave_shared(text)
  to authenticated;
-- People without an account can only open classes through a link (viewing).
grant execute on function public.my_email(), public.user_active(uuid), public.share_access(text, text),
  public.sync_shared(text[], jsonb), public.save_shared(text, text, jsonb, integer) to anon;
grant execute on function public.new_token() to service_role, postgres;
