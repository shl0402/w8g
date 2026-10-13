
-- Shared w8g Auth profile and route storage. Apply only to the selected project.
create extension if not exists citext with schema extensions;
create table if not exists public.w8g_profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    username extensions.citext unique not null,
    email text not null
);
alter table public.w8g_profiles enable row level security;
drop policy if exists "Read own profile" on public.w8g_profiles;
create policy "Read own profile" on public.w8g_profiles for select to authenticated using ((select auth.uid()) = id);
grant select on public.w8g_profiles to authenticated;
grant select on public.w8g_profiles to service_role;
revoke all on public.w8g_profiles from anon;
-- Private username lookup is performed only by the app server with its optional service key.
create table if not exists public.w8g_records (
    user_id uuid not null references auth.users(id) on delete cascade,
    id text not null, kind text not null check (kind in ('saved','history')),
    payload jsonb not null, updated double precision not null,
    primary key(user_id,id)
);
alter table public.w8g_records enable row level security;
drop policy if exists "Own route records" on public.w8g_records;
create policy "Own route records" on public.w8g_records for all to authenticated
    using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
grant select,insert,update,delete on public.w8g_records to authenticated;
revoke all on public.w8g_records from anon;
create schema if not exists w8g_private;
revoke all on schema w8g_private from public,anon,authenticated;
-- An auth.users trigger needs a definer function to write the profile before a session exists.
-- No application role may call this function directly; metadata is a display name, never an authorization rule.
create or replace function w8g_private.sync_profile() returns trigger
    language plpgsql security definer set search_path = '' as $$
begin
    insert into public.w8g_profiles(id,username,email)
    values(new.id, coalesce(nullif(new.raw_user_meta_data->>'username',''),split_part(new.email,'@',1)),new.email)
    on conflict(id) do update set username=excluded.username,email=excluded.email;
    return new;
end; $$;
revoke all on function w8g_private.sync_profile() from public,anon,authenticated;
drop trigger if exists w8g_profile on auth.users;
create trigger w8g_profile after insert or update of email,raw_user_meta_data on auth.users for each row execute function w8g_private.sync_profile();
