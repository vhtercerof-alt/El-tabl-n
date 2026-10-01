-- =====================================================================
-- EL TABLÓN · LOGROS: cumpleaños, misiones semanales e insignias
-- Ejecutar en Supabase → SQL Editor → New query → pegar TODO → Run.
-- Se puede ejecutar varias veces sin romper nada.
--
-- Requisitos (ya existen si ejecutaste los otros archivos):
--   · TABLON-economia-segura.sql (Belis, regalos y tb_abrir_regalo).
-- Después de ejecutarlo, entra una vez con tu cuenta de owner: El Tablón
-- carga solo el catálogo de misiones y los cosméticos nuevos.
--
-- Protecciones (adaptado para que nadie haga trampa desde el navegador):
--   · Las misiones avanzan solo con eventos conocidos, con un tope por
--     llamada y un tiempo mínimo entre eventos (por ejemplo, 1 Wordle al
--     día, una partida de Tetris cada 20 s).
--   · Premios y Belis los entrega solo la base de datos, una vez por misión.
--   · El cumpleaños se registra una sola vez (después solo el owner o un
--     admin lo cambia). Si un estudiante lo registra menos de 7 días antes
--     de la fecha, ese año no hay regalo (evita registrar "hoy" para cobrarlo).
--   · misiones_total solo cambia al reclamar misiones.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Columnas nuevas en profiles
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists cumple            text;
alter table public.profiles add column if not exists cumple_registrado timestamptz;
alter table public.profiles add column if not exists misiones_total    integer not null default 0;

do $chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_cumple_formato') then
    alter table public.profiles add constraint profiles_cumple_formato
      check (cumple is null or cumple ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$');
  end if;
end $chk$;


-- ---------------------------------------------------------------------
-- 2. Funciones de apoyo
-- ---------------------------------------------------------------------
create or replace function public.tb_es_staff()
returns boolean language sql stable security definer set search_path = public as $fn_staff$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('owner', 'admin'));
$fn_staff$;
revoke all on function public.tb_es_staff() from public, anon;
grant execute on function public.tb_es_staff() to authenticated;

-- Semana ISO en hora de Nicaragua (las misiones cambian el lunes a las 00:00).
create or replace function public.tb_semana_actual()
returns text language sql stable as $fn_semana$
  select to_char((now() at time zone 'America/Managua')::date, 'IYYY-"W"IW');
$fn_semana$;

-- Límites de cada evento: máximo por llamada y segundos mínimos entre eventos.
-- Un evento que no está en esta lista no hace avanzar ninguna misión.
create or replace function public.tb_mision_limite(p_evento text, out maximo integer, out segundos integer)
language sql immutable as $fn_limite$
  select x.maximo, x.segundos from (values
    ('tetris_partida',      1,    20),
    ('tetris_puntos',  200000,    20),
    ('wordle_ganar',        1, 72000),
    ('gato_jugar',          1,    15),
    ('gato_ganar',          1,    15),
    ('vf_aciertos',        30,    20),
    ('stop_jugar',          1,    30),
    ('stop_ganar',          1,    30),
    ('pin_jugar',           1,    30),
    ('pin_ganar',           1,    30),
    ('naval_jugar',         1,    60),
    ('naval_ganar',         1,    60),
    ('prefiere_votar',      1, 72000),
    ('encuesta_votar',      1,    10),
    ('meme_enviar',         1,    30),
    ('lengua_revisar',      1,    20),
    ('ruleta_girar',        1,     2),
    ('entrega_subir',       1,    20),
    ('mascota_mimos',       1,     2)
  ) as x(evento, maximo, segundos)
  where x.evento = p_evento;
$fn_limite$;


-- ---------------------------------------------------------------------
-- 3. Protección de columnas de profiles
-- ---------------------------------------------------------------------
create or replace function public.tb_logros_proteger()
returns trigger language plpgsql security definer set search_path = public as $fn_proteger$
begin
  if new.cumple is distinct from old.cumple and auth.uid() is not null then
    if public.tb_es_staff() then
      -- Lo corrige el staff: el regalo no queda bloqueado.
      new.cumple_registrado := null;
    elsif old.cumple is not null then
      raise exception 'El cumpleaños ya está registrado; solo el owner puede cambiarlo.';
    else
      new.cumple_registrado := now();
    end if;
  elsif new.cumple_registrado is distinct from old.cumple_registrado and auth.uid() is not null
        and not public.tb_es_staff() then
    -- Solo el staff puede desbloquear el regalo (poniendo cumple_registrado en null).
    new.cumple_registrado := old.cumple_registrado;
  end if;
  if new.misiones_total is distinct from old.misiones_total
     and auth.uid() is not null
     and coalesce(current_setting('tb.logros', true), '') <> '1' then
    new.misiones_total := old.misiones_total;
  end if;
  return new;
end;
$fn_proteger$;
drop trigger if exists tb_logros_proteger_trg on public.profiles;
create trigger tb_logros_proteger_trg
  before update on public.profiles
  for each row execute function public.tb_logros_proteger();


-- ---------------------------------------------------------------------
-- 4. Tablas
-- ---------------------------------------------------------------------
create table if not exists public.tb_misiones_catalogo (
  id          text primary key,
  evento      text not null,
  modo        text not null default 'sumar' check (modo in ('sumar', 'maximo')),
  meta        integer not null check (meta between 1 and 1000000),
  belis       integer not null default 0 check (belis between 0 and 1000),
  premio_kind text check (premio_kind is null or premio_kind in ('card', 'banner', 'motion', 'avatar', 'border')),
  premio_item text,
  activa      boolean not null default true,
  updated_at  timestamptz not null default now()
);

create table if not exists public.tb_misiones_progreso (
  profile_id   uuid not null references auth.users (id) on delete cascade,
  semana       text not null,
  mision_id    text not null,
  meta         integer not null,
  progreso     integer not null default 0,
  reclamada_at timestamptz,
  primary key (profile_id, semana, mision_id)
);

-- Último evento contado de cada tipo (para el tiempo mínimo entre eventos).
create table if not exists public.tb_misiones_eventos (
  profile_id uuid not null references auth.users (id) on delete cascade,
  evento     text not null,
  ultimo     timestamptz not null,
  primary key (profile_id, evento)
);

create table if not exists public.tb_cumple_regalos (
  profile_id uuid not null references auth.users (id) on delete cascade,
  anio       integer not null,
  created_at timestamptz not null default now(),
  primary key (profile_id, anio)
);

alter table public.tb_misiones_catalogo enable row level security;
alter table public.tb_misiones_progreso enable row level security;
alter table public.tb_misiones_eventos  enable row level security;
alter table public.tb_cumple_regalos    enable row level security;

-- Solo lectura desde la página; todo se escribe con las funciones de abajo.
revoke all on public.tb_misiones_catalogo from anon, authenticated;
revoke all on public.tb_misiones_progreso from anon, authenticated;
revoke all on public.tb_misiones_eventos  from anon, authenticated;
revoke all on public.tb_cumple_regalos    from anon, authenticated;
grant select on public.tb_misiones_catalogo to authenticated;
grant select on public.tb_misiones_progreso to authenticated;
grant select on public.tb_cumple_regalos    to authenticated;

drop policy if exists "misiones_catalogo_leer" on public.tb_misiones_catalogo;
create policy "misiones_catalogo_leer" on public.tb_misiones_catalogo
  for select to authenticated using (true);

drop policy if exists "misiones_progreso_propio" on public.tb_misiones_progreso;
create policy "misiones_progreso_propio" on public.tb_misiones_progreso
  for select to authenticated using (profile_id = auth.uid());

drop policy if exists "cumple_regalos_propio" on public.tb_cumple_regalos;
create policy "cumple_regalos_propio" on public.tb_cumple_regalos
  for select to authenticated using (profile_id = auth.uid());


-- ---------------------------------------------------------------------
-- 5. Misiones
-- ---------------------------------------------------------------------
create or replace function public.tb_misiones_json(p_uid uuid, p_sem text)
returns jsonb language sql stable security definer set search_path = public as $fn_json$
  select jsonb_build_object(
    'semana', p_sem,
    'misiones', coalesce(jsonb_agg(jsonb_build_object(
      'id', mision_id, 'meta', meta, 'progreso', progreso, 'reclamada', reclamada_at is not null
    ) order by mision_id), '[]'::jsonb))
  from public.tb_misiones_progreso
  where profile_id = p_uid and semana = p_sem;
$fn_json$;
revoke all on function public.tb_misiones_json(uuid, text) from public, anon, authenticated;

-- Misiones de la semana: 4 de Belis y 2 de cosmético, iguales para todo el salón.
create or replace function public.tb_misiones_semana()
returns jsonb language plpgsql security definer set search_path = public as $fn_misiones$
declare
  v_uid uuid := auth.uid();
  v_sem text := public.tb_semana_actual();
begin
  if v_uid is null then raise exception 'Inicia sesión.'; end if;
  if not exists (select 1 from public.tb_misiones_progreso where profile_id = v_uid and semana = v_sem) then
    insert into public.tb_misiones_progreso (profile_id, semana, mision_id, meta)
    select v_uid, v_sem, x.id, x.meta from (
      (select id, meta from public.tb_misiones_catalogo
        where activa and premio_kind is null order by md5(id || v_sem) limit 4)
      union all
      (select id, meta from public.tb_misiones_catalogo
        where activa and premio_kind is not null order by md5(id || v_sem) limit 2)
    ) x
    on conflict do nothing;
  end if;
  return public.tb_misiones_json(v_uid, v_sem);
end;
$fn_misiones$;

create or replace function public.tb_mision_avanzar(p_evento text, p_cantidad integer default 1)
returns jsonb language plpgsql security definer set search_path = public as $fn_avanzar$
declare
  v_uid    uuid := auth.uid();
  v_sem    text := public.tb_semana_actual();
  v_lim    record;
  v_ultimo timestamptz;
  v_cant   integer;
begin
  if v_uid is null then raise exception 'Inicia sesión.'; end if;
  select * into v_lim from public.tb_mision_limite(p_evento);
  if v_lim.maximo is null then
    return public.tb_misiones_json(v_uid, v_sem);   -- evento desconocido: no cuenta
  end if;
  v_cant := greatest(1, least(coalesce(p_cantidad, 1), v_lim.maximo));

  -- Tiempo mínimo entre eventos del mismo tipo.
  select ultimo into v_ultimo from public.tb_misiones_eventos
   where profile_id = v_uid and evento = p_evento for update;
  if v_ultimo is not null and now() - v_ultimo < make_interval(secs => v_lim.segundos) then
    return public.tb_misiones_json(v_uid, v_sem);
  end if;
  insert into public.tb_misiones_eventos (profile_id, evento, ultimo)
  values (v_uid, p_evento, now())
  on conflict (profile_id, evento) do update set ultimo = excluded.ultimo;

  update public.tb_misiones_progreso p
     set progreso = case
       when c.modo = 'maximo' then least(p.meta, greatest(p.progreso, v_cant))
       else least(p.meta, p.progreso + v_cant)
     end
    from public.tb_misiones_catalogo c
   where p.mision_id = c.id
     and p.profile_id = v_uid
     and p.semana = v_sem
     and c.evento = p_evento
     and p.reclamada_at is null;
  return public.tb_misiones_json(v_uid, v_sem);
end;
$fn_avanzar$;

create or replace function public.tb_mision_reclamar(p_mision text)
returns jsonb language plpgsql security definer set search_path = public as $fn_reclamar$
declare
  v_uid    uuid := auth.uid();
  v_sem    text := public.tb_semana_actual();
  v_p      public.tb_misiones_progreso%rowtype;
  v_c      public.tb_misiones_catalogo%rowtype;
  v_regalo text;
  v_belis  integer := 0;
begin
  if v_uid is null then raise exception 'Inicia sesión.'; end if;
  select * into v_p from public.tb_misiones_progreso
   where profile_id = v_uid and semana = v_sem and mision_id = p_mision for update;
  if not found then raise exception 'Esa misión no es de esta semana.'; end if;
  if v_p.reclamada_at is not null then raise exception 'Ya reclamaste esta misión.'; end if;
  if v_p.progreso < v_p.meta then raise exception 'La misión todavía no está completa.'; end if;
  select * into v_c from public.tb_misiones_catalogo where id = p_mision;
  if not found then raise exception 'Misión desconocida.'; end if;

  update public.tb_misiones_progreso set reclamada_at = now()
   where profile_id = v_uid and semana = v_sem and mision_id = p_mision;

  perform set_config('tb.logros', '1', true);
  if v_c.premio_kind is not null and v_c.premio_item is not null then
    insert into public.gifts (user_id, kind, item_id, created_by)
    values (v_uid, v_c.premio_kind, v_c.premio_item, v_uid)
    returning id::text into v_regalo;
  else
    v_belis := v_c.belis;
    update public.profiles set belis = coalesce(belis, 0) + v_belis where id = v_uid;
  end if;
  update public.profiles set misiones_total = coalesce(misiones_total, 0) + 1 where id = v_uid;

  return public.tb_misiones_json(v_uid, v_sem) || jsonb_build_object(
    'belis', v_belis,
    'regalo', v_regalo,
    'perfil', (select jsonb_build_object('belis', belis, 'misiones_total', misiones_total)
                 from public.profiles where id = v_uid));
end;
$fn_reclamar$;

-- El owner sincroniza el catálogo desde El Tablón (lo hace solo al entrar).
create or replace function public.tb_sincronizar_misiones(p_items jsonb)
returns void language plpgsql security definer set search_path = public as $fn_sync$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'owner') then
    raise exception 'Solo el owner puede sincronizar las misiones.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 200 then
    raise exception 'Catálogo de misiones no válido.';
  end if;
  insert into public.tb_misiones_catalogo (id, evento, modo, meta, belis, premio_kind, premio_item, activa, updated_at)
  select x->>'id', x->>'evento', coalesce(x->>'modo', 'sumar'),
         least(greatest(coalesce((x->>'meta')::integer, 1), 1), 1000000),
         least(greatest(coalesce((x->>'belis')::integer, 0), 0), 1000),
         nullif(x->>'premio_kind', ''), nullif(x->>'premio_item', ''), true, now()
    from jsonb_array_elements(p_items) x
   where (x->>'id') ~ '^[a-z0-9_]{1,40}$'
     and (x->>'evento') ~ '^[a-z0-9_]{1,40}$'
  on conflict (id) do update set
    evento = excluded.evento, modo = excluded.modo, meta = excluded.meta, belis = excluded.belis,
    premio_kind = excluded.premio_kind, premio_item = excluded.premio_item, activa = true, updated_at = now();
  update public.tb_misiones_catalogo set activa = false
   where id not in (select x->>'id' from jsonb_array_elements(p_items) x where x->>'id' is not null);
end;
$fn_sync$;


-- ---------------------------------------------------------------------
-- 6. Regalo de cumpleaños (una vez al año, solo el día del cumpleaños)
-- ---------------------------------------------------------------------
create or replace function public.tb_regalo_cumple()
returns jsonb language plpgsql security definer set search_path = public as $fn_cumple$
declare
  v_uid    uuid := auth.uid();
  v_md     text := to_char((now() at time zone 'America/Managua')::date, 'MM-DD');
  v_anio   integer := extract(year from (now() at time zone 'America/Managua'))::integer;
  v_cumple text;
  v_reg    timestamptz;
  v_regalo text;
begin
  if v_uid is null then raise exception 'Inicia sesión.'; end if;
  select cumple, cumple_registrado into v_cumple, v_reg from public.profiles where id = v_uid;
  if v_cumple is null then raise exception 'No tienes cumpleaños registrado.'; end if;
  if not (v_cumple = v_md or (v_cumple = '02-29' and v_md = '02-28'
          and not (v_anio % 4 = 0 and (v_anio % 100 <> 0 or v_anio % 400 = 0)))) then
    raise exception 'Hoy no es tu cumpleaños.';
  end if;
  if v_reg is not null and now() - v_reg < interval '7 days' then
    raise exception 'Registraste tu cumpleaños hace muy poco: tu regalo llegará el próximo año. ¡Igual te deseamos un feliz día!';
  end if;
  insert into public.tb_cumple_regalos (profile_id, anio) values (v_uid, v_anio) on conflict do nothing;
  if not found then raise exception 'Ya abriste tu regalo de este año.'; end if;
  insert into public.gifts (user_id, kind, item_id, created_by)
  values (v_uid, 'border', 'cumple_confeti', v_uid)
  returning id::text into v_regalo;
  update public.profiles set belis = coalesce(belis, 0) + 100 where id = v_uid;
  return jsonb_build_object('regalo', v_regalo, 'belis', 100,
    'perfil', (select jsonb_build_object('belis', belis) from public.profiles where id = v_uid));
end;
$fn_cumple$;


-- ---------------------------------------------------------------------
-- 7. Permisos de las funciones
-- ---------------------------------------------------------------------
revoke all on function public.tb_mision_limite(text)               from public, anon, authenticated;
revoke all on function public.tb_misiones_semana()                 from public, anon;
revoke all on function public.tb_mision_avanzar(text, integer)     from public, anon;
revoke all on function public.tb_mision_reclamar(text)             from public, anon;
revoke all on function public.tb_sincronizar_misiones(jsonb)       from public, anon;
revoke all on function public.tb_regalo_cumple()                   from public, anon;
grant execute on function public.tb_misiones_semana()              to authenticated;
grant execute on function public.tb_mision_avanzar(text, integer)  to authenticated;
grant execute on function public.tb_mision_reclamar(text)          to authenticated;
grant execute on function public.tb_sincronizar_misiones(jsonb)    to authenticated;
grant execute on function public.tb_regalo_cumple()                to authenticated;

select 'Logros activados: cumpleaños, misiones e insignias' as resultado;
