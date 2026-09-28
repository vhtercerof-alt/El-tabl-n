-- =====================================================================
-- EL TABLÓN · Activar: entregas de tareas, códigos de invitación y avisos
-- =====================================================================
-- Ejecutar UNA vez en Supabase → SQL Editor → New query → Run.
-- Se puede volver a ejecutar sin romper nada (es idempotente).
--
-- Qué crea:
--   1. Funciones de apoyo para saber si quien llama es owner/admin.
--   2. tb_entregas + bucket privado "entregas": los estudiantes envían su
--      trabajo y el owner/admin lo aprueba (suma 1 cumplido) o lo devuelve.
--   3. tb_invitaciones + tb_ajustes: solo se puede crear cuenta con un
--      código válido. Al final se muestra el código inicial.
--   4. tb_push_suscripciones + tb_push_log: avisos al celular.
--
-- Supuestos (tomados de lo que ya usa la página): public.profiles tiene
-- las columnas id (uuid del usuario), role ('owner'/'admin'/'student') y
-- completed_tasks; public.tasks tiene id y published.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Funciones de apoyo
-- ---------------------------------------------------------------------
create or replace function public.tb_es_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('owner', 'admin'));
$$;

create or replace function public.tb_es_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'owner');
$$;

revoke all on function public.tb_es_staff() from public, anon;
revoke all on function public.tb_es_owner() from public, anon;
grant execute on function public.tb_es_staff() to authenticated;
grant execute on function public.tb_es_owner() to authenticated;


-- ---------------------------------------------------------------------
-- 2. ENTREGAS
-- ---------------------------------------------------------------------
-- task_id toma automáticamente el mismo tipo que tasks.id (bigint o uuid).
do $$
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
end $$;

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
returns json language plpgsql security definer set search_path = public as $$
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
     p_archivo_path !~ ('^' || v_uid::text || '/[A-Za-z0-9._-]{1,120}$') then
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
    execute format(
      'insert into public.tb_entregas (task_id, user_id, texto, archivo_path, archivo_nombre)
       select id, $1, $2, $3, $4 from public.tasks where id::text = $5
       returning *')
    into v_row
    using v_uid, v_texto, p_archivo_path, left(p_archivo_nombre, 120), v_task_id;
  end if;

  return json_build_object('id', v_row.id, 'updated_at', v_row.updated_at);
end $$;

-- Calificar (owner/admin). Aprobar suma 1 cumplido una sola vez;
-- devolver una entrega que estaba aprobada lo resta.
create or replace function public.tb_calificar_entrega(
  p_entrega bigint, p_aprobar boolean, p_nota integer, p_comentario text)
returns json language plpgsql security definer set search_path = public as $$
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
end $$;

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


-- ---------------------------------------------------------------------
-- 3. CÓDIGOS DE INVITACIÓN
-- ---------------------------------------------------------------------
create table if not exists public.tb_invitaciones (
  codigo      text primary key check (codigo ~ '^[A-Z0-9]{6,20}$'),
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
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select invitacion_obligatoria from public.tb_ajustes where id = 1), true);
$$;
grant execute on function public.tb_invitacion_requerida() to anon, authenticated;

-- Se ejecuta en el servidor al crear cada cuenta: sin código válido,
-- la cuenta NO se crea (no se puede saltar desde el navegador).
create or replace function public.tb_validar_invitacion()
returns trigger language plpgsql security definer set search_path = public as $$
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
end $$;

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
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Inicia sesión.'; end if;
  insert into public.tb_push_suscripciones (user_id, endpoint, p256dh, auth)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh,
        auth = excluded.auth, created_at = now();
end $$;

create or replace function public.tb_borrar_suscripcion(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from public.tb_push_suscripciones
  where endpoint = p_endpoint and user_id = auth.uid();
$$;

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


-- ---------------------------------------------------------------------
-- Resultado: tu código de invitación inicial
-- ---------------------------------------------------------------------
select codigo as "Código de invitación inicial", usos, activo
from public.tb_invitaciones order by created_at limit 5;
