-- =====================================================================
-- EL TABLÓN · PINTURILLO EN SALAS (multijugador, por turnos, espectadores)
-- Ejecutar en Supabase → SQL Editor → New query → pegar TODO → Run.
-- Se puede ejecutar varias veces sin romper nada.
--
-- Cómo funciona:
--   · Alguien crea una sala (código de 4 letras) y los demás entran.
--     De 2 a 12 jugadores; cualquiera puede "mirar" como espectador.
--   · Por turnos, cada jugador dibuja una palabra en la pizarra y el resto
--     la adivina. Puntos: más rápido = más puntos; quien dibuja gana puntos
--     por cada persona que adivina.
--   · La palabra secreta está en una tabla que NADIE puede leer: solo la
--     recibe quien dibuja, a través de pin_sala_estado.
--   · Todo cambio se hace con funciones que verifican quién llama.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------
create table if not exists public.pin_salas (
  id           uuid primary key default gen_random_uuid(),
  codigo       text not null unique check (codigo ~ '^[A-Z]{4}$'),
  nombre       text not null check (char_length(nombre) between 1 and 40),
  anfitrion    uuid not null references public.profiles(id) on delete cascade,
  estado       text not null default 'espera' check (estado in ('espera', 'jugando', 'terminada')),
  fase         text not null default 'espera' check (fase in ('espera', 'dibujando', 'pausa', 'fin')),
  rondas       integer not null default 2 check (rondas between 1 and 5),
  segundos     integer not null default 80 check (segundos between 30 and 180),
  orden        uuid[] not null default '{}',
  turno_idx    integer not null default 0,
  vuelta       integer not null default 0,
  dibujante    uuid,
  turno_inicio timestamptz,
  turno_fin    timestamptz,
  pausa_fin    timestamptz,
  trazos       jsonb not null default '[]',
  adivinaron   uuid[] not null default '{}',
  revelada     text,
  mensajes     jsonb not null default '[]',
  ganadores    uuid[] not null default '{}',
  version      integer not null default 0,
  creada       timestamptz not null default now(),
  actualizada  timestamptz not null default now()
);
create index if not exists pin_salas_estado on public.pin_salas (estado, actualizada desc);

create table if not exists public.pin_jugadores (
  sala    uuid not null references public.pin_salas(id) on delete cascade,
  jugador uuid not null references public.profiles(id) on delete cascade,
  puntos  integer not null default 0,
  unido   timestamptz not null default now(),
  primary key (sala, jugador)
);
create index if not exists pin_jugadores_jugador on public.pin_jugadores (jugador);

-- Palabra secreta del turno y palabras ya usadas. Sin políticas: nadie la lee
-- desde la página; solo las funciones de abajo.
create table if not exists public.pin_salas_secreto (
  sala    uuid primary key references public.pin_salas(id) on delete cascade,
  palabra text,
  usadas  text[] not null default '{}'
);

alter table public.pin_salas         enable row level security;
alter table public.pin_jugadores     enable row level security;
alter table public.pin_salas_secreto enable row level security;
revoke all on public.pin_salas         from anon, authenticated;
revoke all on public.pin_jugadores     from anon, authenticated;
revoke all on public.pin_salas_secreto from anon, authenticated;
grant select on public.pin_salas     to authenticated;
grant select on public.pin_jugadores to authenticated;

drop policy if exists pin_salas_ver on public.pin_salas;
create policy pin_salas_ver on public.pin_salas for select to authenticated using (true);
drop policy if exists pin_jugadores_ver on public.pin_jugadores;
create policy pin_jugadores_ver on public.pin_jugadores for select to authenticated using (true);

-- Avisos en tiempo real de la sala (si la publicación existe).
do $rt$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pin_salas') then
    execute 'alter publication supabase_realtime add table public.pin_salas';
  end if;
end $rt$;


-- ---------------------------------------------------------------------
-- 2. Funciones internas
-- ---------------------------------------------------------------------
create or replace function public.pin_palabras()
returns text[] language sql immutable as $fn_pal$
  select array[
    'casa','perro','gato','sol','luna','estrella','árbol','flor','carro','bicicleta','avión','barco','tren',
    'pelota','guitarra','libro','lápiz','mochila','reloj','zapato','camisa','sombrero','lentes','paraguas',
    'teléfono','computadora','televisor','cama','silla','mesa','puerta','ventana','escalera','llave','vela',
    'pastel','pizza','helado','manzana','banano','piña','mango','sandía','uvas','naranja','huevo','pan',
    'queso','taza','cuchara','tenedor','olla','pez','tiburón','ballena','pulpo','tortuga','rana','serpiente',
    'cocodrilo','león','tigre','elefante','jirafa','mono','caballo','vaca','cerdo','gallina','pato','conejo',
    'ratón','oso','pájaro','mariposa','abeja','araña','hormiga','caracol','murciélago','búho','volcán',
    'montaña','playa','río','lago','isla','nube','lluvia','arcoíris','rayo','fuego','hoja','cactus',
    'palmera','hongo','corazón','cohete','robot','fantasma','calabaza','corona','castillo','puente',
    'escuela','hospital','bandera','globo','regalo','campana','tambor','piano','trompeta','micrófono',
    'cámara','ancla','faro','mapa','tijeras','martillo','escoba','cepillo','peine','jabón','toalla',
    'lámpara','ventilador','hamaca','tortilla','nacatamal','gallo pinto','pulpería','balón','bate',
    'guante','portería','dinosaurio','dragón','sirena','pirata','payaso','astronauta','bombero','doctor',
    'maestra','policía','cangrejo','pingüino','camello','canguro','zorro','lobo','burro','loro','girasol',
    'semáforo','carretera','autobús','moto','helicóptero','submarino','tractor','ambulancia','planeta',
    'telescopio','imán','batería','bombilla','candado','espada','escudo','flecha','arco','trofeo','medalla',
    'pizarra','mochila escolar','cuaderno','borrador','regla','calculadora','globo terráqueo','sacapuntas'
  ]::text[];
$fn_pal$;

create or replace function public.pin_norm(p text)
returns text language sql immutable as $fn_norm$
  select regexp_replace(trim(translate(lower(coalesce(p, '')), 'áéíóúüñàèìòù', 'aeiouunaeiou')), '\s+', ' ', 'g');
$fn_norm$;

-- Pista: guiones bajos con algunas letras reveladas según el tiempo transcurrido.
create or replace function public.pin_pista(p_palabra text, p_frac numeric)
returns text language plpgsql immutable as $fn_pista$
declare
  v_letras  integer;
  v_mostrar integer := 0;
  v_pos     integer[];
  v_res     text := '';
  i         integer;
begin
  if p_palabra is null then return null; end if;
  v_letras := char_length(replace(p_palabra, ' ', ''));
  if p_frac >= 0.5 then v_mostrar := 1; end if;
  if p_frac >= 0.75 then v_mostrar := 2; end if;
  v_mostrar := least(v_mostrar, greatest(0, v_letras / 3));
  select array_agg(n order by md5(p_palabra || n::text)) into v_pos
    from generate_series(1, char_length(p_palabra)) n
   where substr(p_palabra, n, 1) <> ' ';
  for i in 1 .. char_length(p_palabra) loop
    if substr(p_palabra, i, 1) = ' ' then
      v_res := v_res || ' ';
    elsif v_mostrar > 0 and i = any (v_pos[1:v_mostrar]) then
      v_res := v_res || substr(p_palabra, i, 1);
    else
      v_res := v_res || '_';
    end if;
  end loop;
  return v_res;
end;
$fn_pista$;

create or replace function public.pin_mensaje(p_msgs jsonb, p_tipo text, p_de uuid, p_texto text)
returns jsonb language sql immutable as $fn_msg$
  select coalesce((
    select jsonb_agg(m order by n)
      from (select m, n from jsonb_array_elements(
              coalesce(p_msgs, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
                't', p_tipo, 'de', p_de, 'x', left(coalesce(p_texto, ''), 80), 'h', now())))
              with ordinality as e(m, n)
            order by n desc limit 40) ultimos
  ), '[]'::jsonb);
$fn_msg$;

-- Empieza el turno de orden[turno_idx]: palabra nueva al azar.
create or replace function public.pin_iniciar_turno(p_sala uuid)
returns void language plpgsql security definer set search_path = public as $fn_turno$
declare
  v_s       public.pin_salas%rowtype;
  v_usadas  text[];
  v_palabra text;
begin
  select * into v_s from public.pin_salas where id = p_sala;
  select usadas into v_usadas from public.pin_salas_secreto where sala = p_sala;
  select w into v_palabra from unnest(public.pin_palabras()) w
   where not (w = any (coalesce(v_usadas, '{}'))) order by random() limit 1;
  if v_palabra is null then
    v_usadas := '{}';
    select w into v_palabra from unnest(public.pin_palabras()) w order by random() limit 1;
  end if;
  insert into public.pin_salas_secreto (sala, palabra, usadas)
  values (p_sala, v_palabra, array_append(coalesce(v_usadas, '{}'), v_palabra))
  on conflict (sala) do update set palabra = excluded.palabra, usadas = excluded.usadas;
  update public.pin_salas set
    fase = 'dibujando', dibujante = v_s.orden[v_s.turno_idx + 1],
    turno_inicio = now(), turno_fin = now() + make_interval(secs => v_s.segundos), pausa_fin = null,
    trazos = '[]', adivinaron = '{}',
    mensajes = public.pin_mensaje(v_s.mensajes, 'sistema', v_s.orden[v_s.turno_idx + 1], 'dibuja'),
    version = version + 1, actualizada = now()
  where id = p_sala;
end;
$fn_turno$;

-- Termina el turno actual: revela la palabra y abre una pausa de 5 s.
create or replace function public.pin_terminar_turno(p_sala uuid)
returns void language plpgsql security definer set search_path = public as $fn_fin$
declare
  v_palabra text;
begin
  select palabra into v_palabra from public.pin_salas_secreto where sala = p_sala;
  update public.pin_salas set
    fase = 'pausa', revelada = v_palabra, pausa_fin = now() + interval '5 seconds',
    mensajes = public.pin_mensaje(mensajes, 'revela', dibujante, v_palabra),
    version = version + 1, actualizada = now()
  where id = p_sala;
  update public.pin_salas_secreto set palabra = null where sala = p_sala;
end;
$fn_fin$;

-- Pasa al siguiente turno (o termina la partida).
create or replace function public.pin_siguiente(p_sala uuid)
returns void language plpgsql security definer set search_path = public as $fn_sig$
declare
  v_s   public.pin_salas%rowtype;
  v_max integer;
begin
  select * into v_s from public.pin_salas where id = p_sala;
  if coalesce(array_length(v_s.orden, 1), 0) < 2 then
    select max(puntos) into v_max from public.pin_jugadores where sala = p_sala;
    update public.pin_salas set estado = 'terminada', fase = 'fin', dibujante = null,
      ganadores = coalesce((select array_agg(jugador) from public.pin_jugadores where sala = p_sala and puntos = v_max and v_max > 0), '{}'),
      version = version + 1, actualizada = now()
    where id = p_sala;
    return;
  end if;
  if v_s.turno_idx + 1 >= array_length(v_s.orden, 1) then
    if v_s.vuelta >= v_s.rondas then
      select max(puntos) into v_max from public.pin_jugadores where sala = p_sala;
      update public.pin_salas set estado = 'terminada', fase = 'fin', dibujante = null,
        ganadores = coalesce((select array_agg(jugador) from public.pin_jugadores where sala = p_sala and puntos = v_max and v_max > 0), '{}'),
        version = version + 1, actualizada = now()
      where id = p_sala;
      return;
    end if;
    update public.pin_salas set vuelta = vuelta + 1, turno_idx = 0 where id = p_sala;
  else
    update public.pin_salas set turno_idx = turno_idx + 1 where id = p_sala;
  end if;
  perform public.pin_iniciar_turno(p_sala);
end;
$fn_sig$;


-- ---------------------------------------------------------------------
-- 3. Funciones que usa la página
-- ---------------------------------------------------------------------
create or replace function public.pin_sala_crear(p_nombre text, p_rondas integer, p_segundos integer)
returns uuid language plpgsql security definer set search_path = public as $fn_crear$
declare
  v_uid    uuid := auth.uid();
  v_codigo text;
  v_id     uuid;
begin
  if v_uid is null then raise exception 'Inicia sesión.'; end if;
  if (select count(*) from public.pin_salas where anfitrion = v_uid and estado <> 'terminada'
        and actualizada > now() - interval '3 hours') >= 2 then
    raise exception 'Ya tienes salas abiertas. Termina o cierra una antes de crear otra.';
  end if;
  loop
    v_codigo := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 24)::int, 1), '') from generate_series(1, 4));
    exit when not exists (select 1 from public.pin_salas where codigo = v_codigo);
  end loop;
  insert into public.pin_salas (codigo, nombre, anfitrion, rondas, segundos)
  values (v_codigo, coalesce(nullif(left(trim(p_nombre), 40), ''), 'Sala de Pinturillo'), v_uid,
          least(greatest(coalesce(p_rondas, 2), 1), 5), least(greatest(coalesce(p_segundos, 80), 30), 180))
  returning id into v_id;
  insert into public.pin_jugadores (sala, jugador) values (v_id, v_uid);
  insert into public.pin_salas_secreto (sala) values (v_id);
  return v_id;
end;
$fn_crear$;

create or replace function public.pin_sala_unirse(p_codigo text)
returns uuid language plpgsql security definer set search_path = public as $fn_unir$
declare
  v_uid uuid := auth.uid();
  v_s   public.pin_salas%rowtype;
begin
  if v_uid is null then raise exception 'Inicia sesión.'; end if;
  select * into v_s from public.pin_salas where codigo = upper(trim(p_codigo)) for update;
  if not found or v_s.estado = 'terminada' then raise exception 'No hay ninguna sala abierta con ese código.'; end if;
  if exists (select 1 from public.pin_jugadores where sala = v_s.id and jugador = v_uid) then return v_s.id; end if;
  if (select count(*) from public.pin_jugadores where sala = v_s.id) >= 12 then
    raise exception 'La sala está llena (máximo 12 jugadores). Puedes entrar a mirar.';
  end if;
  insert into public.pin_jugadores (sala, jugador) values (v_s.id, v_uid);
  update public.pin_salas set
    orden = case when estado = 'jugando' then array_append(orden, v_uid) else orden end,
    mensajes = public.pin_mensaje(mensajes, 'entra', v_uid, ''),
    version = version + 1, actualizada = now()
  where id = v_s.id;
  return v_s.id;
end;
$fn_unir$;

create or replace function public.pin_sala_salir(p_sala uuid)
returns void language plpgsql security definer set search_path = public as $fn_salir$
declare
  v_uid uuid := auth.uid();
  v_s   public.pin_salas%rowtype;
  v_pos integer;
begin
  select * into v_s from public.pin_salas where id = p_sala for update;
  if not found then return; end if;
  delete from public.pin_jugadores where sala = p_sala and jugador = v_uid;
  if not found then return; end if;
  if not exists (select 1 from public.pin_jugadores where sala = p_sala) then
    delete from public.pin_salas where id = p_sala;
    return;
  end if;
  if v_s.anfitrion = v_uid then
    update public.pin_salas set anfitrion = (select jugador from public.pin_jugadores where sala = p_sala order by unido limit 1)
    where id = p_sala;
  end if;
  update public.pin_salas set mensajes = public.pin_mensaje(mensajes, 'sale', v_uid, ''),
    version = version + 1, actualizada = now() where id = p_sala;
  if v_s.estado <> 'jugando' then return; end if;
  v_pos := array_position(v_s.orden, v_uid);
  if v_pos is not null then
    update public.pin_salas set orden = array_remove(orden, v_uid),
      turno_idx = case when v_pos - 1 < turno_idx then turno_idx - 1 else turno_idx end
    where id = p_sala;
  end if;
  if (select coalesce(array_length(orden, 1), 0) from public.pin_salas where id = p_sala) < 2 then
    perform public.pin_siguiente(p_sala);   -- termina la partida
  elsif v_s.dibujante = v_uid and v_s.fase = 'dibujando' then
    -- Se fue quien dibujaba: se revela la palabra y, tras la pausa, sigue
    -- quien ocupaba el lugar siguiente (por eso se retrocede un puesto).
    update public.pin_salas set turno_idx = turno_idx - 1 where id = p_sala;
    perform public.pin_terminar_turno(p_sala);
  end if;
end;
$fn_salir$;

create or replace function public.pin_sala_empezar(p_sala uuid)
returns void language plpgsql security definer set search_path = public as $fn_empezar$
declare
  v_s public.pin_salas%rowtype;
begin
  select * into v_s from public.pin_salas where id = p_sala for update;
  if not found then raise exception 'La sala no existe.'; end if;
  if v_s.anfitrion <> auth.uid() then raise exception 'Solo quien creó la sala puede empezar.'; end if;
  if v_s.estado <> 'espera' then raise exception 'La partida ya empezó.'; end if;
  if (select count(*) from public.pin_jugadores where sala = p_sala) < 2 then
    raise exception 'Se necesitan al menos 2 jugadores.';
  end if;
  update public.pin_jugadores set puntos = 0 where sala = p_sala;
  update public.pin_salas set estado = 'jugando', vuelta = 1, turno_idx = 0,
    orden = (select array_agg(jugador order by random()) from public.pin_jugadores where sala = p_sala),
    mensajes = '[]'
  where id = p_sala;
  perform public.pin_iniciar_turno(p_sala);
end;
$fn_empezar$;

-- Avanza el reloj: termina el turno vencido o empieza el siguiente tras la pausa.
-- Cualquiera puede llamarla; solo actúa si de verdad toca.
create or replace function public.pin_sala_avanzar(p_sala uuid)
returns void language plpgsql security definer set search_path = public as $fn_avanzar$
declare
  v_s public.pin_salas%rowtype;
begin
  select * into v_s from public.pin_salas where id = p_sala for update;
  if not found or v_s.estado <> 'jugando' then return; end if;
  if v_s.fase = 'dibujando' and now() >= v_s.turno_fin then
    perform public.pin_terminar_turno(p_sala);
  elsif v_s.fase = 'pausa' and now() >= v_s.pausa_fin then
    perform public.pin_siguiente(p_sala);
  end if;
end;
$fn_avanzar$;

create or replace function public.pin_sala_trazo(p_sala uuid, p_trazo jsonb)
returns integer language plpgsql security definer set search_path = public as $fn_trazo$
declare
  v_s public.pin_salas%rowtype;
begin
  select * into v_s from public.pin_salas where id = p_sala for update;
  if not found or v_s.fase <> 'dibujando' or v_s.dibujante <> auth.uid() or now() > v_s.turno_fin then
    raise exception 'No es tu turno de dibujar.';
  end if;
  if jsonb_typeof(p_trazo) <> 'object' or pg_column_size(p_trazo) > 40000 then
    raise exception 'Trazo no válido.';
  end if;
  if coalesce((p_trazo->>'clear')::boolean, false) then
    update public.pin_salas set trazos = '[]', version = version + 1, actualizada = now() where id = p_sala;
  else
    if jsonb_array_length(v_s.trazos) >= 600 or pg_column_size(v_s.trazos) > 900000 then
      raise exception 'La pizarra está llena: bórrala para seguir dibujando.';
    end if;
    update public.pin_salas set trazos = trazos || jsonb_build_array(p_trazo), version = version + 1, actualizada = now()
    where id = p_sala;
  end if;
  return v_s.version + 1;
end;
$fn_trazo$;

create or replace function public.pin_sala_adivinar(p_sala uuid, p_texto text)
returns jsonb language plpgsql security definer set search_path = public as $fn_adivinar$
declare
  v_uid     uuid := auth.uid();
  v_s       public.pin_salas%rowtype;
  v_palabra text;
  v_total   numeric;
  v_resta   numeric;
  v_puntos  integer;
  v_texto   text := left(trim(coalesce(p_texto, '')), 60);
begin
  select * into v_s from public.pin_salas where id = p_sala for update;
  if not found or v_s.fase <> 'dibujando' then raise exception 'Ahora no se puede adivinar.'; end if;
  if not exists (select 1 from public.pin_jugadores where sala = p_sala and jugador = v_uid) then
    raise exception 'Estás mirando: solo los jugadores adivinan.';
  end if;
  if v_s.dibujante = v_uid then raise exception 'Tú estás dibujando.'; end if;
  if v_uid = any (v_s.adivinaron) then raise exception 'Ya adivinaste esta palabra.'; end if;
  if v_texto = '' then return jsonb_build_object('correcto', false); end if;
  select palabra into v_palabra from public.pin_salas_secreto where sala = p_sala;

  if public.pin_norm(v_texto) = public.pin_norm(v_palabra) then
    v_total := extract(epoch from (v_s.turno_fin - v_s.turno_inicio));
    v_resta := greatest(0, extract(epoch from (v_s.turno_fin - now())));
    v_puntos := 50 + round(50 * v_resta / greatest(v_total, 1))::integer
                + case when coalesce(array_length(v_s.adivinaron, 1), 0) = 0 then 20 else 0 end;
    update public.pin_jugadores set puntos = puntos + v_puntos where sala = p_sala and jugador = v_uid;
    update public.pin_jugadores set puntos = puntos + 20 where sala = p_sala and jugador = v_s.dibujante;
    update public.pin_salas set adivinaron = array_append(adivinaron, v_uid),
      mensajes = public.pin_mensaje(mensajes, 'acierto', v_uid, '+' || v_puntos),
      version = version + 1, actualizada = now()
    where id = p_sala;
    -- Si ya adivinaron todos, se termina el turno.
    if (select coalesce(array_length(adivinaron, 1), 0) from public.pin_salas where id = p_sala)
       >= (select count(*) from public.pin_jugadores where sala = p_sala and jugador <> v_s.dibujante) then
      perform public.pin_terminar_turno(p_sala);
    end if;
    return jsonb_build_object('correcto', true, 'puntos', v_puntos);
  end if;
  -- No se muestra un intento que contenga la palabra (evita revelarla por accidente).
  if position(public.pin_norm(v_palabra) in public.pin_norm(v_texto)) = 0 then
    update public.pin_salas set mensajes = public.pin_mensaje(mensajes, 'intento', v_uid, v_texto),
      version = version + 1, actualizada = now()
    where id = p_sala;
  end if;
  return jsonb_build_object('correcto', false,
    'cerca', char_length(public.pin_norm(v_texto)) = char_length(public.pin_norm(v_palabra))
             and public.pin_norm(v_texto) <> public.pin_norm(v_palabra)
             and left(public.pin_norm(v_texto), 2) = left(public.pin_norm(v_palabra), 2));
end;
$fn_adivinar$;

-- Quien dibuja puede saltar su turno (se revela la palabra).
create or replace function public.pin_sala_saltar(p_sala uuid)
returns void language plpgsql security definer set search_path = public as $fn_saltar$
declare
  v_s public.pin_salas%rowtype;
begin
  select * into v_s from public.pin_salas where id = p_sala for update;
  if not found or v_s.fase <> 'dibujando' or v_s.dibujante <> auth.uid() then
    raise exception 'No es tu turno.';
  end if;
  perform public.pin_terminar_turno(p_sala);
end;
$fn_saltar$;

-- Estado de la sala. La palabra solo la recibe quien dibuja.
create or replace function public.pin_sala_estado(p_sala uuid)
returns jsonb language plpgsql security definer set search_path = public as $fn_estado$
declare
  v_uid     uuid := auth.uid();
  v_s       public.pin_salas%rowtype;
  v_palabra text;
  v_frac    numeric := 0;
begin
  if v_uid is null then raise exception 'Inicia sesión.'; end if;
  select * into v_s from public.pin_salas where id = p_sala;
  if not found then raise exception 'La sala ya no existe.'; end if;
  select palabra into v_palabra from public.pin_salas_secreto where sala = p_sala;
  if v_s.fase = 'dibujando' and v_s.turno_fin > v_s.turno_inicio then
    v_frac := least(1, greatest(0, extract(epoch from (now() - v_s.turno_inicio)) / extract(epoch from (v_s.turno_fin - v_s.turno_inicio))));
  end if;
  return jsonb_build_object(
    'ahora', now(),
    'sala', to_jsonb(v_s),
    'jugadores', coalesce((select jsonb_agg(jsonb_build_object('id', jugador, 'puntos', puntos) order by puntos desc, unido)
                             from public.pin_jugadores where sala = p_sala), '[]'::jsonb),
    'soy_jugador', exists (select 1 from public.pin_jugadores where sala = p_sala and jugador = v_uid),
    'soy_dibujante', v_s.fase = 'dibujando' and v_s.dibujante = v_uid,
    'ya_adivine', v_uid = any (v_s.adivinaron),
    'palabra', case when v_s.fase = 'dibujando' and v_s.dibujante = v_uid then v_palabra end,
    'pista', case when v_s.fase = 'dibujando' then public.pin_pista(v_palabra, v_frac) end
  );
end;
$fn_estado$;


-- ---------------------------------------------------------------------
-- 4. Permisos
-- ---------------------------------------------------------------------
revoke all on function public.pin_iniciar_turno(uuid)  from public, anon, authenticated;
revoke all on function public.pin_terminar_turno(uuid) from public, anon, authenticated;
revoke all on function public.pin_siguiente(uuid)      from public, anon, authenticated;
revoke all on function public.pin_sala_crear(text, integer, integer) from public, anon;
revoke all on function public.pin_sala_unirse(text)            from public, anon;
revoke all on function public.pin_sala_salir(uuid)             from public, anon;
revoke all on function public.pin_sala_empezar(uuid)           from public, anon;
revoke all on function public.pin_sala_avanzar(uuid)           from public, anon;
revoke all on function public.pin_sala_trazo(uuid, jsonb)      from public, anon;
revoke all on function public.pin_sala_adivinar(uuid, text)    from public, anon;
revoke all on function public.pin_sala_saltar(uuid)            from public, anon;
revoke all on function public.pin_sala_estado(uuid)            from public, anon;
grant execute on function public.pin_sala_crear(text, integer, integer) to authenticated;
grant execute on function public.pin_sala_unirse(text)         to authenticated;
grant execute on function public.pin_sala_salir(uuid)          to authenticated;
grant execute on function public.pin_sala_empezar(uuid)        to authenticated;
grant execute on function public.pin_sala_avanzar(uuid)        to authenticated;
grant execute on function public.pin_sala_trazo(uuid, jsonb)   to authenticated;
grant execute on function public.pin_sala_adivinar(uuid, text) to authenticated;
grant execute on function public.pin_sala_saltar(uuid)         to authenticated;
grant execute on function public.pin_sala_estado(uuid)         to authenticated;

select 'Pinturillo en salas activado' as resultado;
