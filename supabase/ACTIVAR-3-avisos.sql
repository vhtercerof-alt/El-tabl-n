-- =====================================================================
-- EL TABLÓN · ACTIVAR PARTE 3 de 3 · Avisos al celular
-- =====================================================================
-- Cómo ejecutarlo en Supabase:
--   1. SQL Editor → New query (una pestaña VACÍA).
--   2. Pega TODO este archivo. No selecciones nada (si hay texto
--      seleccionado, Supabase ejecuta solo lo seleccionado).
--   3. Clic en Run. Debe decir "Success".
-- Se puede ejecutar varias veces sin romper nada.
-- Requiere haber ejecutado la parte 1.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 4. AVISOS (notificaciones push)
-- ---------------------------------------------------------------------
create table if not exists public.tb_push_suscripciones (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  endpoint   text not null unique
             check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  p256dh     text not null check (char_length(p256dh) <= 200),
  auth       text not null check (char_length(auth) <= 100),
  created_at timestamptz not null default now()
);
alter table public.tb_push_suscripciones enable row level security;
revoke all on public.tb_push_suscripciones from anon;

drop policy if exists tb_push_propias on public.tb_push_suscripciones;
create policy tb_push_propias on public.tb_push_suscripciones
  for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.tb_push_suscripciones from authenticated;

-- Guardar/quitar la suscripción de este dispositivo para el usuario actual.
create or replace function public.tb_guardar_suscripcion(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  if auth.uid() is null then raise exception 'Inicia sesión.'; end if;
  insert into public.tb_push_suscripciones (user_id, endpoint, p256dh, auth)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh,
        auth = excluded.auth, created_at = now();
end $fn$;

create or replace function public.tb_borrar_suscripcion(p_endpoint text)
returns void language sql security definer set search_path = public as $fn$
  delete from public.tb_push_suscripciones
  where endpoint = p_endpoint and user_id = auth.uid();
$fn$;

revoke all on function public.tb_guardar_suscripcion(text, text, text) from public, anon;
revoke all on function public.tb_borrar_suscripcion(text) from public, anon;
grant execute on function public.tb_guardar_suscripcion(text, text, text) to authenticated;
grant execute on function public.tb_borrar_suscripcion(text) to authenticated;

-- Registro interno para no enviar el mismo aviso dos veces
-- (solo lo usa el servidor de Vercel con la clave service_role).
create table if not exists public.tb_push_log (
  clave      text primary key,
  created_at timestamptz not null default now()
);
alter table public.tb_push_log enable row level security;
revoke all on public.tb_push_log from anon, authenticated;


select 'Avisos activados' as resultado;
