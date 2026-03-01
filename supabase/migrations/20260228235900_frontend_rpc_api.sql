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
alter table public.requests drop constraint if exists valid_time_range;

alter table public.requests
alter column start_time drop not null,
alter column end_time drop not null;

alter table public.requests
add column if not exists request_type text not null default 'other',
add column if not exists sit_location text,
add column if not exists meal_required boolean not null default false,
add column if not exists meal_prepared_by_sitter boolean not null default false,
add column if not exists sitters_kids_welcome boolean not null default false,
add column if not exists allergies_or_pet_concerns text,
add column if not exists open_for_any_date boolean not null default false,
add column if not exists open_for_alternatives boolean not null default false,
add column if not exists request_date date,
add column if not exists hours_offered numeric;

alter table public.requests
add constraint requests_status_check
check (status = any (array['open'::text, 'claimed'::text, 'accepted'::text, 'completed'::text, 'cancelled'::text]));

alter table public.requests
drop constraint if exists requests_request_type_check;

alter table public.requests
add constraint requests_request_type_check
check (request_type = any (array['babysit'::text, 'drive'::text, 'favor'::text, 'other'::text]));

alter table public.requests
drop constraint if exists requests_sit_location_check;

alter table public.requests
add constraint requests_sit_location_check
check (sit_location is null or sit_location = any (array['sitter_house'::text, 'requester_house'::text, 'either'::text]));

alter table public.requests
drop constraint if exists requests_valid_time_range_check;

alter table public.requests
add constraint requests_valid_time_range_check
check (
  (start_time is null and end_time is null)
  or (start_time is not null and end_time is not null and end_time > start_time)
);

alter table public.requests
drop constraint if exists requests_hours_offered_check;

alter table public.requests
add constraint requests_hours_offered_check
check (hours_offered is null or hours_offered > 0);

alter table public.requests
drop constraint if exists requests_meal_prepared_requires_meal_check;

alter table public.requests
add constraint requests_meal_prepared_requires_meal_check
check (not meal_prepared_by_sitter or meal_required);

alter table public.ledger_entries
alter column request drop not null;

create or replace function public.create_ledger_on_completion()
returns trigger
language plpgsql
as $$
declare
  hours numeric;
begin
  if new.status = 'completed' and old.status <> 'completed' then
    if new.hours_offered is not null then
      hours := new.hours_offered;
    elsif new.start_time is not null and new.end_time is not null then
      hours := extract(epoch from (new.end_time - new.start_time)) / 3600;
    else
      raise exception 'Cannot create ledger entry without hours_offered or time range for request %', new.id;
    end if;

    if hours <= 0 then
      raise exception 'Invalid hours for request %', new.id;
    end if;

    insert into public.ledger_entries (request, from_user, to_user, hours)
    values (new.id, new.owner, new.accepted_by, hours);
  end if;

  return new;
end;
$$;

create or replace function public.rpc_list_ledger_entries()
returns table (
  "timestamp" timestamptz,
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
  request_date date,
  request_type text,
  status text,
  notes text,
  hours_offered numeric
)
language sql
stable
as $$
  select r.id, r.start_time, r.end_time, r.request_date, r.request_type, r.status, r.notes, r.hours_offered
  from public.requests r
  where r.owner = auth.uid()
    and (
      (r.end_time is not null and r.end_time >= now())
      or (r.end_time is null and r.request_date is not null and r.request_date >= current_date)
    )
  order by r.start_time asc;
$$;

create or replace function public.rpc_list_open_other_requests()
returns table (
  id uuid,
  owner uuid,
  start_time timestamptz,
  end_time timestamptz,
  request_date date,
  request_type text,
  status text,
  notes text,
  hours_offered numeric
)
language sql
stable
as $$
  select r.id, r.owner, r.start_time, r.end_time, r.request_date, r.request_type, r.status, r.notes, r.hours_offered
  from public.requests r
  where r.status = 'open'
    and r.owner <> auth.uid()
    and (
      (r.end_time is not null and r.end_time >= now())
      or (r.end_time is null and r.request_date is not null and r.request_date >= current_date)
    )
  order by r.start_time asc;
$$;

create or replace function public.rpc_list_requests()
returns table (
  id uuid,
  start_time timestamptz,
  end_time timestamptz,
  request_date date,
  request_type text,
  status text,
  notes text,
  hours_offered numeric
)
language sql
stable
as $$
  select r.id, r.start_time, r.end_time, r.request_date, r.request_type, r.status, r.notes, r.hours_offered
  from public.requests r
  order by coalesce(r.start_time, r.request_date::timestamptz) asc;
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
  p_request_type text,
  p_notes text,
  p_open_for_any_date boolean default false,
  p_open_for_alternatives boolean default false,
  p_request_date date default null,
  p_start_time timestamptz default null,
  p_end_time timestamptz default null,
  p_hours_offered numeric default null,
  p_sit_location text default null,
  p_meal_required boolean default false,
  p_meal_prepared_by_sitter boolean default false,
  p_sitters_kids_welcome boolean default false,
  p_allergies_or_pet_concerns text default null
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
  v_hours numeric;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_request_type not in ('babysit', 'drive', 'favor', 'other') then
    raise exception 'Invalid request type';
  end if;

  if p_notes is null or btrim(p_notes) = '' then
    raise exception 'Description is required';
  end if;

  if p_request_type in ('babysit', 'drive') and p_request_date is null then
    raise exception 'Date is required for babysit and drive requests';
  end if;

  if (p_start_time is null) <> (p_end_time is null) then
    raise exception 'Start and end time must both be provided, or both be empty';
  end if;

  if p_start_time is not null and p_end_time <= p_start_time then
    raise exception 'End time must be after start time';
  end if;

  if p_meal_prepared_by_sitter and not p_meal_required then
    raise exception 'Meal cannot be prepared by sitter unless meal is required';
  end if;

  v_hours := p_hours_offered;

  if p_request_type = 'babysit' and p_start_time is not null and p_end_time is not null then
    v_hours := extract(epoch from (p_end_time - p_start_time)) / 3600;
  end if;

  if v_hours is not null and v_hours <= 0 then
    raise exception 'Hours offered must be greater than zero';
  end if;

  insert into public.requests (
    owner,
    request_type,
    notes,
    open_for_any_date,
    open_for_alternatives,
    request_date,
    start_time,
    end_time,
    hours_offered,
    sit_location,
    meal_required,
    meal_prepared_by_sitter,
    sitters_kids_welcome,
    allergies_or_pet_concerns,
    status
  )
  values (
    auth.uid(),
    p_request_type,
    p_notes,
    coalesce(p_open_for_any_date, false),
    coalesce(p_open_for_alternatives, false),
    p_request_date,
    p_start_time,
    p_end_time,
    v_hours,
    p_sit_location,
    coalesce(p_meal_required, false),
    coalesce(p_meal_prepared_by_sitter, false),
    coalesce(p_sitters_kids_welcome, false),
    p_allergies_or_pet_concerns,
    'open'
  )
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.rpc_update_request(
  p_request_id uuid,
  p_request_date date default null,
  p_start_time timestamptz default null,
  p_end_time timestamptz default null,
  p_notes text default null,
  p_open_for_any_date boolean default false,
  p_open_for_alternatives boolean default false,
  p_hours_offered numeric default null,
  p_sit_location text default null,
  p_meal_required boolean default false,
  p_meal_prepared_by_sitter boolean default false,
  p_sitters_kids_welcome boolean default false,
  p_allergies_or_pet_concerns text default null
)
returns void
language plpgsql
as $$
declare
  v_request_type text;
  v_hours numeric;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_notes is null or btrim(p_notes) = '' then
    raise exception 'Description is required';
  end if;

  select request_type into v_request_type
  from public.requests
  where id = p_request_id
    and owner = auth.uid()
    and status = 'open';

  if not found then
    raise exception 'Request not found or not editable';
  end if;

  if v_request_type in ('babysit', 'drive') and p_request_date is null then
    raise exception 'Date is required for babysit and drive requests';
  end if;

  if p_start_time is not null and p_request_date is null then
    raise exception 'Date is required when start or end time is provided';
  end if;

  if (p_start_time is null) <> (p_end_time is null) then
    raise exception 'Start and end time must both be provided, or both be empty';
  end if;

  if p_start_time is not null and p_end_time <= p_start_time then
    raise exception 'End time must be after start time';
  end if;

  if p_meal_prepared_by_sitter and not p_meal_required then
    raise exception 'Meal cannot be prepared by sitter unless meal is required';
  end if;

  v_hours := p_hours_offered;

  if v_request_type = 'babysit' and p_start_time is not null and p_end_time is not null then
    v_hours := extract(epoch from (p_end_time - p_start_time)) / 3600;
  end if;

  if v_hours is not null and v_hours <= 0 then
    raise exception 'Hours offered must be greater than zero';
  end if;

  update public.requests
  set request_date = p_request_date,
      start_time = p_start_time,
      end_time = p_end_time,
      notes = p_notes,
      open_for_any_date = coalesce(p_open_for_any_date, false),
      open_for_alternatives = coalesce(p_open_for_alternatives, false),
      hours_offered = v_hours,
      sit_location = case when v_request_type = 'babysit' then p_sit_location else null end,
      meal_required = case when v_request_type = 'babysit' then coalesce(p_meal_required, false) else false end,
      meal_prepared_by_sitter = case when v_request_type = 'babysit' then coalesce(p_meal_prepared_by_sitter, false) else false end,
      sitters_kids_welcome = case when v_request_type = 'babysit' then coalesce(p_sitters_kids_welcome, false) else false end,
      allergies_or_pet_concerns = case when v_request_type = 'babysit' then p_allergies_or_pet_concerns else null end
  where id = p_request_id;
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

create or replace function public.rpc_cancel_request(p_request_id uuid)
returns void
language plpgsql
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update public.requests
  set status = 'cancelled',
      accepted_by = null
  where id = p_request_id
    and owner = auth.uid()
    and status in ('open', 'claimed', 'accepted');

  if not found then
    raise exception 'Request not found or cannot be cancelled';
  end if;
end;
$$;

create or replace function public.rpc_is_admin()
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin = true
  );
$$;

create or replace function public.rpc_has_completed_sit_this_month()
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.ledger_entries le
    join public.requests r on r.id = le.request
    where le.from_user = auth.uid()
      and r.request_type = 'babysit'
      and le.timestamp >= date_trunc('month', now())
      and le.timestamp < date_trunc('month', now()) + interval '1 month'
  );
$$;

create or replace function public.rpc_list_ledger_balances()
returns table (
  user_id uuid,
  family_name text,
  hours_balance numeric
)
language sql
stable
as $$
  with users as (
    select p.id as user_id, p.family_name
    from public.profiles p
  ),
  balances as (
    select
      u.user_id,
      u.family_name,
      coalesce(sum(
        case
          when le.to_user = u.user_id then le.hours
          when le.from_user = u.user_id then -le.hours
          else 0
        end
      ), 0) as hours_balance
    from users u
    left join public.ledger_entries le
      on le.to_user = u.user_id or le.from_user = u.user_id
    group by u.user_id, u.family_name
  )
  select b.user_id, b.family_name, b.hours_balance
  from balances b
  order by b.family_name nulls last, b.user_id;
$$;

create or replace function public.rpc_list_ledger_entries_filtered(
  p_start_date date default null,
  p_end_date date default null
)
returns table (
  id uuid,
  request uuid,
  "timestamp" timestamptz,
  hours numeric,
  from_user uuid,
  to_user uuid
)
language sql
stable
as $$
  select le.id, le.request, le.timestamp, le.hours, le.from_user, le.to_user
  from public.ledger_entries le
  where (p_start_date is null or le.timestamp >= p_start_date::timestamptz)
    and (p_end_date is null or le.timestamp < (p_end_date::timestamptz + interval '1 day'))
  order by le.timestamp desc;
$$;

create or replace function public.rpc_list_completed_sits_for_prefill()
returns table (
  request_id uuid,
  from_user uuid,
  to_user uuid,
  hours numeric,
  completed_at timestamptz,
  notes text
)
language sql
stable
as $$
  select
    r.id as request_id,
    r.owner as from_user,
    r.accepted_by as to_user,
    coalesce(
      r.hours_offered,
      case
        when r.start_time is not null and r.end_time is not null
          then extract(epoch from (r.end_time - r.start_time)) / 3600
        else null
      end
    ) as hours,
    le.timestamp as completed_at,
    r.notes
  from public.requests r
  join public.ledger_entries le on le.request = r.id
  where r.status = 'completed'
  order by le.timestamp desc;
$$;

create or replace function public.rpc_list_profiles_for_entry()
returns table (
  id uuid,
  family_name text
)
language sql
stable
as $$
  select p.id, coalesce(p.family_name, p.id::text) as family_name
  from public.profiles p
  order by p.family_name nulls last, p.id;
$$;

create or replace function public.rpc_create_manual_ledger_entry(
  p_from_user uuid,
  p_to_user uuid,
  p_hours numeric,
  p_request uuid default null,
  p_timestamp timestamptz default null
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
  v_is_admin boolean;
  v_to_user uuid;
  v_timestamp timestamptz;
begin
  v_is_admin := public.rpc_is_admin();

  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if v_is_admin then
    v_to_user := p_to_user;
    v_timestamp := coalesce(p_timestamp, now());
  else
    if p_to_user <> auth.uid() then
      raise exception 'Non-admin entries must use yourself as recipient';
    end if;
    v_to_user := auth.uid();
    v_timestamp := now();
  end if;

  if p_hours is null or p_hours <= 0 then
    raise exception 'Hours must be greater than zero';
  end if;

  if p_from_user = v_to_user then
    raise exception 'From user and to user must be different';
  end if;

  insert into public.ledger_entries (request, from_user, to_user, hours, timestamp)
  values (
    p_request,
    p_from_user,
    v_to_user,
    p_hours,
    v_timestamp
  )
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.rpc_get_ledger_entry(p_entry_id uuid)
returns table (
  id uuid,
  request uuid,
  from_user uuid,
  to_user uuid,
  hours numeric,
  "timestamp" timestamptz
)
language sql
stable
as $$
  select le.id, le.request, le.from_user, le.to_user, le.hours, le.timestamp
  from public.ledger_entries le
  where le.id = p_entry_id;
$$;

create or replace function public.rpc_update_ledger_entry(
  p_entry_id uuid,
  p_from_user uuid,
  p_to_user uuid,
  p_hours numeric,
  p_timestamp timestamptz default null
)
returns void
language plpgsql
as $$
begin
  if not public.rpc_is_admin() then
    raise exception 'Admin only';
  end if;

  if p_hours is null or p_hours <= 0 then
    raise exception 'Hours must be greater than zero';
  end if;

  if p_from_user = p_to_user then
    raise exception 'From user and to user must be different';
  end if;

  update public.ledger_entries
  set from_user = p_from_user,
      to_user = p_to_user,
      hours = p_hours,
      "timestamp" = coalesce(p_timestamp, public.ledger_entries."timestamp")
  where id = p_entry_id;

  if not found then
    raise exception 'Ledger entry not found';
  end if;
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
grant execute on function public.rpc_create_request(text, text, boolean, boolean, date, timestamptz, timestamptz, numeric, text, boolean, boolean, boolean, text) to authenticated, service_role;
grant execute on function public.rpc_update_request(uuid, date, timestamptz, timestamptz, text, boolean, boolean, numeric, text, boolean, boolean, boolean, text) to authenticated, service_role;
grant execute on function public.rpc_claim_request(uuid, text) to authenticated, service_role;
grant execute on function public.rpc_select_request_winner(uuid, uuid) to authenticated, service_role;
grant execute on function public.rpc_complete_request(uuid) to authenticated, service_role;
grant execute on function public.rpc_cancel_request(uuid) to authenticated, service_role;
grant execute on function public.rpc_is_admin() to authenticated, service_role;
grant execute on function public.rpc_has_completed_sit_this_month() to authenticated, service_role;
grant execute on function public.rpc_list_ledger_balances() to authenticated, service_role;
grant execute on function public.rpc_list_ledger_entries_filtered(date, date) to authenticated, service_role;
grant execute on function public.rpc_list_completed_sits_for_prefill() to authenticated, service_role;
grant execute on function public.rpc_list_profiles_for_entry() to authenticated, service_role;
grant execute on function public.rpc_create_manual_ledger_entry(uuid, uuid, numeric, uuid, timestamptz) to authenticated, service_role;
grant execute on function public.rpc_get_ledger_entry(uuid) to authenticated, service_role;
grant execute on function public.rpc_update_ledger_entry(uuid, uuid, uuid, numeric, timestamptz) to authenticated, service_role;

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
      and p.proname like 'rpc!_%' escape '!'
  loop
    execute format(
      'alter function %I.%I(%s) security definer',
      fn.schema_name,
      fn.function_name,
      fn.function_args
    );

    execute format(
      'alter function %I.%I(%s) set search_path = public',
      fn.schema_name,
      fn.function_name,
      fn.function_args
    );
  end loop;
end;
$$;

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
      and p.proname like 'rpc!_%' escape '!'
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