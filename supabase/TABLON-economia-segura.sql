-- =====================================================================
-- EL TABLÓN · ECONOMÍA SEGURA
-- Ruletas, tienda, regalos, recompensas de nivel, racha y premio diario.
-- =====================================================================
-- Cómo ejecutarlo en Supabase:
--   1. SQL Editor → New query (una pestaña VACÍA).
--   2. Pega TODO este archivo. No selecciones nada.
--   3. Clic en Run. Al final debe aparecer "Economía segura activada".
--   4. Abre El Tablón con tu cuenta de owner una vez: así se carga el
--      catálogo de premios de las ruletas.
-- Se puede ejecutar varias veces sin romper nada.
--
-- Por qué "segura": el sorteo, los precios y los premios los decide la
-- base de datos. Un estudiante no puede darse Belis ni premios desde el
-- navegador.
--
-- Reglas (iguales a las que muestra la página):
--   · 1 giro cada 24 h por ruleta. Repetido paga: Común 8, Raro 15,
--     Épico 40, Legendario 90, Único 300 Belis.
--   · Tienda: tirada 50, épico 150, legendario 400, reinicio 550,
--     protector de racha 120.
--   · Premio diario (ciclo de 7 días): 50, 10, 10, 10, 100, 10, 100.
--   · Recompensas de nivel en 10, 30, 40, 50, 80 y 100.
--   · Fechas según la hora de Nicaragua (America/Managua).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Columnas del perfil que usa la economía (solo se crean si faltan)
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists belis             integer not null default 0;
alter table public.profiles add column if not exists level             integer not null default 1;
alter table public.profiles add column if not exists cards             text[]  not null default '{}';
alter table public.profiles add column if not exists banners           text[]  not null default '{}';
alter table public.profiles add column if not exists motions           text[]  not null default '{}';
alter table public.profiles add column if not exists avatars           text[]  not null default '{}';
alter table public.profiles add column if not exists borders           text[]  not null default '{}';
alter table public.profiles add column if not exists card              text;
alter table public.profiles add column if not exists banner            text;
alter table public.profiles add column if not exists motion            text;
alter table public.profiles add column if not exists avatar            text;
alter table public.profiles add column if not exists border            text;
alter table public.profiles add column if not exists last_spin         timestamptz;
alter table public.profiles add column if not exists last_spin_card    timestamptz;
alter table public.profiles add column if not exists last_spin_motion  timestamptz;
alter table public.profiles add column if not exists last_spin_avatar  timestamptz;
alter table public.profiles add column if not exists last_spin_border  timestamptz;
alter table public.profiles add column if not exists claimed_levels    integer[] not null default '{}';
alter table public.profiles add column if not exists streak_count      integer not null default 0;
alter table public.profiles add column if not exists streak_best       integer not null default 0;
alter table public.profiles add column if not exists streak_shields    integer not null default 0;
alter table public.profiles add column if not exists streak_last       date;
alter table public.profiles add column if not exists login_streak_day  integer not null default 0;
alter table public.profiles add column if not exists login_streak_last date;


-- ---------------------------------------------------------------------
-- 1. Catálogo de premios (lo envía la página del owner)
-- ---------------------------------------------------------------------
create table if not exists public.tb_catalogo (
  kind        text    not null,
  item_id     text    not null,
  rarity      text    not null default 'Común',
  weight      integer not null default 0 check (weight between 0 and 100000),
  activo      boolean not null default true,
  solo_regalo boolean not null default false,
  updated_at  timestamptz not null default now(),
  primary key (kind, item_id)
);
alter table public.tb_catalogo enable row level security;
revoke all on public.tb_catalogo from anon, authenticated;
grant select on public.tb_catalogo to authenticated;
drop policy if exists tb_catalogo_ver on public.tb_catalogo;
create policy tb_catalogo_ver on public.tb_catalogo for select to authenticated using (true);


-- ---------------------------------------------------------------------
-- 2. Funciones de apoyo (internas)
-- ---------------------------------------------------------------------
-- Columna de "objetos que tengo" y de "último giro" de cada ruleta.
create or replace function public.tb_col_owned(p_kind text)
returns text language sql immutable as $fn$
  select case p_kind when 'card' then 'cards' when 'banner' then 'banners'
    when 'motion' then 'motions' when 'avatar' then 'avatars'
    when 'border' then 'borders' end;
$fn$;

create or replace function public.tb_col_spin(p_kind text)
returns text language sql immutable as $fn$
  select case p_kind when 'card' then 'last_spin_card' when 'banner' then 'last_spin'
    when 'motion' then 'last_spin_motion' when 'avatar' then 'last_spin_avatar'
    when 'border' then 'last_spin_border' end;
$fn$;

create or replace function public.tb_pago_repetido(p_rareza text)
returns integer language sql immutable as $fn$
  select case p_rareza when 'Común' then 8 when 'Raro' then 15 when 'Épico' then 40
    when 'Legendario' then 90 when 'Único' then 300 else 0 end;
$fn$;

create or replace function public.tb_hoy()
returns date language sql stable as $fn$
  select (now() at time zone 'America/Managua')::date;
$fn$;

-- Lista (como texto) de lo que hay en una columna-lista del perfil,
-- sea text[], integer[] o jsonb.
create or replace function public.tb_lista(p_uid uuid, p_col text)
returns text[] language plpgsql stable security definer set search_path = public as $fn$
declare
  v text[];
begin
  execute format(
    'select coalesce((select array_agg(x) from jsonb_array_elements_text(
       case when jsonb_typeof(to_jsonb(p.%1$I)) = ''array'' then to_jsonb(p.%1$I)
            else ''[]''::jsonb end) x), ''{}''::text[])
     from public.profiles p where p.id = $1', p_col)
  into v using p_uid;
  return coalesce(v, '{}');
end $fn$;

-- Agrega un valor a una columna-lista del perfil. Devuelve true si era nuevo.
create or replace function public.tb_agregar(p_uid uuid, p_col text, p_valor text, p_numero boolean default false)
returns boolean language plpgsql security definer set search_path = public as $fn$
declare
  v_tipo text;
begin
  if p_valor = any(public.tb_lista(p_uid, p_col)) then
    return false;
  end if;
  select format_type(a.atttypid, a.atttypmod) into v_tipo
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass and a.attname = p_col and not a.attisdropped;
  if v_tipo is null then
    raise exception 'Falta la columna % en profiles.', p_col;
  elsif v_tipo in ('jsonb', 'json') then
    execute format(
      'update public.profiles set %1$I = ((case when jsonb_typeof(to_jsonb(%1$I)) = ''array''
         then to_jsonb(%1$I) else ''[]''::jsonb end) || jsonb_build_array(%2$s))::%3$s
       where id = $1', p_col, case when p_numero then '$2::integer' else '$2' end, v_tipo)
    using p_uid, p_valor;
  elsif right(v_tipo, 2) = '[]' then
    execute format(
      'update public.profiles set %1$I = array_append(coalesce(%1$I, ''{}''), $2::%2$s) where id = $1',
      p_col, left(v_tipo, length(v_tipo) - 2))
    using p_uid, p_valor;
  else
    raise exception 'La columna % tiene un tipo no soportado (%).', p_col, v_tipo;
  end if;
  return true;
end $fn$;

-- Guarda la fecha y hora actual en una columna del perfil. Si la columna
-- es de texto, usa formato ISO (lo entienden todos los navegadores).
create or replace function public.tb_marcar_ahora(p_uid uuid, p_col text)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_tipo text;
begin
  select format_type(a.atttypid, a.atttypmod) into v_tipo
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass and a.attname = p_col and not a.attisdropped;
  if v_tipo in ('text', 'character varying') then
    execute format('update public.profiles set %I = $2 where id = $1', p_col)
      using p_uid, to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  else
    execute format('update public.profiles set %I = now() where id = $1', p_col) using p_uid;
  end if;
end $fn$;

-- Devuelve solo algunas columnas del perfil (para refrescar la página).
create or replace function public.tb_perfil(p_uid uuid, p_cols text[])
returns jsonb language sql stable security definer set search_path = public as $fn$
  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
  from public.profiles p, jsonb_each(to_jsonb(p)) e
  where p.id = p_uid and e.key = any(p_cols);
$fn$;

-- Bloquea el perfil del usuario actual (evita gastar dos veces a la vez).
create or replace function public.tb_mi_perfil()
returns public.profiles language plpgsql security definer set search_path = public as $fn$
declare
  v public.profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Inicia sesión.'; end if;
  select * into v from public.profiles where id = auth.uid() for update;
  if not found then raise exception 'No se encontró tu perfil.'; end if;
  return v;
end $fn$;

-- Las funciones internas no se pueden llamar desde la página.
revoke all on function public.tb_lista(uuid, text) from public, anon, authenticated;
revoke all on function public.tb_agregar(uuid, text, text, boolean) from public, anon, authenticated;
revoke all on function public.tb_perfil(uuid, text[]) from public, anon, authenticated;
revoke all on function public.tb_mi_perfil() from public, anon, authenticated;
revoke all on function public.tb_marcar_ahora(uuid, text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 3. Sincronizar catálogo (solo owner)
-- ---------------------------------------------------------------------
create or replace function public.tb_sincronizar_catalogo(p_items jsonb)
returns json language plpgsql security definer set search_path = public as $fn$
declare
  v_n integer;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'owner') then
    raise exception 'Solo el owner puede actualizar el catálogo.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 5000 then
    raise exception 'Catálogo no válido.';
  end if;
  insert into public.tb_catalogo (kind, item_id, rarity, weight, activo, solo_regalo, updated_at)
  select i->>'kind', i->>'item_id', left(coalesce(i->>'rarity', 'Común'), 30),
         least(greatest(coalesce((i->>'weight')::integer, 0), 0), 100000),
         coalesce((i->>'activo')::boolean, true), coalesce((i->>'solo_regalo')::boolean, false), now()
  from jsonb_array_elements(p_items) i
  where i->>'kind' in ('card', 'banner', 'motion', 'avatar', 'border', 'carta')
    and coalesce(i->>'item_id', '') ~ '^[A-Za-z0-9_-]{1,80}\Z'
  on conflict (kind, item_id) do update set
    rarity = excluded.rarity, weight = excluded.weight, activo = excluded.activo,
    solo_regalo = excluded.solo_regalo, updated_at = now();
  get diagnostics v_n = row_count;
  -- Lo que ya no está en la página deja de salir en las ruletas.
  update public.tb_catalogo c set activo = false, updated_at = now()
  where c.activo and not exists (
    select 1 from jsonb_array_elements(p_items) i
    where i->>'kind' = c.kind and i->>'item_id' = c.item_id);
  return json_build_object('items', v_n);
end $fn$;


-- ---------------------------------------------------------------------
-- 4. Girar una ruleta
-- ---------------------------------------------------------------------
create or replace function public.tb_girar(p_kind text)
returns json language plpgsql security definer set search_path = public as $fn$
declare
  v_yo      public.profiles%rowtype;
  v_owned   text := public.tb_col_owned(p_kind);
  v_spin    text := public.tb_col_spin(p_kind);
  v_ultimo  timestamptz;
  v_item    text;
  v_rareza  text;
  v_carta   text;
  v_shiny   boolean := false;
  v_nuevo   boolean;
  v_pago    integer := 0;
begin
  if v_owned is null then raise exception 'Ruleta no válida.'; end if;
  v_yo := public.tb_mi_perfil();

  execute format('select %I::text::timestamptz from public.profiles where id = $1', v_spin)
    into v_ultimo using v_yo.id;
  if v_ultimo is not null and v_ultimo > now() - interval '24 hours' then
    raise exception 'Todavía no puedes girar esta ruleta. Vuelve cuando termine la cuenta regresiva.';
  end if;

  -- Carta épica (casi imposible) solo en la ruleta de tarjetas.
  if p_kind = 'card' and random() < 0.00000000067 then
    select item_id into v_carta from public.tb_catalogo
    where kind = 'carta' and activo order by random() limit 1;
    if v_carta is not null then
      v_shiny := random() < 0.1;
      v_item := (case when v_shiny then 'shiny_' else 'carta_' end) || v_carta;
      v_nuevo := public.tb_agregar(v_yo.id, 'cards', v_item);
      perform public.tb_marcar_ahora(v_yo.id, v_spin);
      return json_build_object('tipo', 'carta', 'carta', v_carta, 'shiny', v_shiny, 'nuevo', v_nuevo,
        'perfil', public.tb_perfil(v_yo.id, array['cards', v_spin, 'belis']));
    end if;
  end if;

  -- Sorteo ponderado por peso entre los premios activos de esa ruleta.
  select item_id, rarity into v_item, v_rareza
  from public.tb_catalogo
  where kind = p_kind and activo and not solo_regalo and weight > 0
  order by -ln(1.0 - random()) / weight
  limit 1;
  if v_item is null then
    raise exception 'El catálogo de premios aún no está cargado: el owner debe abrir El Tablón una vez.';
  end if;

  v_nuevo := public.tb_agregar(v_yo.id, v_owned, v_item);
  if not v_nuevo then
    v_pago := public.tb_pago_repetido(v_rareza);
    update public.profiles set belis = coalesce(belis, 0) + v_pago where id = v_yo.id;
  end if;
  perform public.tb_marcar_ahora(v_yo.id, v_spin);

  return json_build_object('tipo', 'item', 'premio', v_item, 'rareza', v_rareza,
    'nuevo', v_nuevo, 'pago', v_pago,
    'perfil', public.tb_perfil(v_yo.id, array[v_owned, v_spin, 'belis']));
end $fn$;


-- ---------------------------------------------------------------------
-- 5. Tienda
-- ---------------------------------------------------------------------
create or replace function public.tb_comprar(p_clave text, p_kind text default null)
returns json language plpgsql security definer set search_path = public as $fn$
declare
  v_yo     public.profiles%rowtype;
  v_precio integer;
  v_owned  text;
  v_spin   text;
  v_ultimo timestamptz;
  v_item   text;
  v_rareza text;
  v_cols   text[] := array['belis'];
begin
  v_precio := case p_clave when 'tirada' then 50 when 'epica' then 150
    when 'legendaria' then 400 when 'reset' then 550 when 'protector' then 120 end;
  if v_precio is null then raise exception 'Producto no válido.'; end if;
  v_yo := public.tb_mi_perfil();
  if coalesce(v_yo.belis, 0) < v_precio then
    raise exception 'No te alcanzan los Belis: cuesta % y tienes %.', v_precio, coalesce(v_yo.belis, 0);
  end if;

  if p_clave in ('tirada', 'epica', 'legendaria') then
    v_owned := public.tb_col_owned(p_kind);
    v_spin := public.tb_col_spin(p_kind);
    if v_owned is null then raise exception 'Elige una ruleta válida.'; end if;
  end if;

  if p_clave = 'tirada' then
    execute format('select %I::text::timestamptz from public.profiles where id = $1', v_spin)
      into v_ultimo using v_yo.id;
    if v_ultimo is null or v_ultimo <= now() - interval '24 hours' then
      raise exception 'Esa ruleta ya está disponible: gírala gratis.';
    end if;
    execute format('update public.profiles set %I = null where id = $1', v_spin) using v_yo.id;
    v_cols := array_append(v_cols, v_spin);

  elsif p_clave in ('epica', 'legendaria') then
    v_rareza := case p_clave when 'epica' then 'Épico' else 'Legendario' end;
    select item_id into v_item from public.tb_catalogo
    where kind = p_kind and rarity = v_rareza and activo and not solo_regalo and weight > 0
      and not (item_id = any(public.tb_lista(v_yo.id, v_owned)))
    order by random() limit 1;
    if v_item is null then
      raise exception 'Ya tienes todos los cosméticos % de esa ruleta.', v_rareza;
    end if;
    perform public.tb_agregar(v_yo.id, v_owned, v_item);
    v_cols := array_append(v_cols, v_owned);

  elsif p_clave = 'reset' then
    update public.profiles set last_spin = null, last_spin_card = null, last_spin_motion = null,
      last_spin_avatar = null, last_spin_border = null where id = v_yo.id;
    v_cols := array_cat(v_cols, array['last_spin', 'last_spin_card', 'last_spin_motion', 'last_spin_avatar', 'last_spin_border']);

  elsif p_clave = 'protector' then
    if coalesce(v_yo.streak_shields, 0) >= 99 then
      raise exception 'Ya tienes el máximo de protectores (99).';
    end if;
    update public.profiles set streak_shields = coalesce(streak_shields, 0) + 1 where id = v_yo.id;
    v_cols := array_append(v_cols, 'streak_shields');
  end if;

  update public.profiles set belis = belis - v_precio where id = v_yo.id;
  return json_build_object('clave', p_clave, 'premio', v_item, 'nuevo', v_item is not null,
    'perfil', public.tb_perfil(v_yo.id, v_cols));
end $fn$;


-- ---------------------------------------------------------------------
-- 6. Abrir un regalo
-- ---------------------------------------------------------------------
create or replace function public.tb_abrir_regalo(p_regalo text)
returns json language plpgsql security definer set search_path = public as $fn$
declare
  v_yo    public.profiles%rowtype;
  v_kind  text;
  v_item  text;
  v_owned text;
  v_nuevo boolean;
  v_fecha timestamptz := now();
begin
  v_yo := public.tb_mi_perfil();
  select g.kind, g.item_id into v_kind, v_item
  from public.gifts g
  where g.id::text = p_regalo and g.user_id = v_yo.id and g.claimed_at is null
  for update;
  if v_item is null then
    raise exception 'Ese regalo no existe o ya lo abriste.';
  end if;
  v_owned := public.tb_col_owned(v_kind);
  if v_owned is null then raise exception 'Tipo de regalo no válido.'; end if;
  v_nuevo := public.tb_agregar(v_yo.id, v_owned, v_item);
  update public.gifts set claimed_at = v_fecha where id::text = p_regalo;
  return json_build_object('nuevo', v_nuevo, 'claimed_at', v_fecha, 'kind', v_kind, 'premio', v_item,
    'perfil', public.tb_perfil(v_yo.id, array[v_owned]));
end $fn$;


-- ---------------------------------------------------------------------
-- 7. Recompensas por nivel
-- ---------------------------------------------------------------------
create or replace function public.tb_revisar_niveles()
returns json language plpgsql security definer set search_path = public as $fn$
declare
  v_yo      public.profiles%rowtype;
  v_hito    integer;
  v_ultimo  integer;
  v_kind    text;
  v_item    text;
  v_cols    text[] := array['claimed_levels'];
begin
  v_yo := public.tb_mi_perfil();
  foreach v_hito in array array[10, 30, 40, 50, 80, 100] loop
    continue when coalesce(v_yo.level, 1) < v_hito;
    continue when v_hito::text = any(public.tb_lista(v_yo.id, 'claimed_levels'));
    perform public.tb_agregar(v_yo.id, 'claimed_levels', v_hito::text, true);
    v_ultimo := v_hito;
    v_kind := null; v_item := null;
    if to_regclass('public.level_rewards') is not null then
      execute 'select kind, item_id from public.level_rewards where level = $1'
        into v_kind, v_item using v_hito;
    end if;
    if public.tb_col_owned(v_kind) is not null and v_item is not null then
      perform public.tb_agregar(v_yo.id, public.tb_col_owned(v_kind), v_item);
      v_cols := array_append(v_cols, public.tb_col_owned(v_kind));
    end if;
  end loop;
  return json_build_object('nivel', v_ultimo, 'perfil', public.tb_perfil(v_yo.id, v_cols));
end $fn$;


-- ---------------------------------------------------------------------
-- 8. Racha de días
-- ---------------------------------------------------------------------
create or replace function public.tb_revisar_racha()
returns json language plpgsql security definer set search_path = public as $fn$
declare
  v_yo      public.profiles%rowtype;
  v_hoy     date := public.tb_hoy();
  v_ultimo  date;
  v_dias    integer;
  v_antes   integer;
  v_nueva   integer;
  v_usados  integer := 0;
  v_reinicio boolean := false;
  v_pend    integer[];
begin
  v_yo := public.tb_mi_perfil();
  v_ultimo := left(v_yo.streak_last::text, 10)::date;
  v_antes := coalesce(v_yo.streak_count, 0);
  if v_ultimo = v_hoy then
    return json_build_object('cambio', false);
  end if;
  if v_ultimo is null or v_ultimo > v_hoy then
    v_nueva := 1; v_reinicio := v_antes > 0;
  else
    v_dias := v_hoy - v_ultimo;
    if v_dias = 1 then
      v_nueva := v_antes + 1;
    elsif coalesce(v_yo.streak_shields, 0) >= v_dias - 1 then
      v_usados := v_dias - 1;
      v_nueva := v_antes + 1;
    else
      v_nueva := 1; v_reinicio := true;
    end if;
  end if;
  update public.profiles set
    streak_count = v_nueva,
    streak_best = greatest(coalesce(streak_best, 0), v_nueva),
    streak_shields = greatest(coalesce(streak_shields, 0) - v_usados, 0),
    streak_last = v_hoy
  where id = v_yo.id;
  select coalesce(array_agg(m order by m), '{}') into v_pend
  from unnest(array[1, 2, 3, 10, 30, 50, 70, 100, 150, 200, 300]) m
  where not v_reinicio and m > v_antes and m <= v_nueva;
  return json_build_object('cambio', true, 'nueva', v_nueva, 'usados', v_usados, 'pendientes', v_pend,
    'perfil', public.tb_perfil(v_yo.id, array['streak_count', 'streak_best', 'streak_shields', 'streak_last']));
end $fn$;


-- ---------------------------------------------------------------------
-- 9. Premio diario por entrar (ciclo de 7 días)
-- ---------------------------------------------------------------------
create or replace function public.tb_recompensa_diaria()
returns json language plpgsql security definer set search_path = public as $fn$
declare
  v_yo     public.profiles%rowtype;
  v_hoy    date := public.tb_hoy();
  v_ultimo date;
  v_dia    integer;
  v_monto  integer;
begin
  v_yo := public.tb_mi_perfil();
  v_ultimo := left(v_yo.login_streak_last::text, 10)::date;
  if v_ultimo = v_hoy then
    return json_build_object('dia', null);
  end if;
  if v_ultimo = v_hoy - 1 then
    v_dia := (coalesce(v_yo.login_streak_day, 0) % 7) + 1;
  else
    v_dia := 1;
  end if;
  v_monto := (array[50, 10, 10, 10, 100, 10, 100])[v_dia];
  update public.profiles set belis = coalesce(belis, 0) + v_monto,
    login_streak_day = v_dia, login_streak_last = v_hoy
  where id = v_yo.id;
  return json_build_object('dia', v_dia, 'monto', v_monto,
    'perfil', public.tb_perfil(v_yo.id, array['belis', 'login_streak_day', 'login_streak_last']));
end $fn$;


-- ---------------------------------------------------------------------
-- 10. Permisos: solo usuarios con sesión pueden llamar a las funciones
-- ---------------------------------------------------------------------
revoke all on function public.tb_sincronizar_catalogo(jsonb) from public, anon;
revoke all on function public.tb_girar(text) from public, anon;
revoke all on function public.tb_comprar(text, text) from public, anon;
revoke all on function public.tb_abrir_regalo(text) from public, anon;
revoke all on function public.tb_revisar_niveles() from public, anon;
revoke all on function public.tb_revisar_racha() from public, anon;
revoke all on function public.tb_recompensa_diaria() from public, anon;
grant execute on function public.tb_sincronizar_catalogo(jsonb) to authenticated;
grant execute on function public.tb_girar(text) to authenticated;
grant execute on function public.tb_comprar(text, text) to authenticated;
grant execute on function public.tb_abrir_regalo(text) to authenticated;
grant execute on function public.tb_revisar_niveles() to authenticated;
grant execute on function public.tb_revisar_racha() to authenticated;
grant execute on function public.tb_recompensa_diaria() to authenticated;

select 'Economía segura activada. Abre El Tablón con tu cuenta de owner para cargar el catálogo.' as resultado;
