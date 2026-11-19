-- KELLERFRISEUR v2 – Supabase SQL
-- Im Supabase SQL Editor als Ganzes ausführen.
create extension if not exists btree_gist;
create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'admin' check (role in ('owner','admin')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.settings (
  id boolean primary key default true check(id),
  duration_minutes integer not null default 60 check(duration_minutes between 5 and 480),
  booking_days integer not null default 30 check(booking_days between 1 and 365),
  slot_interval integer not null default 15 check(slot_interval in (5,10,15,20,30,60)),
  timezone text not null default 'Europe/Berlin'
);
insert into public.settings(id) values(true) on conflict(id) do nothing;
create table if not exists public.appointments (
  id bigint generated always as identity primary key,
  customer_name text not null,
  email text,
  phone text,
  notes text,
  internal_note text,
  requested_date date not null,
  requested_time time not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  status text not null default 'pending' check(status in ('pending','confirmed','rejected','cancelled','withdrawn','manual')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check(end_at>start_at)
);
-- Aktive Termine (Anfragen, bestätigte und manuelle Termine) dürfen sich nie überschneiden.
-- Status cancelled/rejected/withdrawn belegen keine Zeit.
alter table public.appointments drop constraint if exists appointments_no_overlap;
alter table public.appointments add constraint appointments_no_overlap
  exclude using gist (tstzrange(start_at,end_at,'[)') with &&)
  where (status in ('pending','confirmed','manual'));
create table if not exists public.availability_blocks (
  id bigint generated always as identity primary key,
  start_at timestamptz not null,
  end_at timestamptz not null,
  reason text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check(end_at>start_at)
);
create table if not exists public.mail_log (
  id bigint generated always as identity primary key,
  appointment_id bigint references public.appointments(id) on delete set null,
  recipient text not null,
  subject text not null,
  sent boolean not null default false,
  error text,
  created_at timestamptz not null default now()
);

-- Browser darf keinerlei Tabellen direkt lesen oder schreiben. Nur Netlify mit Service-Role greift zu.
alter table public.admin_users enable row level security;
alter table public.settings enable row level security;
alter table public.appointments enable row level security;
alter table public.availability_blocks enable row level security;
alter table public.mail_log enable row level security;
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

create or replace function public.public_day_availability(p_date date)
returns table("time" text, available boolean)
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg public.settings%rowtype; t time; s timestamptz; e timestamptz; day_start timestamptz; day_end timestamptz; local_now timestamp;
begin
 select * into cfg from public.settings where id=true;
 if p_date < (now() at time zone 'Europe/Berlin')::date or p_date > (now() at time zone 'Europe/Berlin')::date + cfg.booking_days then return; end if;
 day_start := (p_date::timestamp at time zone 'Europe/Berlin'); day_end := ((p_date+1)::timestamp at time zone 'Europe/Berlin');
 t := time '00:00';
 while t < time '24:00' loop
   s := (p_date::timestamp + t) at time zone 'Europe/Berlin'; e := s + make_interval(mins=>cfg.duration_minutes);
   if e <= day_end and extract(minute from t)::int % cfg.slot_interval=0 then
     return query select to_char(t,'HH24:MI'),
       not exists(select 1 from appointments a where a.status in ('pending','confirmed','manual') and tstzrange(a.start_at,a.end_at,'[)') && tstzrange(s,e,'[)'))
       and not exists(select 1 from availability_blocks b where tstzrange(b.start_at,b.end_at,'[)') && tstzrange(s,e,'[)'))
       and s > now();
   end if;
   t := t + interval '15 minutes';
 end loop;
end $$;
revoke all on function public.public_day_availability(date) from public;
grant execute on function public.public_day_availability(date) to anon, authenticated;

create or replace function public.create_public_booking(p_name text,p_email text,p_phone text,p_notes text,p_date date,p_time time)
returns bigint language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg public.settings%rowtype; s timestamptz; e timestamptz; new_id bigint;
begin
 select * into cfg from settings where id=true;
 if p_date < (now() at time zone 'Europe/Berlin')::date or p_date > (now() at time zone 'Europe/Berlin')::date + cfg.booking_days then raise exception 'slot_unavailable'; end if;
 if extract(minute from p_time)::int % cfg.slot_interval <> 0 or p_time < time '00:00' then raise exception 'slot_unavailable'; end if;
 s := (p_date::timestamp+p_time) at time zone 'Europe/Berlin'; e := s+make_interval(mins=>cfg.duration_minutes);
 if s<=now() or (s at time zone 'Europe/Berlin')::date <> p_date then raise exception 'slot_unavailable'; end if;
 if exists(select 1 from availability_blocks b where tstzrange(b.start_at,b.end_at,'[)') && tstzrange(s,e,'[)')) then raise exception 'slot_unavailable'; end if;
 insert into appointments(customer_name,email,phone,notes,requested_date,requested_time,start_at,end_at,status)
 values(left(trim(p_name),100),lower(trim(p_email)),nullif(left(trim(coalesce(p_phone,'')),40),''),nullif(left(trim(coalesce(p_notes,'')),1000),''),p_date,p_time,s,e,'pending') returning id into new_id;
 return new_id;
exception when exclusion_violation then raise exception 'slot_unavailable';
end $$;
revoke all on function public.create_public_booking(text,text,text,text,date,time) from public;
grant execute on function public.create_public_booking(text,text,text,text,date,time) to anon,authenticated;

create or replace function public.admin_set_appointment_status(p_id bigint,p_status text)
returns table(id bigint,customer_name text,email text,requested_date date,requested_time time)
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if p_status not in ('confirmed','rejected') then raise exception 'invalid status'; end if;
 return query update appointments a set status=p_status where a.id=p_id and a.status='pending'
 returning a.id,a.customer_name,a.email,a.requested_date,a.requested_time;
end $$;
revoke all on function public.admin_set_appointment_status(bigint,text) from public;

create or replace function public.admin_create_appointment(p_name text,p_email text,p_phone text,p_date date,p_time time,p_notes text,p_user_id uuid)
returns bigint language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg settings%rowtype;s timestamptz;e timestamptz;new_id bigint;
begin select * into cfg from settings where id=true;s:=(p_date::timestamp+p_time) at time zone 'Europe/Berlin';e:=s+make_interval(mins=>cfg.duration_minutes);
 insert into appointments(customer_name,email,phone,internal_note,requested_date,requested_time,start_at,end_at,status,created_by)
 values(left(trim(p_name),100),nullif(trim(p_email),''),nullif(trim(p_phone),''),nullif(trim(p_notes),''),p_date,p_time,s,e,'manual',p_user_id) returning id into new_id;return new_id;
end $$;
revoke all on function public.admin_create_appointment(text,text,text,date,time,text,uuid) from public;
