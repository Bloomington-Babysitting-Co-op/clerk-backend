-- Session settings
set statement_timeout = 0;
set lock_timeout = 0;
set idle_in_transaction_session_timeout = 0;
set client_encoding = 'UTF8';
set standard_conforming_strings = on;
select pg_catalog.set_config('search_path', '', false);
set check_function_bodies = false;
set xmloption = content;
set client_min_messages = warning;
set row_security = off;

-- Extension: required for gen_random_uuid()
create extension if not exists "pgcrypto" with schema "extensions";

-- Table: profiles stores household-level profile metadata and admin flag
create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  family_name text,
  phone text,
  parent_member_names text,
  member_emails text,
  member_phones text,
  address text,
  emergency_contact_names text,
  emergency_contact_phones text,
  children_details text,
  pets text,
  family_photo_url text,
  business_information text,
  notify_new_request boolean not null default false,
  notify_unoffered_48h boolean not null default false,
  notify_request_offered boolean not null default false,
  notify_offer_cancelled_or_edited boolean not null default false,
  notify_ledger_debtor boolean not null default false,
  notify_midmonth_inactive boolean not null default false,
  admin_date_joined date,
  admin_last_background_check date,
  admin_last_dues_payment date,
  admin_general_notes text,
  is_admin boolean default false,
  created_at timestamptz default now()
);

create index profiles_is_admin_idx on public.profiles(is_admin);

-- Table: requests stores all help requests and their lifecycle state by household
create table public.requests (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id) on delete cascade,
  start_time timestamptz,
  end_time timestamptz,
  request_type text not null,
  sit_location text,
  meal_required boolean not null default false,
  meal_prepared_by_sitter boolean not null default false,
  sitters_kids_welcome boolean not null default false,
  allergies_or_pet_concerns text,
  origin text,
  destination text,
  flexible_date boolean not null default false,
  flexible_start_time boolean not null default false,
  flexible_end_time boolean not null default false,
  request_date date,
  hours_offered numeric,
  notes text,
  status text not null,
  accepted_by uuid references public.profiles(id),
  created_at timestamptz default now(),
  constraint requests_status_check check (
    status = any (array['open'::text, 'offered'::text, 'assigned'::text, 'completed'::text, 'cancelled'::text, 'expired'::text])
  ),
  constraint accepted_by_valid check (
    ((status = 'assigned'::text) and (accepted_by is not null))
    or ((status <> 'assigned'::text) and (accepted_by is null))
    or (status = 'completed'::text)
  ),
  constraint requests_request_type_check check (
    request_type = any (array['babysit'::text, 'drive'::text, 'favor'::text])
  ),
  constraint requests_sit_location_check check (
    sit_location is null or sit_location = any (array['sitter_house'::text, 'requester_house'::text, 'either'::text])
  ),
  constraint requests_valid_time_range_check check (
    (start_time is null or end_time is null) or (end_time > start_time)
  ),
  constraint requests_hours_offered_check check (
    hours_offered is null or hours_offered > 0
  ),
  constraint requests_meal_prepared_requires_meal_check check (
    not meal_prepared_by_sitter or meal_required
  )
);

create index requests_owner_idx on public.requests(owner);
create index requests_status_idx on public.requests(status);

-- Table: offers stores offers from households to help with open requests
create table public.offers (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  comment text,
  created_at timestamptz not null default now(),
  unique (request_id, user_id)
);

create index offers_request_id_idx on public.offers(request_id);
create index offers_user_id_idx on public.offers(user_id);

-- Table: household_members maps auth users to shared household profiles
create table public.household_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  household_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz default now()
);

create index household_members_household_idx on public.household_members(household_id);

-- Table: ledger_entries stores hour transfers between households
create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  request uuid references public.requests(id) on delete cascade,
  from_user uuid not null references public.profiles(id),
  to_user uuid not null references public.profiles(id),
  hours numeric not null check (hours > 0),
  "timestamp" timestamptz not null default now(),
  created_at timestamptz default now()
);

create index ledger_request_idx on public.ledger_entries(request);
create index ledger_from_user_idx on public.ledger_entries(from_user);
create index ledger_to_user_idx on public.ledger_entries(to_user);
create index ledger_timestamp_idx on public.ledger_entries("timestamp");

-- Function: get or create the current auth user's household profile
create or replace function public.rpc_current_household_id()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_household_id uuid;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id = auth.uid();

  if v_household_id is not null then
    return v_household_id;
  end if;

  select u.email into v_email
  from auth.users u
  where u.id = auth.uid();

  insert into public.profiles (family_name)
  values (coalesce(nullif(split_part(v_email, '@', 1), ''), 'New Household'))
  returning id into v_household_id;

  insert into public.household_members (user_id, household_id)
  values (auth.uid(), v_household_id)
  on conflict (user_id) do update
  set household_id = excluded.household_id;

  return v_household_id;
end;
$$;

-- RPC: whether current user is an admin
create or replace function public.rpc_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select public.rpc_current_household_id() as household_id
  )
  select exists (
    select 1
    from public.profiles p
    cross join me
    where p.id = me.household_id
      and p.is_admin = true
  );
$$;

-- RPC: link an existing auth user email to the current household profile
create or replace function public.rpc_add_household_member_by_email(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_household_id uuid;
  v_target_user_id uuid;
  v_existing_household uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not public.rpc_is_admin() then
    raise exception 'Admin only';
  end if;

  if p_email is null or btrim(p_email) = '' then
    raise exception 'Email is required';
  end if;

  v_household_id := public.rpc_current_household_id();

  select u.id into v_target_user_id
  from auth.users u
  where lower(u.email) = lower(btrim(p_email));

  if v_target_user_id is null then
    raise exception 'No auth user found for that email';
  end if;

  select hm.household_id into v_existing_household
  from public.household_members hm
  where hm.user_id = v_target_user_id;

  if v_existing_household is not null and v_existing_household <> v_household_id then
    raise exception 'That email is already linked to a different household';
  end if;

  insert into public.household_members (user_id, household_id)
  values (v_target_user_id, v_household_id)
  on conflict (user_id) do update
  set household_id = excluded.household_id;
end;
$$;

-- RPC: list linked login emails for the current household profile
create or replace function public.rpc_list_my_household_emails()
returns table (email text)
language sql
stable
security definer
set search_path = public
as $$
  select u.email
  from public.household_members hm
  join auth.users u on u.id = hm.user_id
  where hm.household_id = public.rpc_current_household_id()
  order by u.email;
$$;

-- Function: create ledger entry once a request transitions to completed
create or replace function public.create_ledger_on_completion()
returns trigger
language plpgsql
set search_path = public
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

create trigger trg_create_ledger_on_completion
after update on public.requests
for each row
execute function public.create_ledger_on_completion();

-- RPC: list all requests for requests page
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
security definer
set search_path = public
as $$
  select r.id, r.start_time, r.end_time, r.request_date, r.request_type, r.status, r.notes, r.hours_offered
  from public.requests r
  order by coalesce(r.start_time, r.request_date::timestamptz) asc;
$$;

-- RPC: get full request details for request view page
create or replace function public.rpc_get_request(p_request_id uuid)
returns public.requests
language sql
stable
security definer
set search_path = public
as $$
  select r.*
  from public.requests r
  where r.id = p_request_id;
$$;

-- RPC: list offers for a request
create or replace function public.rpc_list_offers(p_request_id uuid)
returns table (
  id uuid,
  request_id uuid,
  user_id uuid,
  comment text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select o.id, o.request_id, o.user_id, o.comment, o.created_at
  from public.offers o
  where o.request_id = p_request_id
  order by o.created_at desc;
$$;

-- RPC: create a new request
create or replace function public.rpc_create_request(
  p_request_type text,
  p_notes text,
  p_flexible_date boolean default false,
  p_flexible_start_time boolean default false,
  p_flexible_end_time boolean default false,
  p_request_date date default null,
  p_start_time timestamptz default null,
  p_end_time timestamptz default null,
  p_hours_offered numeric default null,
  p_sit_location text default null,
  p_meal_required boolean default false,
  p_meal_prepared_by_sitter boolean default false,
  p_sitters_kids_welcome boolean default false,
  p_allergies_or_pet_concerns text default null,
  p_origin text default null,
  p_destination text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_hours numeric;
  v_household_id uuid;
begin
  v_household_id := public.rpc_current_household_id();

  if p_request_type not in ('babysit', 'drive', 'favor') then
    raise exception 'Invalid request type';
  end if;

  if p_notes is null or btrim(p_notes) = '' then
    raise exception 'Description is required';
  end if;

  if p_request_type in ('babysit', 'drive') and p_request_date is null and not coalesce(p_flexible_date, false) then
    raise exception 'Date is required for babysit and drive requests';
  end if;

  if p_start_time is not null and p_request_date is null and not coalesce(p_flexible_date, false) then
    raise exception 'Date is required when start time is provided unless date is marked flexible';
  end if;

  if p_end_time is not null and p_request_date is null and not coalesce(p_flexible_date, false) then
    raise exception 'Date is required when end time is provided unless date is marked flexible';
  end if;

  if p_start_time is not null and p_end_time is not null and p_end_time <= p_start_time then
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
    flexible_date,
    flexible_start_time,
    flexible_end_time,
    request_date,
    start_time,
    end_time,
    hours_offered,
    sit_location,
    meal_required,
    meal_prepared_by_sitter,
    sitters_kids_welcome,
    allergies_or_pet_concerns,
    origin,
    destination,
    status
  )
  values (
    v_household_id,
    p_request_type,
    p_notes,
    coalesce(p_flexible_date, false),
    coalesce(p_flexible_start_time, false),
    coalesce(p_flexible_end_time, false),
    p_request_date,
    p_start_time,
    p_end_time,
    v_hours,
    p_sit_location,
    coalesce(p_meal_required, false),
    coalesce(p_meal_prepared_by_sitter, false),
    coalesce(p_sitters_kids_welcome, false),
    p_allergies_or_pet_concerns,
    case when p_request_type = 'drive' then p_origin else null end,
    case when p_request_type = 'drive' then p_destination else null end,
    'open'
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- RPC: update an open request owned by current user
create or replace function public.rpc_update_request(
  p_request_id uuid,
  p_request_date date default null,
  p_flexible_date boolean default false,
  p_flexible_start_time boolean default false,
  p_flexible_end_time boolean default false,
  p_start_time timestamptz default null,
  p_end_time timestamptz default null,
  p_notes text default null,
  p_hours_offered numeric default null,
  p_sit_location text default null,
  p_meal_required boolean default false,
  p_meal_prepared_by_sitter boolean default false,
  p_sitters_kids_welcome boolean default false,
  p_allergies_or_pet_concerns text default null,
  p_origin text default null,
  p_destination text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_type text;
  v_hours numeric;
  v_household_id uuid;
begin
  v_household_id := public.rpc_current_household_id();

  if p_notes is null or btrim(p_notes) = '' then
    raise exception 'Description is required';
  end if;

  select request_type into v_request_type
  from public.requests
  where id = p_request_id
    and owner = v_household_id
    and status = 'open';

  if not found then
    raise exception 'Request not found or not editable';
  end if;

  if v_request_type in ('babysit', 'drive') and p_request_date is null and not coalesce(p_flexible_date, false) then
    raise exception 'Date is required for babysit and drive requests';
  end if;

  if p_start_time is not null and p_request_date is null and not coalesce(p_flexible_date, false) then
    raise exception 'Date is required when start time is provided unless date is marked flexible';
  end if;

  if p_end_time is not null and p_request_date is null and not coalesce(p_flexible_date, false) then
    raise exception 'Date is required when end time is provided unless date is marked flexible';
  end if;

  if p_start_time is not null and p_end_time is not null and p_end_time <= p_start_time then
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
      flexible_date = coalesce(p_flexible_date, false),
      flexible_start_time = coalesce(p_flexible_start_time, false),
      flexible_end_time = coalesce(p_flexible_end_time, false),
      start_time = p_start_time,
      end_time = p_end_time,
      notes = p_notes,
      hours_offered = v_hours,
      sit_location = case when v_request_type = 'babysit' then p_sit_location else null end,
      meal_required = case when v_request_type = 'babysit' then coalesce(p_meal_required, false) else false end,
      meal_prepared_by_sitter = case when v_request_type = 'babysit' then coalesce(p_meal_prepared_by_sitter, false) else false end,
      sitters_kids_welcome = case when v_request_type = 'babysit' then coalesce(p_sitters_kids_welcome, false) else false end,
      allergies_or_pet_concerns = case when v_request_type = 'babysit' then p_allergies_or_pet_concerns else null end,
      origin = case when v_request_type = 'drive' then p_origin else null end,
      destination = case when v_request_type = 'drive' then p_destination else null end
  where id = p_request_id;
end;
$$;

-- RPC: submit an offer on a request
create or replace function public.rpc_offer_request(
  p_request_id uuid,
  p_comment text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.requests%rowtype;
  v_household_id uuid;
begin
  v_household_id := public.rpc_current_household_id();

  select * into v_request
  from public.requests
  where id = p_request_id;

  if not found then
    raise exception 'Request not found';
  end if;

  if v_request.owner = v_household_id then
    raise exception 'Owner cannot offer on own request';
  end if;

  if v_request.status not in ('open', 'offered') then
    raise exception 'Request cannot be offered in current status';
  end if;

  insert into public.offers (request_id, user_id, comment)
  values (p_request_id, v_household_id, p_comment)
  on conflict (request_id, user_id) do nothing;

  update public.requests
  set status = 'offered'
  where id = p_request_id
    and status = 'open';
end;
$$;

-- RPC: owner selects the winning offer and assigns request
create or replace function public.rpc_select_request_winner(
  p_request_id uuid,
  p_offer_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_offer_user uuid;
  v_status text;
  v_household_id uuid;
begin
  v_household_id := public.rpc_current_household_id();

  select owner, status into v_owner, v_status
  from public.requests
  where id = p_request_id;

  if not found then
    raise exception 'Request not found';
  end if;

  if v_owner <> v_household_id then
    raise exception 'Only owner can select winner';
  end if;

  if v_status <> 'offered' then
    raise exception 'Request must be offered before selecting winner';
  end if;

  select o.user_id into v_offer_user
  from public.offers o
  where o.id = p_offer_id
    and o.request_id = p_request_id;

  if v_offer_user is null then
    raise exception 'Offer not found for request';
  end if;

  update public.requests
  set status = 'assigned',
      accepted_by = v_offer_user
  where id = p_request_id;
end;
$$;

-- RPC: complete an assigned request (owner or assignee)
create or replace function public.rpc_complete_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_accepted_by uuid;
  v_status text;
  v_household_id uuid;
begin
  v_household_id := public.rpc_current_household_id();

  select owner, accepted_by, status into v_owner, v_accepted_by, v_status
  from public.requests
  where id = p_request_id;

  if not found then
    raise exception 'Request not found';
  end if;

  if v_status <> 'assigned' then
    raise exception 'Only assigned requests can be completed';
  end if;

  if v_household_id <> v_owner and v_household_id <> v_accepted_by then
    raise exception 'Not allowed to complete this request';
  end if;

  update public.requests
  set status = 'completed'
  where id = p_request_id;
end;
$$;

-- RPC: cancel request while still active
create or replace function public.rpc_cancel_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_household_id uuid;
begin
  v_household_id := public.rpc_current_household_id();

  update public.requests
  set status = 'cancelled',
      accepted_by = null
  where id = p_request_id
    and owner = v_household_id
    and status in ('open', 'offered', 'assigned');

  if not found then
    raise exception 'Request not found or cannot be cancelled';
  end if;
end;
$$;

-- RPC: current user's net ledger balance
create or replace function public.rpc_get_hours_balance()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select public.rpc_current_household_id() as household_id
  )
  select coalesce(sum(
    case
      when le.to_user = me.household_id then le.hours
      when le.from_user = me.household_id then -le.hours
      else 0
    end
  ), 0)
  from public.ledger_entries le
  cross join me;
$$;

-- RPC: dashboard requests owned by current user with future schedules
create or replace function public.rpc_list_user_future_requests()
returns table (
  id uuid,
  start_time timestamptz,
  end_time timestamptz,
  request_date date,
  request_type text,
  status text,
  notes text,
  hours_offered numeric,
  flexible_date boolean,
  flexible_start_time boolean,
  flexible_end_time boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select public.rpc_current_household_id() as household_id
  )
  select
    r.id,
    r.start_time,
    r.end_time,
    r.request_date,
    r.request_type,
    r.status,
    r.notes,
    r.hours_offered,
    r.flexible_date,
    r.flexible_start_time,
    r.flexible_end_time
  from public.requests r
  cross join me
  where r.owner = me.household_id
    and (
      (r.end_time is not null and r.end_time >= now())
      or (r.end_time is null and r.request_date is not null and r.request_date >= current_date)
    )
  order by r.start_time asc;
$$;

-- RPC: dashboard open requests from other users
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
  hours_offered numeric,
  flexible_date boolean,
  flexible_start_time boolean,
  flexible_end_time boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select public.rpc_current_household_id() as household_id
  )
  select
    r.id,
    r.owner,
    r.start_time,
    r.end_time,
    r.request_date,
    r.request_type,
    r.status,
    r.notes,
    r.hours_offered,
    r.flexible_date,
    r.flexible_start_time,
    r.flexible_end_time
  from public.requests r
  cross join me
  where r.status = 'open'
    and r.owner <> me.household_id
    and (
      (r.end_time is not null and r.end_time >= now())
      or (r.end_time is null and r.request_date is not null and r.request_date >= current_date)
    )
  order by r.start_time asc;
$$;

-- RPC: whether current user completed a babysit this calendar month
create or replace function public.rpc_has_completed_sit_this_month()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select public.rpc_current_household_id() as household_id
  )
  select exists (
    select 1
    from public.ledger_entries le
    join public.requests r on r.id = le.request
    cross join me
    where le.from_user = me.household_id
      and r.request_type = 'babysit'
      and le.timestamp >= date_trunc('month', now())
      and le.timestamp < date_trunc('month', now()) + interval '1 month'
  );
$$;

-- RPC: fetch current user's profile details for profile page
create or replace function public.rpc_get_my_profile_details()
returns table (
  id uuid,
  family_name text,
  phone text,
  parent_member_names text,
  member_emails text,
  member_phones text,
  address text,
  emergency_contact_names text,
  emergency_contact_phones text,
  children_details text,
  pets text,
  family_photo_url text,
  business_information text,
  notify_new_request boolean,
  notify_unoffered_48h boolean,
  notify_request_offered boolean,
  notify_offer_cancelled_or_edited boolean,
  notify_ledger_debtor boolean,
  notify_midmonth_inactive boolean,
  admin_date_joined date,
  admin_last_background_check date,
  admin_last_dues_payment date,
  admin_general_notes text,
  is_admin boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select public.rpc_current_household_id() as household_id
  )
  select
    p.id,
    p.family_name,
    p.phone,
    p.parent_member_names,
    p.member_emails,
    p.member_phones,
    p.address,
    p.emergency_contact_names,
    p.emergency_contact_phones,
    p.children_details,
    p.pets,
    p.family_photo_url,
    p.business_information,
    p.notify_new_request,
    p.notify_unoffered_48h,
    p.notify_request_offered,
    p.notify_offer_cancelled_or_edited,
    p.notify_ledger_debtor,
    p.notify_midmonth_inactive,
    p.admin_date_joined,
    p.admin_last_background_check,
    p.admin_last_dues_payment,
    p.admin_general_notes,
    p.is_admin
  from public.profiles p
  cross join me
  where p.id = me.household_id;
$$;

-- RPC: upsert current user's profile details and notification preferences
create or replace function public.rpc_upsert_my_profile_details(
  p_family_name text default null,
  p_phone text default null,
  p_parent_member_names text default null,
  p_member_emails text default null,
  p_member_phones text default null,
  p_address text default null,
  p_emergency_contact_names text default null,
  p_emergency_contact_phones text default null,
  p_children_details text default null,
  p_pets text default null,
  p_family_photo_url text default null,
  p_business_information text default null,
  p_notify_new_request boolean default false,
  p_notify_unoffered_48h boolean default false,
  p_notify_request_offered boolean default false,
  p_notify_offer_cancelled_or_edited boolean default false,
  p_notify_ledger_debtor boolean default false,
  p_notify_midmonth_inactive boolean default false,
  p_admin_date_joined date default null,
  p_admin_last_background_check date default null,
  p_admin_last_dues_payment date default null,
  p_admin_general_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_admin boolean;
  v_household_id uuid;
begin
  v_household_id := public.rpc_current_household_id();

  v_is_admin := public.rpc_is_admin();

  insert into public.profiles (
    id,
    family_name,
    phone,
    parent_member_names,
    member_emails,
    member_phones,
    address,
    emergency_contact_names,
    emergency_contact_phones,
    children_details,
    pets,
    family_photo_url,
    business_information,
    notify_new_request,
    notify_unoffered_48h,
    notify_request_offered,
    notify_offer_cancelled_or_edited,
    notify_ledger_debtor,
    notify_midmonth_inactive,
    admin_date_joined,
    admin_last_background_check,
    admin_last_dues_payment,
    admin_general_notes
  )
  values (
    v_household_id,
    p_family_name,
    p_phone,
    p_parent_member_names,
    p_member_emails,
    p_member_phones,
    p_address,
    p_emergency_contact_names,
    p_emergency_contact_phones,
    p_children_details,
    p_pets,
    p_family_photo_url,
    p_business_information,
    coalesce(p_notify_new_request, false),
    coalesce(p_notify_unoffered_48h, false),
    coalesce(p_notify_request_offered, false),
    coalesce(p_notify_offer_cancelled_or_edited, false),
    coalesce(p_notify_ledger_debtor, false),
    coalesce(p_notify_midmonth_inactive, false),
    case when v_is_admin then p_admin_date_joined else null end,
    case when v_is_admin then p_admin_last_background_check else null end,
    case when v_is_admin then p_admin_last_dues_payment else null end,
    case when v_is_admin then p_admin_general_notes else null end
  )
  on conflict (id) do update
  set family_name = excluded.family_name,
      phone = excluded.phone,
      parent_member_names = excluded.parent_member_names,
      member_emails = excluded.member_emails,
      member_phones = excluded.member_phones,
      address = excluded.address,
      emergency_contact_names = excluded.emergency_contact_names,
      emergency_contact_phones = excluded.emergency_contact_phones,
      children_details = excluded.children_details,
      pets = excluded.pets,
      family_photo_url = excluded.family_photo_url,
      business_information = excluded.business_information,
      notify_new_request = excluded.notify_new_request,
      notify_unoffered_48h = excluded.notify_unoffered_48h,
      notify_request_offered = excluded.notify_request_offered,
      notify_offer_cancelled_or_edited = excluded.notify_offer_cancelled_or_edited,
      notify_ledger_debtor = excluded.notify_ledger_debtor,
      notify_midmonth_inactive = excluded.notify_midmonth_inactive,
      admin_date_joined = case when v_is_admin then excluded.admin_date_joined else public.profiles.admin_date_joined end,
      admin_last_background_check = case when v_is_admin then excluded.admin_last_background_check else public.profiles.admin_last_background_check end,
      admin_last_dues_payment = case when v_is_admin then excluded.admin_last_dues_payment else public.profiles.admin_last_dues_payment end,
      admin_general_notes = case when v_is_admin then excluded.admin_general_notes else public.profiles.admin_general_notes end;
end;
$$;

-- RPC: ledger entries filtered by optional date range
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
security definer
set search_path = public
as $$
  select le.id, le.request, le.timestamp, le.hours, le.from_user, le.to_user
  from public.ledger_entries le
  where (p_start_date is null or le.timestamp >= p_start_date::timestamptz)
    and (p_end_date is null or le.timestamp < (p_end_date::timestamptz + interval '1 day'))
  order by le.timestamp desc;
$$;

-- RPC: per-user ledger balance table for admin ledger page
create or replace function public.rpc_list_ledger_balances()
returns table (
  user_id uuid,
  family_name text,
  hours_balance numeric
)
language sql
stable
security definer
set search_path = public
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

-- RPC: list completed sits for prefill in manual entry flow
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
security definer
set search_path = public
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

-- RPC: list user profiles for from/to selectors
create or replace function public.rpc_list_profiles_for_entry()
returns table (
  id uuid,
  family_name text
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, coalesce(p.family_name, p.id::text) as family_name
  from public.profiles p
  order by p.family_name nulls last, p.id;
$$;

-- RPC: create manual ledger entry (admin unrestricted, non-admin to self only)
create or replace function public.rpc_create_manual_ledger_entry(
  p_from_user uuid,
  p_to_user uuid,
  p_hours numeric,
  p_request uuid default null,
  p_timestamp timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_is_admin boolean;
  v_household_id uuid;
  v_to_user uuid;
  v_timestamp timestamptz;
begin
  v_household_id := public.rpc_current_household_id();

  v_is_admin := public.rpc_is_admin();

  if v_is_admin then
    v_to_user := p_to_user;
    v_timestamp := coalesce(p_timestamp, now());
  else
    if p_to_user <> v_household_id then
      raise exception 'Non-admin entries must use yourself as recipient';
    end if;
    v_to_user := v_household_id;
    v_timestamp := now();
  end if;

  if p_hours is null or p_hours <= 0 then
    raise exception 'Hours must be greater than zero';
  end if;

  if p_from_user = v_to_user then
    raise exception 'From user and to user must be different';
  end if;

  insert into public.ledger_entries (request, from_user, to_user, hours, timestamp)
  values (p_request, p_from_user, v_to_user, p_hours, v_timestamp)
  returning id into v_id;

  return v_id;
end;
$$;

-- RPC: fetch a single ledger entry for edit screen
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
security definer
set search_path = public
as $$
  select le.id, le.request, le.from_user, le.to_user, le.hours, le.timestamp
  from public.ledger_entries le
  where le.id = p_entry_id;
$$;

-- RPC: update ledger entry (admin only)
create or replace function public.rpc_update_ledger_entry(
  p_entry_id uuid,
  p_from_user uuid,
  p_to_user uuid,
  p_hours numeric,
  p_timestamp timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public
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

-- Security: enforce RPC-only access for anon/authenticated
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

grant usage on schema public to anon, authenticated;
grant usage on schema public to service_role;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;

-- RPC grants: only expose the frontend-used API surface
grant execute on function public.rpc_list_requests() to authenticated, service_role;
grant execute on function public.rpc_get_request(uuid) to authenticated, service_role;
grant execute on function public.rpc_list_offers(uuid) to authenticated, service_role;
grant execute on function public.rpc_current_household_id() to authenticated, service_role;
grant execute on function public.rpc_add_household_member_by_email(text) to authenticated, service_role;
grant execute on function public.rpc_list_my_household_emails() to authenticated, service_role;
grant execute on function public.rpc_create_request(text, text, boolean, boolean, boolean, date, timestamptz, timestamptz, numeric, text, boolean, boolean, boolean, text, text, text) to authenticated, service_role;
grant execute on function public.rpc_update_request(uuid, date, boolean, boolean, boolean, timestamptz, timestamptz, text, numeric, text, boolean, boolean, boolean, text, text, text) to authenticated, service_role;
grant execute on function public.rpc_offer_request(uuid, text) to authenticated, service_role;
grant execute on function public.rpc_select_request_winner(uuid, uuid) to authenticated, service_role;
grant execute on function public.rpc_complete_request(uuid) to authenticated, service_role;
grant execute on function public.rpc_cancel_request(uuid) to authenticated, service_role;
grant execute on function public.rpc_get_hours_balance() to authenticated, service_role;
grant execute on function public.rpc_list_user_future_requests() to authenticated, service_role;
grant execute on function public.rpc_list_open_other_requests() to authenticated, service_role;
grant execute on function public.rpc_has_completed_sit_this_month() to authenticated, service_role;
grant execute on function public.rpc_is_admin() to authenticated, service_role;
grant execute on function public.rpc_get_my_profile_details() to authenticated, service_role;
grant execute on function public.rpc_upsert_my_profile_details(text, text, text, text, text, text, text, text, text, text, text, text, boolean, boolean, boolean, boolean, boolean, boolean, date, date, date, text) to authenticated, service_role;
grant execute on function public.rpc_list_ledger_entries_filtered(date, date) to authenticated, service_role;
grant execute on function public.rpc_list_ledger_balances() to authenticated, service_role;
grant execute on function public.rpc_list_completed_sits_for_prefill() to authenticated, service_role;
grant execute on function public.rpc_list_profiles_for_entry() to authenticated, service_role;
grant execute on function public.rpc_create_manual_ledger_entry(uuid, uuid, numeric, uuid, timestamptz) to authenticated, service_role;
grant execute on function public.rpc_get_ledger_entry(uuid) to authenticated, service_role;
grant execute on function public.rpc_update_ledger_entry(uuid, uuid, uuid, numeric, timestamptz) to authenticated, service_role;
