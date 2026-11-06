-- SAVEETHA PULSE / EVENTHUB schema
-- Run in Supabase SQL Editor. Review policies and institutional requirements before production.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null,
 college_email text not null unique,
 register_number text not null unique,
 department text not null,
 academic_year smallint not null check (academic_year between 1 and 4),
 section text not null,
 phone_number text,
 role text not null default 'student' check (role in ('student','admin')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.events (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 description text,
 category text not null,
 poster_url text,
 event_date date not null,
 start_time time,
 end_time time,
 venue text not null,
 registration_deadline timestamptz,
 max_participants integer check(max_participants is null or max_participants > 0),
 eligibility text,
 status text not null default 'draft' check(status in ('draft','published','cancelled','completed')),
 source_url text,
 source_verified boolean not null default false,
 created_by uuid references public.profiles(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.registrations (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 event_id uuid not null references public.events(id) on delete cascade,
 registration_number text not null,
 status text not null default 'confirmed' check(status in ('pending','confirmed','waitlisted','cancelled','rejected')),
 registered_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(user_id,event_id)
);
create table if not exists public.event_passes (
 id uuid primary key default gen_random_uuid(),
 registration_id uuid not null unique references public.registrations(id) on delete cascade,
 pass_code text not null unique,
 token_hash text not null unique,
 status text not null default 'active' check(status in ('active','revoked','expired')),
 generated_at timestamptz not null default now(),
 expires_at timestamptz
);
create table if not exists public.attendance (
 id uuid primary key default gen_random_uuid(),
 registration_id uuid not null references public.registrations(id) on delete cascade,
 event_id uuid not null references public.events(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 checked_in_by uuid not null references public.profiles(id),
 check_in_time timestamptz not null default now(),
 status text not null default 'present' check(status in ('present','rejected')),
 constraint one_successful_checkin_per_registration unique(registration_id)
);
create table if not exists public.notifications (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 title text not null,
 message text not null,
 type text not null default 'info',
 is_read boolean not null default false,
 created_at timestamptz not null default now()
);
create table if not exists public.admin_users (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null unique references public.profiles(id) on delete cascade,
 permissions jsonb not null default '{"events":true,"students":true,"registrations":true,"attendance":true}'::jsonb,
 created_at timestamptz not null default now()
);
create table if not exists public.event_sources (
 id uuid primary key default gen_random_uuid(),
 source_name text not null,
 source_url text not null unique,
 last_checked_at timestamptz,
 verification_status text not null default 'unverified',
 created_at timestamptz not null default now()
);
create table if not exists public.audit_logs (
 id uuid primary key default gen_random_uuid(),
 admin_id uuid references public.profiles(id),
 action text not null,
 entity_type text not null,
 entity_id uuid,
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists events_status_date_idx on public.events(status,event_date);
create index if not exists registrations_user_idx on public.registrations(user_id,registered_at desc);
create index if not exists registrations_event_idx on public.registrations(event_id,status);
create index if not exists notifications_user_idx on public.notifications(user_id,created_at desc);
create index if not exists attendance_event_idx on public.attendance(event_id,check_in_time desc);

create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at=now(); return new; end $$;
drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
drop trigger if exists events_updated_at on public.events;
create trigger events_updated_at before update on public.events for each row execute function public.set_updated_at();
drop trigger if exists registrations_updated_at on public.registrations;
create trigger registrations_updated_at before update on public.registrations for each row execute function public.set_updated_at();

-- Profile is created from Auth metadata. Role is always forced to student.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,full_name,college_email,register_number,department,academic_year,section,phone_number,role)
 values(new.id,
 coalesce(new.raw_user_meta_data->>'full_name','Student'),
 lower(new.email),
 coalesce(new.raw_user_meta_data->>'register_number','PENDING-'||substr(new.id::text,1,8)),
 coalesce(new.raw_user_meta_data->>'department','Not provided'),
 coalesce(nullif(new.raw_user_meta_data->>'academic_year','')::smallint,1),
 coalesce(new.raw_user_meta_data->>'section','NA'),
 new.raw_user_meta_data->>'phone_number','student')
 on conflict(id) do nothing;
 return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.admin_users au where au.user_id=auth.uid())
$$;

-- Atomic registration and pass issuance; capacity check is serialized per event.
create or replace function public.register_for_event(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ev public.events%rowtype; prof public.profiles%rowtype; reg public.registrations%rowtype;
 raw_token text; code text; confirmed_count integer;
begin
 if auth.uid() is null then raise exception 'Please sign in to register'; end if;
 select * into prof from public.profiles where id=auth.uid();
 if not found then raise exception 'Student profile not found'; end if;
 select * into ev from public.events where id=p_event_id and status='published' for update;
 if not found then raise exception 'Event is not open for registration'; end if;
 if ev.registration_deadline is not null and now()>ev.registration_deadline then raise exception 'Registration deadline has passed'; end if;
 if ev.eligibility is not null and length(trim(ev.eligibility))>0 and lower(ev.eligibility) not in ('all','all students') then
   if position(lower(prof.department) in lower(ev.eligibility))=0 then raise exception 'You are not eligible for this event'; end if;
 end if;
 if exists(select 1 from public.registrations where user_id=auth.uid() and event_id=p_event_id) then raise exception 'You are already registered for this event'; end if;
 select count(*) into confirmed_count from public.registrations where event_id=p_event_id and status='confirmed';
 insert into public.registrations(user_id,event_id,registration_number,status)
 values(auth.uid(),p_event_id,prof.register_number,case when ev.max_participants is not null and confirmed_count>=ev.max_participants then 'waitlisted' else 'confirmed' end)
 returning * into reg;
 if reg.status='confirmed' then
   raw_token:=encode(gen_random_bytes(32),'hex');
   code:='SPX-'||upper(substr(encode(gen_random_bytes(6),'hex'),1,4))||'-'||upper(substr(encode(gen_random_bytes(6),'hex'),1,4));
   insert into public.event_passes(registration_id,pass_code,token_hash)
   values(reg.id,code,encode(digest(raw_token,'sha256'),'hex'));
   insert into public.notifications(user_id,title,message,type)
   values(auth.uid(),'Registration confirmed','Your registration for '||ev.title||' is confirmed. Your digital pass is available in your dashboard.','registration');
   return jsonb_build_object('registration_id',reg.id,'status',reg.status,'pass_token',raw_token);
 end if;
 insert into public.notifications(user_id,title,message,type)
 values(auth.uid(),'Added to waiting list','You have been waitlisted for '||ev.title||'.','registration');
 return jsonb_build_object('registration_id',reg.id,'status',reg.status);
end $$;

-- Pass token is returned only to its owner; raw token is stored client-side only if user saves it.
create or replace function public.get_my_event_pass(p_registration_id uuid)
returns table(pass_code text,status text,event_title text,event_date date,venue text,verification_token text)
language plpgsql security definer set search_path=public as $$
declare raw_token text; new_code text;
begin
 if auth.uid() is null then raise exception 'Please sign in'; end if;
 if not exists(select 1 from public.registrations r where r.id=p_registration_id and r.user_id=auth.uid() and r.status='confirmed') then
   raise exception 'Confirmed registration not found';
 end if;
 raw_token:=encode(gen_random_bytes(32),'hex');
 new_code:='SPX-'||upper(substr(encode(gen_random_bytes(6),'hex'),1,4))||'-'||upper(substr(encode(gen_random_bytes(6),'hex'),1,4));
 update public.event_passes ep set token_hash=encode(digest(raw_token,'sha256'),'hex'),pass_code=new_code,status='active',generated_at=now()
 where ep.registration_id=p_registration_id;
 if not found then
   insert into public.event_passes(registration_id,pass_code,token_hash)
   values(p_registration_id,new_code,encode(digest(raw_token,'sha256'),'hex'));
 end if;
 return query
 select ep.pass_code,ep.status,e.title,e.event_date,e.venue,raw_token
 from public.event_passes ep join public.registrations r on r.id=ep.registration_id join public.events e on e.id=r.event_id
 where r.id=p_registration_id and r.user_id=auth.uid() and ep.status='active';
end $$;

-- Staff-only check-in. Scanner submits the opaque token; hash is matched in the DB.
create or replace function public.verify_and_checkin(p_token text,p_event_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ep public.event_passes%rowtype; r public.registrations%rowtype; prof public.profiles%rowtype;
begin
 if not public.is_admin() then raise exception 'Administrator permission required'; end if;
 select * into ep from public.event_passes where token_hash=encode(digest(p_token,'sha256'),'hex') and status='active' for update;
 if not found then return jsonb_build_object('ok',false,'reason','Invalid or revoked pass'); end if;
 select * into r from public.registrations where id=ep.registration_id;
 if r.event_id<>p_event_id then return jsonb_build_object('ok',false,'reason','Pass belongs to another event'); end if;
 if r.status<>'confirmed' then return jsonb_build_object('ok',false,'reason','Registration is not confirmed'); end if;
 if ep.expires_at is not null and now()>ep.expires_at then return jsonb_build_object('ok',false,'reason','Pass expired'); end if;
 if exists(select 1 from public.attendance where registration_id=r.id) then return jsonb_build_object('ok',false,'reason','Duplicate check-in'); end if;
 insert into public.attendance(registration_id,event_id,user_id,checked_in_by)
 values(r.id,r.event_id,r.user_id,auth.uid());
 insert into public.audit_logs(admin_id,action,entity_type,entity_id,details)
 values(auth.uid(),'attendance_checked_in','registration',r.id,jsonb_build_object('event_id',r.event_id));
 return jsonb_build_object('ok',true,'reason','Entry approved');
end $$;

alter table public.profiles enable row level security;
alter table public.events enable row level security;
alter table public.registrations enable row level security;
alter table public.event_passes enable row level security;
alter table public.attendance enable row level security;
alter table public.notifications enable row level security;
alter table public.admin_users enable row level security;
alter table public.event_sources enable row level security;
alter table public.audit_logs enable row level security;

create policy "profile read self or admin" on public.profiles for select using(id=auth.uid() or public.is_admin());
create policy "profile update self or admin" on public.profiles for update using(id=auth.uid() or public.is_admin()) with check((id=auth.uid() and role='student') or public.is_admin());
create policy "published events visible" on public.events for select using(status='published' or public.is_admin());
create policy "admins manage events" on public.events for all using(public.is_admin()) with check(public.is_admin());
create policy "registrations own or admin read" on public.registrations for select using(user_id=auth.uid() or public.is_admin());
create policy "admins manage registrations" on public.registrations for all using(public.is_admin()) with check(public.is_admin());
create policy "passes own or admin read" on public.event_passes for select using(exists(select 1 from public.registrations r where r.id=registration_id and (r.user_id=auth.uid() or public.is_admin())));
create policy "attendance admin read" on public.attendance for select using(public.is_admin());
create policy "notifications own read/update" on public.notifications for select using(user_id=auth.uid() or public.is_admin());
create policy "notifications own update" on public.notifications for update using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy "admin users self/admin read" on public.admin_users for select using(user_id=auth.uid() or public.is_admin());
create policy "event sources admin only" on public.event_sources for all using(public.is_admin()) with check(public.is_admin());
create policy "audit logs admin read" on public.audit_logs for select using(public.is_admin());

grant execute on function public.register_for_event(uuid) to authenticated;
grant execute on function public.get_my_event_pass(uuid) to authenticated;
grant execute on function public.verify_and_checkin(text,uuid) to authenticated;

-- Bootstrap first admin only after the account has been created and email verified:
-- insert into public.admin_users(user_id) values ('AUTH_USER_UUID_HERE');
-- Do NOT expose service-role keys or grant admin from a client-side signup form.
