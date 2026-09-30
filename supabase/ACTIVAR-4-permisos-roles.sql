-- =====================================================================
-- EL TABLÓN · Permisos por rol (por ahora: "voleibol")
-- Ejecutar UNA vez en Supabase → SQL Editor → Run.
--
-- Qué hace:
--   · Crea tb_permisos_rol: qué roles tienen qué permiso.
--   · Todos pueden LEER los permisos (la página decide qué mostrar),
--     pero SOLO el owner puede darlos o quitarlos, y solo mediante la
--     función tb_permiso_rol (nadie puede escribir la tabla directamente).
--   · Si se borra un rol, se borran sus permisos.
-- El servidor de Vercel vuelve a comprobar el permiso antes de usar la IA.
-- =====================================================================

create table if not exists public.tb_permisos_rol (
  role_id    text        not null,
  permiso    text        not null check (permiso in ('voleibol')),
  created_at timestamptz not null default now(),
  primary key (role_id, permiso)
);

alter table public.tb_permisos_rol enable row level security;
revoke all on public.tb_permisos_rol from anon, authenticated;
grant select on public.tb_permisos_rol to authenticated;

drop policy if exists tb_permisos_rol_leer on public.tb_permisos_rol;
create policy tb_permisos_rol_leer on public.tb_permisos_rol
  for select to authenticated using (true);

-- Dar (p_activo = true) o quitar (false) un permiso a un rol. Solo el owner.
create or replace function public.tb_permiso_rol(p_role text, p_permiso text, p_activo boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn_permiso$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'owner') then
    raise exception 'Solo el owner puede cambiar permisos.';
  end if;
  if p_permiso is null or p_permiso not in ('voleibol') then
    raise exception 'Permiso no válido.';
  end if;
  if not exists (select 1 from public.roles where id::text = p_role) then
    raise exception 'El rol no existe.';
  end if;
  if p_activo then
    insert into public.tb_permisos_rol (role_id, permiso)
    values (p_role, p_permiso)
    on conflict do nothing;
  else
    delete from public.tb_permisos_rol where role_id = p_role and permiso = p_permiso;
  end if;
  return p_activo;
end;
$fn_permiso$;

revoke all on function public.tb_permiso_rol(text, text, boolean) from public, anon;
grant execute on function public.tb_permiso_rol(text, text, boolean) to authenticated;

-- Limpieza automática al borrar un rol.
create or replace function public.tb_permisos_rol_limpiar()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn_limpiar$
begin
  delete from public.tb_permisos_rol where role_id = old.id::text;
  return old;
end;
$fn_limpiar$;

drop trigger if exists tb_permisos_rol_limpiar on public.roles;
create trigger tb_permisos_rol_limpiar
  after delete on public.roles
  for each row execute function public.tb_permisos_rol_limpiar();

select 'Permisos por rol activados' as resultado;
