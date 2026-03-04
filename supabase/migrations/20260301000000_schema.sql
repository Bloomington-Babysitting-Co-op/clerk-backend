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

-- Table: families stores shared-family metadata and admin flag
create table public.families (
  id uuid primary key default gen_random_uuid(),
  name text,
  address text,
  emergency_contacts jsonb,
  pets text,
  family_photo_url text,
  notes text,
  admin_date_joined date,
  admin_last_background_check date,
  admin_last_dues_payment date,
  is_active boolean default true,
  is_admin boolean default false
);

create index families_is_admin_idx on public.families(is_admin);

-- Table: family_parents maps auth users to shared families
create table public.family_parents (
  user_id uuid primary key references auth.users(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  name text,
  phone text,
  notify_new_request boolean not null default false,
  notify_unoffered_48h boolean not null default false,
  notify_request_offered boolean not null default false,
  notify_offer_cancelled_or_edited boolean not null default false,
  notify_ledger_debtor boolean not null default false,
  notify_midmonth_inactive boolean not null default false
);

create index family_parents_family_idx on public.family_parents(family_id);

-- Table: family_children stores per-child details for each family
create table public.family_children (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  name text not null,
  date_of_birth date,
  allergies text,
  notes text
);

create index family_children_family_idx on public.family_children(family_id);
create index family_children_date_of_birth_idx on public.family_children(date_of_birth);

-- Table: requests stores all help requests and their lifecycle state by family
create table public.requests (
  id uuid primary key default gen_random_uuid(),
  requester_family_id uuid not null references public.families(id) on delete cascade,
  status text not null,
  type text not null,
  notes text,
  date date,
  start_time time,
  end_time time,
  flexible_date boolean not null default false,
  flexible_start_time boolean not null default false,
  flexible_end_time boolean not null default false,
  hours numeric,
  sit_location text,
  meal_required boolean not null default false,
  meal_prepared_by_sitter boolean not null default false,
  sitters_children_welcome boolean not null default false,
  origin text,
  destination text,
  assignee_family_id uuid references public.families(id),
  created_at timestamptz default now(),
  constraint requests_status_check check (
    status = any (array['open'::text, 'offered'::text, 'assigned'::text, 'completed'::text, 'cancelled'::text, 'expired'::text])
  ),
  constraint assignee_family_id_valid check (
    ((status = 'assigned'::text) and (assignee_family_id is not null))
    or ((status <> 'assigned'::text) and (assignee_family_id is null))
    or (status = 'completed'::text)
  ),
  constraint requests_request_type_check check (
    type = any (array['babysit'::text, 'drive'::text, 'favor'::text])
  ),
  constraint requests_sit_location_check check (
    sit_location is null or sit_location = any (array['sitter_house'::text, 'requester_house'::text, 'either'::text])
  ),
  constraint requests_valid_time_range_check check (
    (start_time is null or end_time is null) or (end_time > start_time)
  ),
  constraint requests_hours_check check (
    hours is null or hours > 0
  ),
  constraint requests_meal_prepared_requires_meal_check check (
    not meal_prepared_by_sitter or meal_required
  )
);

create index requests_requester_family_id_idx on public.requests(requester_family_id);
create index requests_status_idx on public.requests(status);

-- Table: request_children links babysit requests to selected children from the requester's family
create table public.request_children (
  request_id uuid not null references public.requests(id) on delete cascade,
  child_id uuid not null references public.family_children(id) on delete cascade,
  primary key (request_id, child_id)
);

create index request_children_request_id_idx on public.request_children(request_id);
create index request_children_child_id_idx on public.request_children(child_id);

-- Table: offers stores offers from families to help with open requests
create table public.offers (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  notes text,
  created_at timestamptz not null default now(),
  unique (request_id, family_id)
);

create index offers_request_id_idx on public.offers(request_id);
create index offers_family_id_idx on public.offers(family_id);

-- Table: ledger_entries stores hour transfers between families
create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  from_family_id uuid not null references public.families(id),
  to_family_id uuid not null references public.families(id),
  entry_date date not null default (now() at time zone 'America/Indiana/Indianapolis')::date,
  hours numeric not null check (hours > 0),
  notes text,
  request_id uuid references public.requests(id) on delete cascade,
  created_at timestamptz default now()
);

create index ledger_from_family_id_idx on public.ledger_entries(from_family_id);
create index ledger_to_family_id_idx on public.ledger_entries(to_family_id);
create index ledger_entry_date_idx on public.ledger_entries(entry_date);
create index ledger_request_id_idx on public.ledger_entries(request_id);

-- Function: canonical local date for request lifecycle/validation checks
create or replace function public.rpc_local_today()
returns date
language sql
stable
security definer
set search_path = public
as $$
  select (now() at time zone 'America/Indiana/Indianapolis')::date;
$$;

-- Function: canonical local month window bounds for monthly checks
create or replace function public.rpc_local_month_start()
returns date
language sql
stable
security definer
set search_path = public
as $$
  select date_trunc('month', public.rpc_local_today())::date;
$$;

create or replace function public.rpc_local_month_end()
returns date
language sql
stable
security definer
set search_path = public
as $$
  select (public.rpc_local_month_start() + interval '1 month')::date;
$$;

-- Function: refresh request statuses based on date lifecycle
create or replace function public.rpc_refresh_request_statuses()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.requests
  set status = 'expired',
      assignee_family_id = null
  where date < public.rpc_local_today()
    and status in ('open', 'offered');

  update public.requests
  set status = 'completed'
  where date < public.rpc_local_today()
    and status = 'assigned';
end;
$$;

-- Function: get or create the current auth user's family id
create or replace function public.rpc_get_family_id()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_family_id uuid;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select fm.family_id into v_family_id
  from public.family_parents fm
  where fm.user_id = auth.uid();

  if v_family_id is not null then
    if exists (
      select 1
      from public.families f
      where f.id = v_family_id
        and coalesce(f.is_active, true) = false
    ) then
      raise exception 'Family is inactive';
    end if;

    return v_family_id;
  end if;

  select u.email into v_email
  from auth.users u
  where u.id = auth.uid();

  insert into public.families (name)
  values (coalesce(nullif(split_part(v_email, '@', 1), ''), 'New Family'))
  returning id into v_family_id;

  insert into public.family_parents (user_id, family_id)
  values (auth.uid(), v_family_id)
  on conflict (user_id) do update
  set family_id = excluded.family_id;

  return v_family_id;
end;
$$;

-- RPC: whether current user's family is active
create or replace function public.rpc_is_current_family_active()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select public.rpc_get_family_id() as family_id
  )
  select coalesce(f.is_active, true)
  from public.families f
  cross join me
  where f.id = me.family_id;
$$;

-- RPC: whether current user is an admin
create or replace function public.rpc_get_admin_status()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select public.rpc_get_family_id() as family_id
  )
  select exists (
    select 1
    from public.families p
    cross join me
    where p.id = me.family_id
      and p.is_admin = true
  );
$$;

-- RPC: link an existing auth user email to the current shared family
create or replace function public.rpc_add_family_member_by_email(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_family_id uuid;
  v_target_user_id uuid;
  v_existing_family_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not public.rpc_get_admin_status() then
    raise exception 'Admin only';
  end if;

  if p_email is null or btrim(p_email) = '' then
    raise exception 'Email is required';
  end if;

  v_family_id := public.rpc_get_family_id();

  select u.id into v_target_user_id
  from auth.users u
  where lower(u.email) = lower(btrim(p_email));

  if v_target_user_id is null then
    raise exception 'No auth user found for that email';
  end if;

  select fm.family_id into v_existing_family_id
  from public.family_parents fm
  where fm.user_id = v_target_user_id;

  if v_existing_family_id is not null and v_existing_family_id <> v_family_id then
    raise exception 'That email is already linked to a different family';
  end if;

  insert into public.family_parents (user_id, family_id)
  values (v_target_user_id, v_family_id)
  on conflict (user_id) do update
  set family_id = excluded.family_id;
end;
$$;

-- RPC: list linked login emails for the current shared family
create or replace function public.rpc_list_my_family_emails()
returns table (email text)
language sql
stable
security definer
set search_path = public
as $$
  select u.email
  from public.family_parents fm
  join auth.users u on u.id = fm.user_id
  where fm.family_id = public.rpc_get_family_id()
  order by u.email;
$$;

-- RPC: fetch current auth user's parent profile fields
create or replace function public.rpc_get_my_parent_profile()
returns table (
  name text,
  phone text,
  notify_new_request boolean,
  notify_unoffered_48h boolean,
  notify_request_offered boolean,
  notify_offer_cancelled_or_edited boolean,
  notify_ledger_debtor boolean,
  notify_midmonth_inactive boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    fp.name,
    fp.phone,
    fp.notify_new_request,
    fp.notify_unoffered_48h,
    fp.notify_request_offered,
    fp.notify_offer_cancelled_or_edited,
    fp.notify_ledger_debtor,
    fp.notify_midmonth_inactive
  from public.family_parents fp
  where fp.user_id = auth.uid();
$$;

-- RPC: upsert current auth user's parent profile fields
create or replace function public.rpc_upsert_my_parent_profile(
  p_name text default null,
  p_phone text default null,
  p_notify_new_request boolean default false,
  p_notify_unoffered_48h boolean default false,
  p_notify_request_offered boolean default false,
  p_notify_offer_cancelled_or_edited boolean default false,
  p_notify_ledger_debtor boolean default false,
  p_notify_midmonth_inactive boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_family_id uuid;
begin
  v_family_id := public.rpc_get_family_id();

  insert into public.family_parents (
    user_id,
    family_id,
    name,
    phone,
    notify_new_request,
    notify_unoffered_48h,
    notify_request_offered,
    notify_offer_cancelled_or_edited,
    notify_ledger_debtor,
    notify_midmonth_inactive
  )
  values (
    auth.uid(),
    v_family_id,
    nullif(btrim(p_name), ''),
    nullif(btrim(p_phone), ''),
    coalesce(p_notify_new_request, false),
    coalesce(p_notify_unoffered_48h, false),
    coalesce(p_notify_request_offered, false),
    coalesce(p_notify_offer_cancelled_or_edited, false),
    coalesce(p_notify_ledger_debtor, false),
    coalesce(p_notify_midmonth_inactive, false)
  )
  on conflict (user_id) do update
  set family_id = excluded.family_id,
      name = excluded.name,
      phone = excluded.phone,
      notify_new_request = excluded.notify_new_request,
      notify_unoffered_48h = excluded.notify_unoffered_48h,
      notify_request_offered = excluded.notify_request_offered,
      notify_offer_cancelled_or_edited = excluded.notify_offer_cancelled_or_edited,
      notify_ledger_debtor = excluded.notify_ledger_debtor,
      notify_midmonth_inactive = excluded.notify_midmonth_inactive;
end;
$$;

-- RPC: list children for the current shared family
create or replace function public.rpc_list_my_family_children()
returns table (
  id uuid,
  name text,
  date_of_birth date,
  allergies text,
  notes text
)
language sql
stable
security definer
set search_path = public
as $$
  select fc.id, fc.name, fc.date_of_birth, fc.allergies, fc.notes
  from public.family_children fc
  where fc.family_id = public.rpc_get_family_id()
  order by fc.date_of_birth asc, fc.id asc;
$$;

-- RPC: replace all children for the current shared family from JSON array payload
create or replace function public.rpc_replace_my_family_children(p_children jsonb default '[]'::jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_family_id uuid;
begin
  v_family_id := public.rpc_get_family_id();

  delete from public.family_children
  where family_id = v_family_id;

  insert into public.family_children (
    family_id,
    name,
    date_of_birth,
    allergies,
    notes
  )
  select
    v_family_id,
    btrim(child->>'name') as name,
    case
      when nullif(child->>'date_of_birth', '') is null then null
      else to_date((child->>'date_of_birth') || '-15', 'YYYY-MM-DD')
    end as date_of_birth,
    nullif(btrim(child->>'allergies'), '') as allergies,
    nullif(btrim(child->>'notes'), '') as notes
  from jsonb_array_elements(coalesce(p_children, '[]'::jsonb)) as child
  where btrim(coalesce(child->>'name', '')) <> '';
end;
$$;

-- RPC: list requests with optional date filters
create or replace function public.rpc_list_requests_filtered(
  p_start_date date default null,
  p_end_date date default null
)
returns table (
  id uuid,
  start_time time,
  end_time time,
  date date,
  type text,
  status text,
  family_name text,
  notes text,
  hours numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.rpc_refresh_request_statuses();

  return query
  select
    r.id,
    r.start_time,
    r.end_time,
    r.date,
    r.type,
    r.status,
    f.name as family_name,
    r.notes,
    r.hours
  from public.requests r
  join public.families f on f.id = r.requester_family_id
  where (p_start_date is null or (r.date is not null and r.date >= p_start_date))
    and (p_end_date is null or (r.date is not null and r.date <= p_end_date))
  order by r.date asc nulls first
     ,r.start_time asc nulls first
     ,r.id;
end;
$$;

-- RPC: get full request details for request view page
create or replace function public.rpc_get_request(p_request_id uuid)
returns public.requests
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.rpc_refresh_request_statuses();

  return (
    select r
    from public.requests r
    where r.id = p_request_id
  );
end;
$$;

-- RPC: list selected children for a request
create or replace function public.rpc_list_request_children(p_request_id uuid)
returns table (
  id uuid,
  name text,
  date_of_birth date,
  allergies text,
  notes text
)
language sql
stable
security definer
set search_path = public
as $$
  select fc.id, fc.name, fc.date_of_birth, fc.allergies, fc.notes
  from public.request_children rc
  join public.family_children fc on fc.id = rc.child_id
  where rc.request_id = p_request_id
  order by fc.name asc, fc.id asc;
$$;

-- RPC: list offers for a request
create or replace function public.rpc_list_offers(p_request_id uuid)
returns table (
  id uuid,
  request_id uuid,
  family_id uuid,
  family_name text,
  hours_balance numeric,
  has_used_this_month boolean,
  notes text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with balances as (
    select
      fam.id as family_id,
      coalesce(sum(
        case
          when le.to_family_id = fam.id then le.hours
          when le.from_family_id = fam.id then -le.hours
          else 0
        end
      ), 0) as hours_balance
    from public.families fam
    left join public.ledger_entries le
      on le.to_family_id = fam.id or le.from_family_id = fam.id
    group by fam.id
  ),
  monthly_usage as (
    select
      le.from_family_id as family_id,
      true as has_used_this_month
    from public.ledger_entries le
    join public.requests r on r.id = le.request_id
    where r.type = 'babysit'
      and le.entry_date >= public.rpc_local_month_start()
      and le.entry_date < public.rpc_local_month_end()
    group by le.from_family_id
  )
  select
    o.id,
    o.request_id,
    o.family_id,
    f.name as family_name,
    coalesce(b.hours_balance, 0) as hours_balance,
    coalesce(mu.has_used_this_month, false) as has_used_this_month,
    o.notes,
    o.created_at
  from public.offers o
  join public.families f on f.id = o.family_id
  left join balances b on b.family_id = o.family_id
  left join monthly_usage mu on mu.family_id = o.family_id
  where o.request_id = p_request_id
  order by
    coalesce(mu.has_used_this_month, false) asc,
    coalesce(b.hours_balance, 0) asc,
    o.created_at asc,
    o.id asc;
$$;

-- RPC: create a new request
create or replace function public.rpc_create_request(
  p_type text,
  p_notes text,
  p_date date default null,
  p_start_time time default null,
  p_end_time time default null,
  p_flexible_date boolean default false,
  p_flexible_start_time boolean default false,
  p_flexible_end_time boolean default false,
  p_hours numeric default null,
  p_sit_location text default null,
  p_meal_required boolean default false,
  p_meal_prepared_by_sitter boolean default false,
  p_sitters_children_welcome boolean default false,
  p_child_ids uuid[] default null,
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
  v_family_id uuid;
begin
  v_family_id := public.rpc_get_family_id();

  perform public.rpc_refresh_request_statuses();

  if p_type not in ('babysit', 'drive', 'favor') then
    raise exception 'Invalid request type';
  end if;

  if p_notes is null or btrim(p_notes) = '' then
    raise exception 'Description is required';
  end if;

  if p_date is null then
    raise exception 'Request date is required';
  end if;

  if p_date is not null and p_date < public.rpc_local_today() then
    raise exception 'Request date cannot be in the past';
  end if;

  if p_start_time is not null and p_end_time is not null and p_end_time <= p_start_time then
    raise exception 'End time must be after start time';
  end if;

  if p_meal_prepared_by_sitter and not p_meal_required then
    raise exception 'Meal cannot be prepared by sitter unless meal is required';
  end if;

  v_hours := p_hours;

  if p_type = 'babysit' and p_start_time is not null and p_end_time is not null then
    v_hours := ceil(extract(epoch from (p_end_time - p_start_time)) / 900.0) * 0.25;
  end if;

  if v_hours is not null and v_hours <= 0 then
    raise exception 'Hours must be greater than zero';
  end if;

  insert into public.requests (
    requester_family_id,
    type,
    notes,
    date,
    start_time,
    end_time,
    flexible_date,
    flexible_start_time,
    flexible_end_time,
    hours,
    sit_location,
    meal_required,
    meal_prepared_by_sitter,
    sitters_children_welcome,
    origin,
    destination,
    status
  )
  values (
    v_family_id,
    p_type,
    p_notes,
    p_date,
    p_start_time,
    p_end_time,
    coalesce(p_flexible_date, false),
    coalesce(p_flexible_start_time, false),
    coalesce(p_flexible_end_time, false),
    v_hours,
    p_sit_location,
    coalesce(p_meal_required, false),
    coalesce(p_meal_prepared_by_sitter, false),
    coalesce(p_sitters_children_welcome, false),
    case when p_type = 'drive' then p_origin else null end,
    case when p_type = 'drive' then p_destination else null end,
    'open'
  )
  returning id into v_id;

  if p_type = 'babysit' and coalesce(array_length(p_child_ids, 1), 0) > 0 then
    if exists (
      select 1
      from unnest(p_child_ids) as child_id
      left join public.family_children fc
        on fc.id = child_id
       and fc.family_id = v_family_id
      where fc.id is null
    ) then
      raise exception 'Each selected child must belong to your family';
    end if;

    insert into public.request_children (request_id, child_id)
    select v_id, child_id
    from (
      select distinct child_id
      from unnest(p_child_ids) as child_id
    ) as c;
  end if;

  return v_id;
end;
$$;

-- RPC: update an open, offered, or assigned request created by current user
create or replace function public.rpc_update_request(
  p_request_id uuid,
  p_notes text default null,
  p_date date default null,
  p_start_time time default null,
  p_end_time time default null,
  p_flexible_date boolean default false,
  p_flexible_start_time boolean default false,
  p_flexible_end_time boolean default false,
  p_hours numeric default null,
  p_sit_location text default null,
  p_meal_required boolean default false,
  p_meal_prepared_by_sitter boolean default false,
  p_sitters_children_welcome boolean default false,
  p_child_ids uuid[] default null,
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
  v_family_id uuid;
begin
  v_family_id := public.rpc_get_family_id();

  perform public.rpc_refresh_request_statuses();

  if p_notes is null or btrim(p_notes) = '' then
    raise exception 'Description is required';
  end if;

  select type into v_request_type
  from public.requests
  where id = p_request_id
    and requester_family_id = v_family_id
    and status in ('open', 'offered', 'assigned');

  if not found then
    raise exception 'Request not found or not editable';
  end if;

  if p_date is null then
    raise exception 'Request date is required';
  end if;

  if p_date is not null and p_date < public.rpc_local_today() then
    raise exception 'Request date cannot be in the past';
  end if;

  if p_start_time is not null and p_end_time is not null and p_end_time <= p_start_time then
    raise exception 'End time must be after start time';
  end if;

  if p_meal_prepared_by_sitter and not p_meal_required then
    raise exception 'Meal cannot be prepared by sitter unless meal is required';
  end if;

  v_hours := p_hours;

  if v_request_type = 'babysit' and p_start_time is not null and p_end_time is not null then
    v_hours := ceil(extract(epoch from (p_end_time - p_start_time)) / 900.0) * 0.25;
  end if;

  if v_hours is not null and v_hours <= 0 then
    raise exception 'Hours must be greater than zero';
  end if;

  update public.requests
    set notes = p_notes,
      date = p_date,
      start_time = p_start_time,
      end_time = p_end_time,
      flexible_date = coalesce(p_flexible_date, false),
      flexible_start_time = coalesce(p_flexible_start_time, false),
      flexible_end_time = coalesce(p_flexible_end_time, false),
      hours = v_hours,
      sit_location = case when v_request_type = 'babysit' then p_sit_location else null end,
      meal_required = case when v_request_type = 'babysit' then coalesce(p_meal_required, false) else false end,
      meal_prepared_by_sitter = case when v_request_type = 'babysit' then coalesce(p_meal_prepared_by_sitter, false) else false end,
      sitters_children_welcome = case when v_request_type = 'babysit' then coalesce(p_sitters_children_welcome, false) else false end,
      origin = case when v_request_type = 'drive' then p_origin else null end,
      destination = case when v_request_type = 'drive' then p_destination else null end
  where id = p_request_id;

  delete from public.request_children
  where request_id = p_request_id;

  if v_request_type = 'babysit' and coalesce(array_length(p_child_ids, 1), 0) > 0 then
    if exists (
      select 1
      from unnest(p_child_ids) as child_id
      left join public.family_children fc
        on fc.id = child_id
       and fc.family_id = v_family_id
      where fc.id is null
    ) then
      raise exception 'Each selected child must belong to your family';
    end if;

    insert into public.request_children (request_id, child_id)
    select p_request_id, child_id
    from (
      select distinct child_id
      from unnest(p_child_ids) as child_id
    ) as c;
  end if;
end;
$$;

-- RPC: submit an offer on a request
create or replace function public.rpc_offer_request(
  p_request_id uuid,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.requests%rowtype;
  v_family_id uuid;
begin
  v_family_id := public.rpc_get_family_id();

  perform public.rpc_refresh_request_statuses();

  select * into v_request
  from public.requests
  where id = p_request_id;

  if not found then
    raise exception 'Request not found';
  end if;

  if v_request.requester_family_id = v_family_id then
    raise exception 'Requester cannot offer on own request';
  end if;

  if v_request.status not in ('open', 'offered') then
    raise exception 'Request cannot be offered in current status';
  end if;

  insert into public.offers (request_id, family_id, notes)
  values (p_request_id, v_family_id, p_notes)
  on conflict (request_id, family_id) do nothing;

  update public.requests
  set status = 'offered'
  where id = p_request_id
    and status = 'open';
end;
$$;

-- RPC: edit a submitted offer owned by current family
create or replace function public.rpc_update_offer(
  p_offer_id uuid,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_family_id uuid;
  v_offer_request_id uuid;
  v_offer_family_id uuid;
  v_requester_family_id uuid;
  v_request_status text;
  v_assignee_family_id uuid;
begin
  v_family_id := public.rpc_get_family_id();

  select o.request_id, o.family_id
  into v_offer_request_id, v_offer_family_id
  from public.offers o
  where o.id = p_offer_id;

  if v_offer_request_id is null then
    raise exception 'Offer not found';
  end if;

  if v_offer_family_id <> v_family_id then
    raise exception 'Only the offering family can edit this offer';
  end if;

  select r.requester_family_id, r.status, r.assignee_family_id
  into v_requester_family_id, v_request_status, v_assignee_family_id
  from public.requests r
  where r.id = v_offer_request_id;

  if v_requester_family_id is null then
    raise exception 'Request not found';
  end if;

  if v_requester_family_id = v_family_id then
    raise exception 'Requester cannot edit own offer';
  end if;

  if v_request_status not in ('open', 'offered', 'assigned') then
    raise exception 'Offer cannot be edited in current request status';
  end if;

  update public.offers
  set notes = p_notes
  where id = p_offer_id;
end;
$$;

-- RPC: cancel a submitted offer owned by current family
create or replace function public.rpc_cancel_offer(
  p_offer_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_family_id uuid;
  v_offer_request_id uuid;
  v_offer_family_id uuid;
  v_requester_family_id uuid;
  v_request_status text;
  v_assignee_family_id uuid;
begin
  v_family_id := public.rpc_get_family_id();

  perform public.rpc_refresh_request_statuses();

  select o.request_id, o.family_id
  into v_offer_request_id, v_offer_family_id
  from public.offers o
  where o.id = p_offer_id;

  if v_offer_request_id is null then
    raise exception 'Offer not found';
  end if;

  if v_offer_family_id <> v_family_id then
    raise exception 'Only the offering family can cancel this offer';
  end if;

  select r.requester_family_id, r.status, r.assignee_family_id
  into v_requester_family_id, v_request_status, v_assignee_family_id
  from public.requests r
  where r.id = v_offer_request_id;

  if v_requester_family_id is null then
    raise exception 'Request not found';
  end if;

  if v_requester_family_id = v_family_id then
    raise exception 'Requester cannot cancel own offer';
  end if;

  if v_request_status not in ('open', 'offered', 'assigned') then
    raise exception 'Offer cannot be cancelled in current request status';
  end if;

  delete from public.offers
  where id = p_offer_id;

  if v_request_status = 'offered' then
    if not exists (
      select 1 from public.offers o where o.request_id = v_offer_request_id
    ) then
      update public.requests
      set status = 'open'
      where id = v_offer_request_id
        and status = 'offered';
    end if;
  elsif v_request_status = 'assigned' and v_assignee_family_id = v_family_id then
    if exists (
      select 1 from public.offers o where o.request_id = v_offer_request_id
    ) then
      update public.requests
      set status = 'offered',
          assignee_family_id = null
      where id = v_offer_request_id
        and status = 'assigned';
    else
      update public.requests
      set status = 'open',
          assignee_family_id = null
      where id = v_offer_request_id
        and status = 'assigned';
    end if;
  end if;
end;
$$;

-- RPC: requester clears accepted assignee and reopens offer state
create or replace function public.rpc_request_clear_assignee(
  p_request_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_family_id uuid;
  v_requester_family_id uuid;
  v_status text;
begin
  v_family_id := public.rpc_get_family_id();

  perform public.rpc_refresh_request_statuses();

  select requester_family_id, status
  into v_requester_family_id, v_status
  from public.requests
  where id = p_request_id;

  if not found then
    raise exception 'Request not found';
  end if;

  if v_requester_family_id <> v_family_id then
    raise exception 'Only requester can clear accepted offer';
  end if;

  if v_status <> 'assigned' then
    raise exception 'Only assigned requests can clear accepted offer';
  end if;

  update public.requests
  set status = case
        when exists (select 1 from public.offers o where o.request_id = p_request_id) then 'offered'
        else 'open'
      end,
      assignee_family_id = null
  where id = p_request_id
    and status = 'assigned';
end;
$$;

-- RPC: requester selects the winning offer and assigns request
create or replace function public.rpc_request_set_assignee(
  p_request_id uuid,
  p_offer_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_requester_family_id uuid;
  v_offer_family_id uuid;
  v_status text;
  v_family_id uuid;
begin
  v_family_id := public.rpc_get_family_id();

  perform public.rpc_refresh_request_statuses();

  select requester_family_id, status into v_requester_family_id, v_status
  from public.requests
  where id = p_request_id;

  if not found then
    raise exception 'Request not found';
  end if;

  if v_requester_family_id <> v_family_id then
    raise exception 'Only requester can select winner';
  end if;

  if v_status <> 'offered' then
    raise exception 'Request must be offered before selecting winner';
  end if;

  select o.family_id into v_offer_family_id
  from public.offers o
  where o.id = p_offer_id
    and o.request_id = p_request_id;

  if v_offer_family_id is null then
    raise exception 'Offer not found for request';
  end if;

  update public.requests
  set status = 'assigned',
      assignee_family_id = v_offer_family_id
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
  v_family_id uuid;
begin
  v_family_id := public.rpc_get_family_id();

  update public.requests
  set status = 'cancelled',
      assignee_family_id = null
  where id = p_request_id
    and requester_family_id = v_family_id
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
    select public.rpc_get_family_id() as family_id
  )
  select coalesce(sum(
    case
      when le.to_family_id = me.family_id then le.hours
      when le.from_family_id = me.family_id then -le.hours
      else 0
    end
  ), 0)
  from public.ledger_entries le
  cross join me;
$$;

-- RPC: dashboard all non-terminal unassigned requests
create or replace function public.rpc_list_requests_other_open()
returns table (
  id uuid,
  requester_family_id uuid,
  family_name text,
  status text,
  type text,
  notes text,
  date date,
  start_time time,
  end_time time,
  flexible_date boolean,
  flexible_start_time boolean,
  flexible_end_time boolean,
  hours numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.rpc_refresh_request_statuses();

  return query
  with me as (
    select public.rpc_get_family_id() as family_id
  )
  select
    r.id,
    r.requester_family_id,
    f.name as family_name,
    r.status,
    r.type,
    r.notes,
    r.date,
    r.start_time,
    r.end_time,
    r.flexible_date,
    r.flexible_start_time,
    r.flexible_end_time,
    r.hours
  from public.requests r
  join public.families f on f.id = r.requester_family_id
  cross join me
  where r.status in ('open', 'offered')
    and r.requester_family_id <> me.family_id
    and not exists (
      select 1
      from public.offers o
      where o.request_id = r.id
        and o.family_id = me.family_id
    )
  order by r.date asc nulls first
     ,r.start_time asc nulls first
     ,r.id;
end;
$$;

-- RPC: dashboard active requests created by current user
create or replace function public.rpc_list_requests_my_family_future()
returns table (
  id uuid,
  family_name text,
  status text,
  type text,
  notes text,
  date date,
  start_time time,
  end_time time,
  flexible_date boolean,
  flexible_start_time boolean,
  flexible_end_time boolean,
  hours numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.rpc_refresh_request_statuses();

  return query
  with me as (
    select public.rpc_get_family_id() as family_id
  )
  select
    r.id,
    f.name as family_name,
    r.status,
    r.type,
    r.notes,
    r.date,
    r.start_time,
    r.end_time,
    r.flexible_date,
    r.flexible_start_time,
    r.flexible_end_time,
    r.hours
  from public.requests r
  join public.families f on f.id = r.requester_family_id
  cross join me
  where r.requester_family_id = me.family_id
    and r.status not in ('completed', 'cancelled', 'expired')
    and (
      (r.date is not null and r.date > public.rpc_local_today())
      or (
        r.date = public.rpc_local_today()
        and (r.end_time is null or r.end_time >= (now() at time zone 'America/Indiana/Indianapolis')::time)
      )
      or (r.date is null and coalesce(r.flexible_date, false))
    )
  order by r.date asc nulls first
     ,r.start_time asc nulls first
     ,r.id;
end;
$$;

-- RPC: dashboard requests from other families that current family has submitted offers on
create or replace function public.rpc_list_offers_my_submitted()
returns table (
  id uuid,
  requester_family_id uuid,
  family_name text,
  status text,
  type text,
  notes text,
  date date,
  start_time time,
  end_time time,
  flexible_date boolean,
  flexible_start_time boolean,
  flexible_end_time boolean,
  hours numeric,
  offer_created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.rpc_refresh_request_statuses();

  return query
  with me as (
    select public.rpc_get_family_id() as family_id
  )
  select
    r.id,
    r.requester_family_id,
    f.name as family_name,
    r.status,
    r.type,
    r.notes,
    r.date,
    r.start_time,
    r.end_time,
    r.flexible_date,
    r.flexible_start_time,
    r.flexible_end_time,
    r.hours,
    o.created_at as offer_created_at
  from public.offers o
  join public.requests r on r.id = o.request_id
  join public.families f on f.id = r.requester_family_id
  cross join me
  where o.family_id = me.family_id
    and r.requester_family_id <> me.family_id
    and r.status not in ('completed', 'cancelled', 'expired')
  order by r.date asc nulls first
    ,r.start_time asc nulls first
    ,o.created_at desc
    ,r.id;
end;
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
    select public.rpc_get_family_id() as family_id
  )
  select exists (
    select 1
    from public.ledger_entries le
    join public.requests r on r.id = le.request_id
    cross join me
    where le.from_family_id = me.family_id
      and r.type = 'babysit'
      and le.entry_date >= public.rpc_local_month_start()
      and le.entry_date < public.rpc_local_month_end()
  );
$$;

-- RPC: fetch current user's family details for profile page
create or replace function public.rpc_get_my_family_details()
returns table (
  id uuid,
  name text,
  address text,
  emergency_contacts jsonb,
  pets text,
  family_photo_url text,
  notes text,
  admin_date_joined date,
  admin_last_background_check date,
  admin_last_dues_payment date,
  is_admin boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select public.rpc_get_family_id() as family_id
  )
  select
    p.id,
    p.name,
    p.address,
    p.emergency_contacts,
    p.pets,
    p.family_photo_url,
    p.notes,
    p.admin_date_joined,
    p.admin_last_background_check,
    p.admin_last_dues_payment,
    p.is_admin
  from public.families p
  cross join me
  where p.id = me.family_id;
$$;

-- RPC: upsert current user's family details
create or replace function public.rpc_upsert_my_family_details(
  p_name text default null,
  p_address text default null,
  p_emergency_contacts jsonb default null,
  p_pets text default null,
  p_family_photo_url text default null,
  p_business_information text default null,
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
  v_family_id uuid;
  v_emergency_contacts jsonb;
begin
  v_family_id := public.rpc_get_family_id();
  v_emergency_contacts := p_emergency_contacts;

  if v_emergency_contacts is not null then
    if jsonb_typeof(v_emergency_contacts) <> 'array' then
      raise exception 'Emergency contacts must be a JSON array';
    end if;

    if exists (
      select 1
      from jsonb_array_elements(v_emergency_contacts) as contact
      where jsonb_typeof(contact) <> 'object'
         or nullif(btrim(contact->>'name'), '') is null
         or nullif(btrim(contact->>'phone'), '') is null
    ) then
      raise exception 'Each emergency contact must include non-empty name and phone';
    end if;
  end if;

  v_is_admin := public.rpc_get_admin_status();

  insert into public.families (
    id,
    name,
    address,
    emergency_contacts,
    pets,
    family_photo_url,
    notes,
    admin_date_joined,
    admin_last_background_check,
    admin_last_dues_payment
  )
  values (
    v_family_id,
    p_name,
    p_address,
    v_emergency_contacts,
    p_pets,
    p_family_photo_url,
    p_notes,
    case when v_is_admin then p_admin_date_joined else null end,
    case when v_is_admin then p_admin_last_background_check else null end,
    case when v_is_admin then p_admin_last_dues_payment else null end
  )
  on conflict (id) do update
  set name = excluded.name,
      address = excluded.address,
      emergency_contacts = excluded.emergency_contacts,
      pets = excluded.pets,
      family_photo_url = excluded.family_photo_url,
      notes = excluded.notes,
      admin_date_joined = case when v_is_admin then excluded.admin_date_joined else public.families.admin_date_joined end,
      admin_last_background_check = case when v_is_admin then excluded.admin_last_background_check else public.families.admin_last_background_check end,
      admin_last_dues_payment = case when v_is_admin then excluded.admin_last_dues_payment else public.families.admin_last_dues_payment end;
end;
$$;

-- RPC: ledger entries filtered by optional date range
create or replace function public.rpc_list_ledger_entries_filtered(
  p_start_date date default null,
  p_end_date date default null
)
returns table (
  id uuid,
  from_family_id uuid,
  to_family_id uuid,
  from_family_name text,
  to_family_name text
  entry_date date,
  hours numeric,
  request_id uuid,
)
language sql
stable
security definer
set search_path = public
as $$
  select
    le.id,
    le.from_family_id,
    le.to_family_id,
    ff.name as from_family_name,
    tf.name as to_family_name
    le.entry_date,
    le.hours,
    le.request_id,
  from public.ledger_entries le
  left join public.families ff on ff.id = le.from_family_id
  left join public.families tf on tf.id = le.to_family_id
  where (p_start_date is null or le.entry_date >= p_start_date)
    and (p_end_date is null or le.entry_date <= p_end_date)
  order by le.entry_date desc;
$$;

-- RPC: per-user ledger balance table for admin ledger page
create or replace function public.rpc_list_ledger_balances()
returns table (
  family_id uuid,
  name text,
  hours_balance numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with users as (
    select p.id as family_id, p.name
    from public.families p
  ),
  balances as (
    select
      u.family_id,
      u.name,
      coalesce(sum(
        case
          when le.to_family_id = u.family_id then le.hours
          when le.from_family_id = u.family_id then -le.hours
          else 0
        end
      ), 0) as hours_balance
    from users u
    left join public.ledger_entries le
      on le.to_family_id = u.family_id or le.from_family_id = u.family_id
    group by u.family_id, u.name
  )
  select b.family_id, b.name, b.hours_balance
  from balances b
  order by b.name nulls last, b.family_id;
$$;

-- RPC: list completed sits for entry creation
create or replace function public.rpc_list_requests_completed_for_entry()
returns table (
  request_id uuid,
  from_family_id uuid,
  to_family_id uuid,
  request_date date,
  sit_location text,
  meal_required boolean,
  hours numeric,
  notes text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.id as request_id,
    r.requester_family_id as from_family_id,
    r.assignee_family_id as to_family_id,
    r.date as request_date,
    r.sit_location,
    r.meal_required,
    coalesce(
      r.hours,
      case
        when r.start_time is not null and r.end_time is not null
          then ceil(extract(epoch from (r.end_time - r.start_time)) / 900.0) * 0.25
        else null
      end
    ) as hours,
    r.notes
  from public.requests r
  where r.status = 'completed'
    and r.assignee_family_id is not null
    and not exists (
      select 1
      from public.ledger_entries le2
      where le2.request_id = r.id
    )
  order by r.date desc nulls last,
    r.id;
$$;

-- RPC: list families for from/to selectors
create or replace function public.rpc_list_families_for_entry()
returns table (
  id uuid,
  name text
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, coalesce(p.name, p.id::text) as name
  from public.families p
  order by p.name nulls last, p.id;
$$;

-- RPC: list full family card details for families page
create or replace function public.rpc_list_families_full()
returns table (
  family_id uuid,
  family_name text,
  address text,
  parents jsonb,
  emergency_contacts jsonb,
  children jsonb,
  pets text,
  family_photo_url text,
  business_information text
)
language sql
stable
security definer
set search_path = public
as $$
  with parent_rows as (
    select
      fp.family_id,
      fp.name,
      fp.phone,
      u.email
    from public.family_parents fp
    left join auth.users u on u.id = fp.user_id
  ),
  parent_json as (
    select
      pr.family_id,
      jsonb_agg(
        jsonb_build_object(
          'name', pr.name,
          'email', pr.email,
          'phone', pr.phone
        )
        order by lower(coalesce(pr.name, '')), lower(coalesce(pr.email, ''))
      ) as parents
    from parent_rows pr
    group by pr.family_id
  ),
  child_json as (
    select
      fc.family_id,
      jsonb_agg(
        jsonb_build_object(
          'id', fc.id,
          'name', fc.name,
          'date_of_birth', fc.date_of_birth,
          'allergies', fc.allergies,
          'notes', fc.notes
        )
        order by lower(coalesce(fc.name, '')), fc.id
      ) as children
    from public.family_children fc
    group by fc.family_id
  )
  select
    f.id as family_id,
    f.name as family_name,
    f.address,
    coalesce(pj.parents, '[]'::jsonb) as parents,
    coalesce(f.emergency_contacts, '[]'::jsonb) as emergency_contacts,
    coalesce(cj.children, '[]'::jsonb) as children,
    f.pets,
    f.family_photo_url,
    f.notes
  from public.families f
  left join parent_json pj on pj.family_id = f.id
  left join child_json cj on cj.family_id = f.id
  order by lower(coalesce(f.name, '')), f.id;
$$;

-- RPC: create manual ledger entry (admin unrestricted, non-admin to self only)
create or replace function public.rpc_create_manual_ledger_entry(
  p_from_family_id uuid,
  p_to_family_id uuid,
  p_hours numeric,
  p_request_id uuid default null,
  p_entry_date date default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_is_admin boolean;
  v_family_id uuid;
  v_to_family_id uuid;
  v_entry_date date;
begin
  v_family_id := public.rpc_get_family_id();

  v_is_admin := public.rpc_get_admin_status();

  if v_is_admin then
    v_to_family_id := p_to_family_id;
  else
    if p_to_family_id <> v_family_id then
      raise exception 'Non-admin entries must use yourself as recipient';
    end if;
    v_to_family_id := v_family_id;
  end if;

  v_entry_date := coalesce(p_entry_date, public.rpc_local_today());

  if p_hours is null or p_hours <= 0 then
    raise exception 'Hours must be greater than zero';
  end if;

  if p_from_family_id = v_to_family_id then
    raise exception 'From family and to family must be different';
  end if;

  insert into public.ledger_entries (from_family_id, to_family_id, hours, entry_date, request_id)
  values (p_from_family_id, v_to_family_id, p_hours, v_entry_date, p_request_id)
  returning id into v_id;

  return v_id;
end;
$$;

-- RPC: fetch a single ledger entry for edit screen
create or replace function public.rpc_get_ledger_entry(p_entry_id uuid)
returns table (
  id uuid,
  from_family_id uuid,
  to_family_id uuid,
  entry_date date,
  hours numeric,
  request_id uuid
)
language sql
stable
security definer
set search_path = public
as $$
  select le.id, le.from_family_id, le.to_family_id, le.entry_date, le.hours, le.request_id
  from public.ledger_entries le
  where le.id = p_entry_id;
$$;

-- RPC: update ledger entry (admin only)
create or replace function public.rpc_update_ledger_entry(
  p_entry_id uuid,
  p_from_family_id uuid,
  p_to_family_id uuid,
  p_hours numeric,
  p_entry_date date default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.rpc_get_admin_status() then
    raise exception 'Admin only';
  end if;

  if p_hours is null or p_hours <= 0 then
    raise exception 'Hours must be greater than zero';
  end if;

  if p_from_family_id = p_to_family_id then
    raise exception 'From family and to family must be different';
  end if;

  update public.ledger_entries
  set from_family_id = p_from_family_id,
      to_family_id = p_to_family_id,
      hours = p_hours,
      entry_date = coalesce(p_entry_date, public.ledger_entries.entry_date)
  where id = p_entry_id;

  if not found then
    raise exception 'Ledger entry not found';
  end if;
end;
$$;

-- RPC: internal helper to determine if a family can be hard-deleted
create or replace function public.rpc_admin_family_is_deletable(p_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    not exists (
      select 1
      from public.requests r
      where r.requester_family_id = p_family_id
         or r.assignee_family_id = p_family_id
    )
    and not exists (
      select 1
      from public.ledger_entries le
      where le.from_family_id = p_family_id
         or le.to_family_id = p_family_id
    );
$$;

-- RPC: list all families for admin management
create or replace function public.rpc_admin_list_families()
returns table (
  id uuid,
  name text,
  is_active boolean,
  is_admin boolean,
  admin_date_joined date,
  admin_last_background_check date,
  admin_last_dues_payment date,
  member_count integer,
  can_delete boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    f.id,
    f.name,
    coalesce(f.is_active, true) as is_active,
    coalesce(f.is_admin, false) as is_admin,
    f.admin_date_joined,
    f.admin_last_background_check,
    f.admin_last_dues_payment,
    (
      select count(*)::integer
      from public.family_parents fp
      where fp.family_id = f.id
    ) as member_count,
    public.rpc_admin_family_is_deletable(f.id) as can_delete
  from public.families f
  where public.rpc_get_admin_status()
  order by lower(coalesce(f.name, '')), f.id;
$$;

-- RPC: create a family by name for admin management
create or replace function public.rpc_admin_create_family(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.rpc_get_admin_status() then
    raise exception 'Admin only';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception 'Family name is required';
  end if;

  insert into public.families (name)
  values (btrim(p_name))
  returning id into v_id;

  return v_id;
end;
$$;

-- RPC: update family admin and active fields
create or replace function public.rpc_admin_update_family(
  p_family_id uuid,
  p_is_active boolean,
  p_is_admin boolean,
  p_admin_date_joined date default null,
  p_admin_last_background_check date default null,
  p_admin_last_dues_payment date default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.rpc_get_admin_status() then
    raise exception 'Admin only';
  end if;

  update public.families
  set is_active = coalesce(p_is_active, true),
      is_admin = coalesce(p_is_admin, false),
      admin_date_joined = p_admin_date_joined,
      admin_last_background_check = p_admin_last_background_check,
      admin_last_dues_payment = p_admin_last_dues_payment
  where id = p_family_id;

  if not found then
    raise exception 'Family not found';
  end if;
end;
$$;

-- RPC: hard-delete eligible family and all linked users (users deleted first)
create or replace function public.rpc_admin_delete_family(p_family_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.rpc_get_admin_status() then
    raise exception 'Admin only';
  end if;

  if not public.rpc_admin_family_is_deletable(p_family_id) then
    raise exception 'Family is not eligible for deletion';
  end if;

  delete from auth.users u
  using public.family_parents fp
  where fp.family_id = p_family_id
    and fp.user_id = u.id;

  delete from public.families f
  where f.id = p_family_id;

  if not found then
    raise exception 'Family not found';
  end if;
end;
$$;

-- RPC: list users and their linked family for admin management
create or replace function public.rpc_admin_list_users()
returns table (
  user_id uuid,
  email text,
  family_id uuid,
  family_name text,
  family_is_active boolean,
  created_at timestamptz,
  last_sign_in_at timestamptz,
  can_delete boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    u.id as user_id,
    u.email,
    fp.family_id,
    f.name as family_name,
    coalesce(f.is_active, true) as family_is_active,
    u.created_at,
    u.last_sign_in_at,
    public.rpc_admin_family_is_deletable(fp.family_id) as can_delete
  from auth.users u
  join public.family_parents fp on fp.user_id = u.id
  join public.families f on f.id = fp.family_id
  where public.rpc_get_admin_status()
  order by lower(coalesce(u.email, '')), u.id;
$$;

-- RPC: create a user and link to a family
create or replace function public.rpc_admin_create_user(
  p_email text,
  p_password text,
  p_family_id uuid,
  p_name text default null,
  p_phone text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  if not public.rpc_get_admin_status() then
    raise exception 'Admin only';
  end if;

  if p_email is null or btrim(p_email) = '' then
    raise exception 'Email is required';
  end if;

  if p_password is null or length(p_password) < 8 then
    raise exception 'Password must be at least 8 characters';
  end if;

  if p_family_id is null then
    raise exception 'Family is required';
  end if;

  if not exists (select 1 from public.families f where f.id = p_family_id) then
    raise exception 'Family not found';
  end if;

  if exists (select 1 from auth.users u where lower(u.email) = lower(btrim(p_email))) then
    raise exception 'A user with that email already exists';
  end if;

  insert into auth.users (
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    is_sso_user,
    is_anonymous
  )
  values (
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    lower(btrim(p_email)),
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now(),
    false,
    false
  )
  returning id into v_user_id;

  insert into public.family_parents (user_id, family_id, name, phone)
  values (v_user_id, p_family_id, nullif(btrim(p_name), ''), nullif(btrim(p_phone), ''));

  return v_user_id;
end;
$$;

-- RPC: move a user to a different family
create or replace function public.rpc_admin_update_user_family(
  p_user_id uuid,
  p_family_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.rpc_get_admin_status() then
    raise exception 'Admin only';
  end if;

  if p_user_id is null then
    raise exception 'User is required';
  end if;

  if p_family_id is null then
    raise exception 'Family is required';
  end if;

  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'User not found';
  end if;

  if not exists (select 1 from public.families f where f.id = p_family_id) then
    raise exception 'Family not found';
  end if;

  update public.family_parents fp
  set family_id = p_family_id
  where fp.user_id = p_user_id;

  if not found then
    raise exception 'User is not linked to a family';
  end if;
end;
$$;

-- RPC: delete a user only when linked family is eligible for deletion
create or replace function public.rpc_admin_delete_user(
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_family_id uuid;
begin
  if not public.rpc_get_admin_status() then
    raise exception 'Admin only';
  end if;

  if p_user_id is null then
    raise exception 'User is required';
  end if;

  select fp.family_id into v_family_id
  from public.family_parents fp
  where fp.user_id = p_user_id;

  if v_family_id is null then
    raise exception 'User is not linked to a family';
  end if;

  if not public.rpc_admin_family_is_deletable(v_family_id) then
    raise exception 'User can only be deleted when linked family is eligible for deletion';
  end if;

  delete from auth.users u
  where u.id = p_user_id;

  if not found then
    raise exception 'User not found';
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
grant execute on function public.rpc_list_requests_filtered(date, date) to authenticated, service_role;
grant execute on function public.rpc_get_request(uuid) to authenticated, service_role;
grant execute on function public.rpc_list_request_children(uuid) to authenticated, service_role;
grant execute on function public.rpc_list_offers(uuid) to authenticated, service_role;
grant execute on function public.rpc_get_family_id() to authenticated, service_role;
grant execute on function public.rpc_is_current_family_active() to authenticated, service_role;
grant execute on function public.rpc_add_family_member_by_email(text) to authenticated, service_role;
grant execute on function public.rpc_list_my_family_emails() to authenticated, service_role;
grant execute on function public.rpc_get_my_parent_profile() to authenticated, service_role;
grant execute on function public.rpc_upsert_my_parent_profile(text, text, boolean, boolean, boolean, boolean, boolean, boolean) to authenticated, service_role;
grant execute on function public.rpc_list_my_family_children() to authenticated, service_role;
grant execute on function public.rpc_replace_my_family_children(jsonb) to authenticated, service_role;
grant execute on function public.rpc_create_request(text, text, date, time, time, boolean, boolean, boolean, numeric, text, boolean, boolean, boolean, uuid[], text, text) to authenticated, service_role;
grant execute on function public.rpc_update_request(uuid, text, date, time, time, boolean, boolean, boolean, numeric, text, boolean, boolean, boolean, uuid[], text, text) to authenticated, service_role;
grant execute on function public.rpc_offer_request(uuid, text) to authenticated, service_role;
grant execute on function public.rpc_update_offer(uuid, text) to authenticated, service_role;
grant execute on function public.rpc_cancel_offer(uuid) to authenticated, service_role;
grant execute on function public.rpc_request_set_assignee(uuid, uuid) to authenticated, service_role;
grant execute on function public.rpc_request_clear_assignee(uuid) to authenticated, service_role;
grant execute on function public.rpc_cancel_request(uuid) to authenticated, service_role;
grant execute on function public.rpc_get_hours_balance() to authenticated, service_role;
grant execute on function public.rpc_list_requests_my_family_future() to authenticated, service_role;
grant execute on function public.rpc_list_requests_other_open() to authenticated, service_role;
grant execute on function public.rpc_list_offers_my_submitted() to authenticated, service_role;
grant execute on function public.rpc_has_completed_sit_this_month() to authenticated, service_role;
grant execute on function public.rpc_get_admin_status() to authenticated, service_role;
grant execute on function public.rpc_get_my_family_details() to authenticated, service_role;
grant execute on function public.rpc_upsert_my_family_details(text, text, jsonb, text, text, text, date, date, date, text) to authenticated, service_role;
grant execute on function public.rpc_list_ledger_entries_filtered(date, date) to authenticated, service_role;
grant execute on function public.rpc_list_ledger_balances() to authenticated, service_role;
grant execute on function public.rpc_list_requests_completed_for_entry() to authenticated, service_role;
grant execute on function public.rpc_list_families_for_entry() to authenticated, service_role;
grant execute on function public.rpc_list_families_full() to authenticated, service_role;
grant execute on function public.rpc_create_manual_ledger_entry(uuid, uuid, numeric, uuid, date) to authenticated, service_role;
grant execute on function public.rpc_get_ledger_entry(uuid) to authenticated, service_role;
grant execute on function public.rpc_update_ledger_entry(uuid, uuid, uuid, numeric, date) to authenticated, service_role;
grant execute on function public.rpc_admin_list_families() to authenticated, service_role;
grant execute on function public.rpc_admin_create_family(text) to authenticated, service_role;
grant execute on function public.rpc_admin_update_family(uuid, boolean, boolean, date, date, date) to authenticated, service_role;
grant execute on function public.rpc_admin_delete_family(uuid) to authenticated, service_role;
grant execute on function public.rpc_admin_list_users() to authenticated, service_role;
grant execute on function public.rpc_admin_create_user(text, text, uuid, text, text) to authenticated, service_role;
grant execute on function public.rpc_admin_update_user_family(uuid, uuid) to authenticated, service_role;
grant execute on function public.rpc_admin_delete_user(uuid) to authenticated, service_role;
