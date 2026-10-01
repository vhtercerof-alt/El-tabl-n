-- =====================================================================
-- EL TABLÓN · Profesor de lengua: envíos al profesor
-- Ejecutar UNA vez en Supabase → SQL Editor → Run.
--
-- Reglas:
--   · Cada estudiante crea y ve SOLO sus propios envíos, y puede borrarlos.
--   · Owner y admins ven todos los envíos, pueden comentarlos y borrarlos.
--   · Al crear un envío nadie puede ponerse un comentario a sí mismo.
--   · Al comentar, el staff solo cambia el comentario (el texto, el
--     puntaje y la revisión enviada no se pueden modificar).
-- =====================================================================

create or replace function public.tb_es_staff()
returns boolean language sql stable security definer set search_path = public as $fn_staff$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('owner', 'admin'));
$fn_staff$;
revoke all on function public.tb_es_staff() from public, anon;
grant execute on function public.tb_es_staff() to authenticated;

create table if not exists public.tb_lengua_revisiones (
  id              uuid        primary key default gen_random_uuid(),
  profile_id      uuid        not null references public.profiles(id) on delete cascade,
  texto_original  text        not null check (char_length(texto_original) between 1 and 7000),
  texto_final     text        not null check (char_length(texto_final) between 1 and 9000),
  tipo            text        check (char_length(tipo) <= 30),
  nivel           text        check (char_length(nivel) <= 30),
  puntaje         integer     not null check (puntaje between 0 and 100),
  resultado       jsonb       not null check (pg_column_size(resultado) <= 300000),
  comentario      text        check (char_length(comentario) <= 2000),
  revisado_at     timestamptz,
  revisado_por    uuid        references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now()
);
create index if not exists tb_lengua_revisiones_perfil on public.tb_lengua_revisiones (profile_id, created_at desc);
create index if not exists tb_lengua_revisiones_fecha on public.tb_lengua_revisiones (created_at desc);

alter table public.tb_lengua_revisiones enable row level security;
revoke all on public.tb_lengua_revisiones from anon, authenticated;
grant select, insert, update, delete on public.tb_lengua_revisiones to authenticated;

drop policy if exists lengua_rev_leer on public.tb_lengua_revisiones;
create policy lengua_rev_leer on public.tb_lengua_revisiones
  for select to authenticated
  using (profile_id = auth.uid() or public.tb_es_staff());

drop policy if exists lengua_rev_crear on public.tb_lengua_revisiones;
create policy lengua_rev_crear on public.tb_lengua_revisiones
  for insert to authenticated
  with check (profile_id = auth.uid());

drop policy if exists lengua_rev_comentar on public.tb_lengua_revisiones;
create policy lengua_rev_comentar on public.tb_lengua_revisiones
  for update to authenticated
  using (public.tb_es_staff())
  with check (public.tb_es_staff());

drop policy if exists lengua_rev_borrar on public.tb_lengua_revisiones;
create policy lengua_rev_borrar on public.tb_lengua_revisiones
  for delete to authenticated
  using (profile_id = auth.uid() or public.tb_es_staff());

-- Protege los campos: al crear, sin comentario; al comentar, solo el comentario.
create or replace function public.tb_lengua_revisiones_proteger()
returns trigger language plpgsql security definer set search_path = public as $fn_proteger$
begin
  if tg_op = 'INSERT' then
    new.comentario   := null;
    new.revisado_at  := null;
    new.revisado_por := null;
    new.created_at   := now();
  else
    new.id             := old.id;
    new.profile_id     := old.profile_id;
    new.texto_original := old.texto_original;
    new.texto_final    := old.texto_final;
    new.tipo           := old.tipo;
    new.nivel          := old.nivel;
    new.puntaje        := old.puntaje;
    new.resultado      := old.resultado;
    new.created_at     := old.created_at;
    new.revisado_at    := now();
    new.revisado_por   := auth.uid();
  end if;
  return new;
end;
$fn_proteger$;

drop trigger if exists tb_lengua_revisiones_proteger on public.tb_lengua_revisiones;
create trigger tb_lengua_revisiones_proteger
  before insert or update on public.tb_lengua_revisiones
  for each row execute function public.tb_lengua_revisiones_proteger();

select 'Envíos del Profesor de lengua activados' as resultado;
