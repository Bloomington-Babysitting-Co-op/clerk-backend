create table if not exists public.claims (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  comment text,
  created_at timestamptz not null default now(),
  unique (request_id, user_id)
);

alter table public.claims enable row level security;

drop policy if exists claims_select on public.claims;

create policy claims_select
on public.claims
for select
using (true);

drop policy if exists claims_insert_own on public.claims;

create policy claims_insert_own
on public.claims
for insert
with check (auth.uid() = user_id);

alter table public.requests drop constraint if exists requests_status_check;

alter table public.requests
add constraint requests_status_check
check (status = any (array['open'::text, 'claimed'::text, 'accepted'::text, 'completed'::text, 'cancelled'::text]));

create or replace function public.rpc_list_ledger_entries()
returns table (
  timestamp timestamptz,
  hours numeric,
  from_user uuid,
  to_user uuid
)
language sql
stable
as $$
  select le.timestamp, le.hours, le.from_user, le.to_user
  from public.ledger_entries le
  order by le.timestamp desc;
$$;

create or replace function public.rpc_get_hours_balance()
returns numeric
language sql
stable
as $$
  select coalesce(sum(
    case
      when le.to_user = auth.uid() then le.hours
      when le.from_user = auth.uid() then -le.hours
      else 0
    end
  ), 0)
  from public.ledger_entries le;
$$;

create or replace function public.rpc_list_user_future_requests()
returns table (
  id uuid,
  start_time timestamptz,
  end_time timestamptz,
  status text,
  notes text
)
language sql
stable
as $$
  select r.id, r.start_time, r.end_time, r.status, r.notes
  from public.requests r
  where r.owner = auth.uid()
    and r.end_time >= now()
  order by r.start_time asc;
$$;

create or replace function public.rpc_list_open_other_requests()
returns table (
  id uuid,
  owner uuid,
  start_time timestamptz,
  end_time timestamptz,
  status text,
  notes text
)
language sql
stable
as $$
  select r.id, r.owner, r.start_time, r.end_time, r.status, r.notes
  from public.requests r
  where r.status = 'open'
    and r.owner <> auth.uid()
    and r.end_time >= now()
  order by r.start_time asc;
$$;

create or replace function public.rpc_list_requests()
returns table (
  id uuid,
  start_time timestamptz,
  end_time timestamptz,
  status text,
  notes text
)
language sql
stable
as $$
  select r.id, r.start_time, r.end_time, r.status, r.notes
  from public.requests r
  order by r.start_time asc;
$$;

create or replace function public.rpc_get_request(p_request_id uuid)
returns public.requests
language sql
stable
as $$
  select r.*
  from public.requests r
  where r.id = p_request_id;
$$;

create or replace function public.rpc_list_claims(p_request_id uuid)
returns table (
  id uuid,
  request_id uuid,
  user_id uuid,
  comment text,
  created_at timestamptz
)
language sql
stable
as $$
  select c.id, c.request_id, c.user_id, c.comment, c.created_at
  from public.claims c
  where c.request_id = p_request_id
  order by c.created_at desc;
$$;

create or replace function public.rpc_create_request(
  p_start_time timestamptz,
  p_end_time timestamptz,
  p_notes text default null
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  insert into public.requests (owner, start_time, end_time, notes, status)
  values (auth.uid(), p_start_time, p_end_time, p_notes, 'open')
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.rpc_update_request(
  p_request_id uuid,
  p_start_time timestamptz,
  p_end_time timestamptz,
  p_notes text default null
)
returns void
language plpgsql
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update public.requests
  set start_time = p_start_time,
      end_time = p_end_time,
      notes = p_notes
  where id = p_request_id
    and owner = auth.uid()
    and status = 'open';

  if not found then
    raise exception 'Request not found or not editable';
  end if;
end;
$$;

create or replace function public.rpc_claim_request(
  p_request_id uuid,
  p_comment text default null
)
returns void
language plpgsql
as $$
declare
  v_request public.requests%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_request
  from public.requests
  where id = p_request_id;

  if not found then
    raise exception 'Request not found';
  end if;

  if v_request.owner = auth.uid() then
    raise exception 'Owner cannot claim own request';
  end if;

  if v_request.status not in ('open', 'claimed') then
    raise exception 'Request cannot be claimed in current status';
  end if;

  insert into public.claims (request_id, user_id, comment)
  values (p_request_id, auth.uid(), p_comment)
  on conflict (request_id, user_id) do nothing;

  update public.requests
  set status = 'claimed'
  where id = p_request_id
    and status = 'open';
end;
$$;

create or replace function public.rpc_select_request_winner(
  p_request_id uuid,
  p_claim_id uuid
)
returns void
language plpgsql
as $$
declare
  v_owner uuid;
  v_claim_user uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select owner, status into v_owner, v_status
  from public.requests
  where id = p_request_id;

  if not found then
    raise exception 'Request not found';
  end if;

  if v_owner <> auth.uid() then
    raise exception 'Only owner can select winner';
  end if;

  if v_status <> 'claimed' then
    raise exception 'Request must be claimed before selecting winner';
  end if;

  select c.user_id into v_claim_user
  from public.claims c
  where c.id = p_claim_id
    and c.request_id = p_request_id;

  if v_claim_user is null then
    raise exception 'Claim not found for request';
  end if;

  update public.requests
  set status = 'accepted',
      accepted_by = v_claim_user
  where id = p_request_id;
end;
$$;

create or replace function public.rpc_complete_request(p_request_id uuid)
returns void
language plpgsql
as $$
declare
  v_owner uuid;
  v_accepted_by uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select owner, accepted_by, status into v_owner, v_accepted_by, v_status
  from public.requests
  where id = p_request_id;

  if not found then
    raise exception 'Request not found';
  end if;

  if v_status <> 'accepted' then
    raise exception 'Only accepted requests can be completed';
  end if;

  if auth.uid() <> v_owner and auth.uid() <> v_accepted_by then
    raise exception 'Not allowed to complete this request';
  end if;

  update public.requests
  set status = 'completed'
  where id = p_request_id;
end;
$$;

grant select, insert on table public.claims to authenticated;
grant select, insert on table public.claims to service_role;

grant execute on function public.rpc_list_ledger_entries() to authenticated, service_role;
grant execute on function public.rpc_get_hours_balance() to authenticated, service_role;
grant execute on function public.rpc_list_user_future_requests() to authenticated, service_role;
grant execute on function public.rpc_list_open_other_requests() to authenticated, service_role;
grant execute on function public.rpc_list_requests() to authenticated, service_role;
grant execute on function public.rpc_get_request(uuid) to authenticated, service_role;
grant execute on function public.rpc_list_claims(uuid) to authenticated, service_role;
grant execute on function public.rpc_create_request(timestamptz, timestamptz, text) to authenticated, service_role;
grant execute on function public.rpc_update_request(uuid, timestamptz, timestamptz, text) to authenticated, service_role;
grant execute on function public.rpc_claim_request(uuid, text) to authenticated, service_role;
grant execute on function public.rpc_select_request_winner(uuid, uuid) to authenticated, service_role;
grant execute on function public.rpc_complete_request(uuid) to authenticated, service_role;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

grant usage on schema public to anon, authenticated;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;

do $$
declare
  fn record;
begin
  for fn in
    select
      n.nspname as schema_name,
      p.proname as function_name,
      pg_get_function_identity_arguments(p.oid) as function_args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname like 'rpc\_%' escape '\\'
  loop
    execute format(
      'grant execute on function %I.%I(%s) to authenticated',
      fn.schema_name,
      fn.function_name,
      fn.function_args
    );
  end loop;
end;
$$;

alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on tables from authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public revoke all on sequences from authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon;
alter default privileges for role postgres in schema public revoke all on functions from authenticated;

alter default privileges for role postgres in schema public grant all on tables to service_role;
alter default privileges for role postgres in schema public grant all on sequences to service_role;
alter default privileges for role postgres in schema public grant all on functions to service_role;