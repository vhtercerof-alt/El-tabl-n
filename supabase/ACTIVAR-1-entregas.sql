-- =====================================================================
-- EL TABLÓN · ACTIVAR PARTE 1 de 3 · Entregas de tareas
-- =====================================================================
-- Cómo ejecutarlo en Supabase:
--   1. SQL Editor → New query (una pestaña VACÍA).
--   2. Pega TODO este archivo. No selecciones nada (si hay texto
--      seleccionado, Supabase ejecuta solo lo seleccionado).
--   3. Clic en Run. Debe decir "Success".
-- Se puede ejecutar varias veces sin romper nada.
-- Ejecuta las partes en orden: 1, 2 y 3.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Funciones de apoyo
-- ---------------------------------------------------------------------
create or replace function public.tb_es_staff()
returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('owner', 'admin'));
$fn$;

create or replace function public.tb_es_owner()
returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'owner');
$fn$;

revoke all on function public.tb_es_staff() from public, anon;
revoke all on function public.tb_es_owner() from public, anon;
grant execute on function public.tb_es_staff() to authenticated;
grant execute on function public.tb_es_owner() to authenticated;


-- ---------------------------------------------------------------------
-- 2. ENTREGAS
-- ---------------------------------------------------------------------
-- task_id toma automáticamente el mismo tipo que tasks.id (bigint o uuid).
do $do$
declare
  tipo_id text;
begin
  select format_type(a.atttypid, a.atttypmod) into tipo_id
  from pg_attribute a
  where a.attrelid = 'public.tasks'::regclass and a.attname = 'id';

  execute format($f$
    create table if not exists public.tb_entregas (
      id                bigint generated always as identity primary key,
      task_id           %s not null references public.tasks(id) on delete cascade,
      user_id           uuid not null default auth.uid()
                        references auth.users(id) on delete cascade,
      texto             text check (char_length(texto) <= 2000),
      archivo_path      text check (char_length(archivo_path) <= 300),
      archivo_nombre    text check (char_length(archivo_nombre) <= 120),
      estado            text not null default 'pendiente'
                        check (estado in ('pendiente', 'aprobada', 'devuelta')),
      nota              smallint check (nota between 0 and 100),
      comentario        text check (char_length(comentario) <= 1000),
      cumplido_otorgado boolean not null default false,
      revisada_por      uuid references auth.users(id) on delete set null,
      revisada_at       timestamptz,
      created_at        timestamptz not null default now(),
      updated_at        timestamptz not null default now(),
      unique (task_id, user_id)
    )$f$, tipo_id);
end $do$;

create index if not exists tb_entregas_estado_idx on public.tb_entregas (estado, updated_at desc);

alter table public.tb_entregas enable row level security;

-- Cada estudiante ve solo sus entregas; owner/admin ven todas.
drop policy if exists tb_entregas_ver on public.tb_entregas;
create policy tb_entregas_ver on public.tb_entregas
  for select to authenticated
  using (user_id = auth.uid() or public.tb_es_staff());

-- Nadie escribe directo en la tabla: todo pasa por las funciones de abajo,
-- que validan cada caso.
revoke insert, update, delete on public.tb_entregas from anon, authenticated;
revoke all on public.tb_entregas from anon;
grant select on public.tb_entregas to authenticated;

-- Enviar o reenviar una entrega (estudiante).
create or replace function public.tb_enviar_entrega(
  p_task text, p_texto text, p_archivo_path text, p_archivo_nombre text)
returns json language plpgsql security definer set search_path = public as $fn$
declare
  v_uid   uuid := auth.uid();
  v_texto text := nullif(btrim(coalesce(p_texto, '')), '');
  v_row   public.tb_entregas%rowtype;
  v_task_id text;
begin
  if v_uid is null then raise exception 'Inicia sesión para entregar.'; end if;

  select id::text into v_task_id from public.tasks
  where id::text = p_task and published = true;
  if v_task_id is null then raise exception 'La tarea no existe o no está publicada.'; end if;

  if v_texto is null and p_archivo_path is null then
    raise exception 'Escribe tu respuesta o adjunta un archivo.';
  end if;
  if char_length(coalesce(v_texto, '')) > 2000 then
    raise exception 'El texto no puede pasar de 2000 caracteres.';
  end if;
  -- El archivo debe estar en la carpeta del propio estudiante.
  if p_archivo_path is not null and
     (split_part(p_archivo_path, '/', 1) <> v_uid::text
      or p_archivo_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}\Z') then
    raise exception 'Archivo no válido.';
  end if;

  select * into v_row from public.tb_entregas e
  where e.task_id::text = v_task_id and e.user_id = v_uid
  for update;

  if found then
    if v_row.estado = 'aprobada' then
      raise exception 'Esta entrega ya fue aprobada.';
    end if;
    if v_row.updated_at > now() - interval '30 seconds' then
      raise exception 'Espera unos segundos antes de volver a enviar.';
    end if;
    update public.tb_entregas set
      texto = v_texto,
      archivo_path = p_archivo_path,
      archivo_nombre = left(p_archivo_nombre, 120),
      estado = 'pendiente',
      updated_at = now()
    where id = v_row.id
    returning * into v_row;
  else
    insert into public.tb_entregas (task_id, user_id, texto, archivo_path, archivo_nombre)
    select t.id, v_uid, v_texto, p_archivo_path, left(p_archivo_nombre, 120)
    from public.tasks t where t.id::text = v_task_id
    returning * into v_row;
  end if;

  return json_build_object('id', v_row.id, 'updated_at', v_row.updated_at);
end $fn$;

-- Calificar (owner/admin). Aprobar suma 1 cumplido una sola vez;
-- devolver una entrega que estaba aprobada lo resta.
create or replace function public.tb_calificar_entrega(
  p_entrega bigint, p_aprobar boolean, p_nota integer, p_comentario text)
returns json language plpgsql security definer set search_path = public as $fn$
declare
  v_row public.tb_entregas%rowtype;
begin
  if not public.tb_es_staff() then
    raise exception 'Solo el owner o un admin pueden calificar.';
  end if;
  if p_nota is not null and (p_nota < 0 or p_nota > 100) then
    raise exception 'La nota debe estar entre 0 y 100.';
  end if;

  select * into v_row from public.tb_entregas where id = p_entrega for update;
  if not found then raise exception 'La entrega no existe.'; end if;

  if p_aprobar and not v_row.cumplido_otorgado then
    update public.profiles set completed_tasks = coalesce(completed_tasks, 0) + 1
    where id = v_row.user_id;
  elsif not p_aprobar and v_row.cumplido_otorgado then
    update public.profiles set completed_tasks = greatest(coalesce(completed_tasks, 0) - 1, 0)
    where id = v_row.user_id;
  end if;

  update public.tb_entregas set
    estado = case when p_aprobar then 'aprobada' else 'devuelta' end,
    nota = p_nota,
    comentario = nullif(left(btrim(coalesce(p_comentario, '')), 1000), ''),
    cumplido_otorgado = p_aprobar,
    revisada_por = auth.uid(),
    revisada_at = now()
  where id = p_entrega
  returning * into v_row;

  return json_build_object('id', v_row.id, 'estado', v_row.estado,
                           'revisada_at', v_row.revisada_at);
end $fn$;

revoke all on function public.tb_enviar_entrega(text, text, text, text) from public, anon;
revoke all on function public.tb_calificar_entrega(bigint, boolean, integer, text) from public, anon;
grant execute on function public.tb_enviar_entrega(text, text, text, text) to authenticated;
grant execute on function public.tb_calificar_entrega(bigint, boolean, integer, text) to authenticated;

-- Bucket PRIVADO para los archivos (máx. 5 MB; imágenes y PDF).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('entregas', 'entregas', false, 5242880,
        array['image/webp', 'image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "tb entregas subir" on storage.objects;
create policy "tb entregas subir" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'entregas'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "tb entregas ver" on storage.objects;
create policy "tb entregas ver" on storage.objects
  for select to authenticated
  using (bucket_id = 'entregas'
         and ((storage.foldername(name))[1] = auth.uid()::text
              or public.tb_es_staff()));

drop policy if exists "tb entregas borrar" on storage.objects;
create policy "tb entregas borrar" on storage.objects
  for delete to authenticated
  using (bucket_id = 'entregas'
         and (storage.foldername(name))[1] = auth.uid()::text);


select 'Entregas activadas' as resultado;
