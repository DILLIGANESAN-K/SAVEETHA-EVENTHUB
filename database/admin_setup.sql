-- EVENTHUB admin and event-poster Storage setup
-- Run AFTER the main database/schema.sql has completed successfully.
-- First create/verify the admin Auth user with ax7editzzz@gmail.com and confirm its email.

-- Public bucket: anyone can view event posters; only verified admins can upload/change/delete.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('event-posters', 'event-posters', true, 5242880, array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "event posters public read" on storage.objects;
create policy "event posters public read"
on storage.objects for select
using (bucket_id = 'event-posters');

drop policy if exists "event posters admin upload" on storage.objects;
create policy "event posters admin upload"
on storage.objects for insert to authenticated
with check (bucket_id = 'event-posters' and public.is_admin());

drop policy if exists "event posters admin update" on storage.objects;
create policy "event posters admin update"
on storage.objects for update to authenticated
using (bucket_id = 'event-posters' and public.is_admin())
with check (bucket_id = 'event-posters' and public.is_admin());

drop policy if exists "event posters admin delete" on storage.objects;
create policy "event posters admin delete"
on storage.objects for delete to authenticated
using (bucket_id = 'event-posters' and public.is_admin());

-- Grant admin to the Auth account linked to this email.
-- This does not create the Auth account; create it first using the website signup form.
insert into public.admin_users (user_id)
select id from auth.users where lower(email) = lower('ax7editzzz@gmail.com')
on conflict (user_id) do nothing;

update public.profiles
set role = 'admin'
where id = (
  select id from auth.users where lower(email) = lower('ax7editzzz@gmail.com') limit 1
);

-- Verify the admin assignment. Expected: one row, role = admin, is_admin = true.
select u.id, u.email, p.role,
       exists(select 1 from public.admin_users a where a.user_id = u.id) as is_admin
from auth.users u
left join public.profiles p on p.id = u.id
where lower(u.email) = lower('ax7editzzz@gmail.com');
