-- =====================================================================
-- EL TABLÓN · ACTIVAR PARTE 2 de 3 · Códigos de invitación
-- =====================================================================
-- Cómo ejecutarlo en Supabase:
--   1. SQL Editor → New query (una pestaña VACÍA).
--   2. Pega TODO este archivo. No selecciones nada (si hay texto
--      seleccionado, Supabase ejecuta solo lo seleccionado).
--   3. Clic en Run. Debe decir "Success".
-- Se puede ejecutar varias veces sin romper nada.
-- Requiere haber ejecutado la parte 1.
-- Al final muestra tu código de invitación inicial.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3. CÓDIGOS DE INVITACIÓN
-- ---------------------------------------------------------------------
create table if not exists public.tb_invitaciones (
  codigo      text primary key check (codigo ~ '^[A-Z0-9]{6,20}\Z'),
  nota        text check (char_length(nota) <= 80),
  max_usos    integer check (max_usos > 0),
  usos        integer not null default 0,
  expira      timestamptz,
  activo      boolean not null default true,
  creado_por  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.tb_ajustes (
  id                     integer primary key default 1 check (id = 1),
  invitacion_obligatoria boolean not null default true
);
insert into public.tb_ajustes (id) values (1) on conflict (id) do nothing;

alter table public.tb_invitaciones enable row level security;
alter table public.tb_ajustes enable row level security;
revoke all on public.tb_invitaciones from anon;
revoke all on public.tb_ajustes from anon;

drop policy if exists tb_invitaciones_owner on public.tb_invitaciones;
create policy tb_invitaciones_owner on public.tb_invitaciones
  for all to authenticated
  using (public.tb_es_owner()) with check (public.tb_es_owner());

drop policy if exists tb_ajustes_owner on public.tb_ajustes;
create policy tb_ajustes_owner on public.tb_ajustes
  for all to authenticated
  using (public.tb_es_owner()) with check (public.tb_es_owner());

-- La página pregunta si hace falta código (sin revelar ningún código).
create or replace function public.tb_invitacion_requerida()
returns boolean language sql stable security definer set search_path = public as $fn$
  select coalesce((select invitacion_obligatoria from public.tb_ajustes where id = 1), true);
$fn$;
grant execute on function public.tb_invitacion_requerida() to anon, authenticated;

-- Se ejecuta en el servidor al crear cada cuenta: sin código válido,
-- la cuenta NO se crea (no se puede saltar desde el navegador).
create or replace function public.tb_validar_invitacion()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  v_codigo text := upper(btrim(coalesce(new.raw_user_meta_data ->> 'codigo_invitacion', '')));
begin
  new.raw_user_meta_data := coalesce(new.raw_user_meta_data, '{}'::jsonb) - 'codigo_invitacion';
  if not public.tb_invitacion_requerida() then
    return new;
  end if;
  update public.tb_invitaciones
     set usos = usos + 1
   where codigo = v_codigo
     and activo
     and (expira is null or expira > now())
     and (max_usos is null or usos < max_usos);
  if not found then
    raise exception 'TB_INVITACION_INVALIDA';
  end if;
  return new;
end $fn$;

drop trigger if exists tb_validar_invitacion on auth.users;
create trigger tb_validar_invitacion
  before insert on auth.users
  for each row execute function public.tb_validar_invitacion();

-- Código inicial (solo si todavía no hay ninguno).
insert into public.tb_invitaciones (codigo, nota)
select c.codigo, 'Código inicial'
from (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                               (get_byte(x.b, g) % 32) + 1, 1), '') as codigo
      from (select decode(md5(gen_random_uuid()::text), 'hex') as b) x,
           generate_series(0, 7) g) c
where not exists (select 1 from public.tb_invitaciones);


-- ---------------------------------------------------------------------
-- Resultado: tu código de invitación inicial
-- ---------------------------------------------------------------------
select codigo as "Código de invitación inicial", usos, activo
from public.tb_invitaciones order by created_at limit 5;
