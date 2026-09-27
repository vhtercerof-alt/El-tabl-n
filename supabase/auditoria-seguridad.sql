-- =====================================================================
-- EL TABLÓN · Auditoría de seguridad de Supabase
-- =====================================================================
-- PARTE A: consultas SOLO DE LECTURA. Se pueden ejecutar sin riesgo en
--          el SQL Editor de Supabase. No cambian nada.
-- PARTE B: PLANTILLAS comentadas. NO ejecutar tal cual: los nombres de
--          columnas se tomaron de lo que usa la página, pero sus tipos
--          y el resto del esquema (archivos TABLON-economia-segura.sql,
--          ACTIVAR-buzon-y-vitrina.sql, etc.) no estaban disponibles
--          para esta revisión. Revisar y adaptar antes de usar.
-- =====================================================================


-- ---------------------------------------------------------------------
-- PARTE A.1 · Tablas públicas SIN Row Level Security (RLS)
-- Resultado esperado: ninguna fila. Cualquier tabla que aparezca aquí
-- puede ser leída/modificada por cualquiera que tenga la clave pública.
-- ---------------------------------------------------------------------
select n.nspname as esquema, c.relname as tabla
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r'
  and n.nspname = 'public'
  and not c.relrowsecurity
order by 2;


-- ---------------------------------------------------------------------
-- PARTE A.2 · Todas las políticas RLS, para revisarlas una por una.
-- Buscar políticas con "true" en USING / WITH CHECK para INSERT,
-- UPDATE o DELETE: significan "cualquier usuario puede hacerlo".
-- ---------------------------------------------------------------------
select tablename, policyname, cmd, roles, qual as using_, with_check
from pg_policies
where schemaname = 'public'
order by tablename, cmd;


-- ---------------------------------------------------------------------
-- PARTE A.3 · Permisos de columna de "profiles" para usuarios normales.
-- Si 'authenticated' tiene UPDATE sobre role, belis, level, cards,
-- banners, motions, avatars, borders, last_spin*, etc., un estudiante
-- puede darse a sí mismo rol owner, monedas o premios desde la consola
-- del navegador, aunque la página no lo muestre.
-- ---------------------------------------------------------------------
select grantee, privilege_type, column_name
from information_schema.column_privileges
where table_schema = 'public'
  and table_name = 'profiles'
  and grantee in ('anon', 'authenticated')
  and privilege_type in ('UPDATE', 'INSERT')
order by grantee, privilege_type, column_name;

-- Permisos a nivel de tabla (si aparece UPDATE aquí, aplica a TODAS las columnas)
select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and grantee in ('anon', 'authenticated')
order by table_name, grantee, privilege_type;


-- ---------------------------------------------------------------------
-- PARTE A.4 · Funciones SECURITY DEFINER (se ejecutan con permisos de
-- administrador). Cada una debe comprobar quién la llama. Revisar que
-- las funciones owner_* comprueben que auth.uid() tiene rol 'owner'
-- y que fijen search_path.
-- ---------------------------------------------------------------------
select p.proname as funcion,
       p.prosecdef as security_definer,
       p.proconfig as configuracion,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_puede_ejecutar
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
order by 1;

-- Funciones owner_* cuyo código NO menciona auth.uid() (sospechosas)
select p.proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like 'owner\_%'
  and pg_get_functiondef(p.oid) not ilike '%auth.uid()%';


-- ---------------------------------------------------------------------
-- PARTE A.5 · Buckets de Storage y sus políticas.
-- 'prensa' y 'MASCOTA-AUDIO' son públicos para lectura (esperado), pero
-- la SUBIDA solo debería permitirse a owner/admin.
-- ---------------------------------------------------------------------
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets;

select policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'storage' and tablename = 'objects';


-- ---------------------------------------------------------------------
-- PARTE A.6 · ¿El alta de usuarios copia el "rol" desde los metadatos?
-- La página envía username, display_name y bio al registrarse. Si el
-- trigger de alta leyera raw_user_meta_data->>'role', cualquiera podría
-- registrarse como owner. Revisar el código que devuelve esta consulta.
-- ---------------------------------------------------------------------
select tgname, pg_get_triggerdef(t.oid)
from pg_trigger t
where t.tgrelid = 'auth.users'::regclass and not t.tgisinternal;


-- =====================================================================
-- PARTE B · PLANTILLAS (comentadas). Revisar tipos y nombres antes.
-- =====================================================================

-- B.1 · Limitar qué columnas de su propio perfil puede cambiar un usuario.
-- La página solo necesita escribir directamente: theme, light_mode, bio,
-- arcade, terms_accepted_at y las columnas "equipadas" (card, banner,
-- motion, avatar, border). Todo lo demás debe pasar por funciones RPC.
--
-- revoke update on public.profiles from anon, authenticated;
-- grant update (theme, light_mode, bio, arcade, terms_accepted_at,
--               card, banner, motion, avatar, border)
--   on public.profiles to authenticated;
-- -- y la política RLS de UPDATE debe ser: using (id = auth.uid())
-- --                                     with check (id = auth.uid())

-- B.2 · Impedir equipar objetos que el usuario no tiene.
-- (Suponiendo que cards/banners/motions/avatars/borders son text[];
--  si son jsonb, cambiar "= any(...)" por el operador "?".)
--
-- create or replace function public.tb_validar_equipado()
-- returns trigger language plpgsql as $$
-- begin
--   if new.card   is distinct from old.card   and new.card   is not null and not (new.card   = any(coalesce(new.cards,   '{}'))) then raise exception 'Tarjeta no desbloqueada'; end if;
--   if new.banner is distinct from old.banner and new.banner is not null and not (new.banner = any(coalesce(new.banners, '{}'))) then raise exception 'Banner no desbloqueado'; end if;
--   if new.motion is distinct from old.motion and new.motion is not null and not (new.motion = any(coalesce(new.motions, '{}'))) then raise exception 'Banner animado no desbloqueado'; end if;
--   if new.avatar is distinct from old.avatar and new.avatar is not null and not (new.avatar = any(coalesce(new.avatars, '{}'))) then raise exception 'Foto no desbloqueada'; end if;
--   if new.border is distinct from old.border and new.border is not null and not (new.border = any(coalesce(new.borders, '{}'))) then raise exception 'Contorno no desbloqueado'; end if;
--   return new;
-- end $$;
-- create trigger tb_validar_equipado before update on public.profiles
--   for each row execute function public.tb_validar_equipado();
-- (El owner puede usar objetos sin tenerlos: añadir una excepción para su rol.)

-- B.3 · Contador de vistas de noticias sin dar permiso de editar "prensa".
-- Hoy la página hace UPDATE prensa SET vistas = ... desde el navegador,
-- lo que exige que cualquier usuario pueda editar la tabla "prensa".
--
-- create or replace function public.tb_sumar_vista_prensa(p_id bigint)
-- returns void language sql security definer set search_path = public as $$
--   update public.prensa set vistas = coalesce(vistas, 0) + 1 where id = p_id;
-- $$;
-- revoke all on function public.tb_sumar_vista_prensa(bigint) from anon;
-- grant execute on function public.tb_sumar_vista_prensa(bigint) to authenticated;
-- -- Después: quitar el permiso de UPDATE sobre prensa a estudiantes y
-- -- cambiar registrarVistaPrensa() en la página para usar client.rpc(...).

-- B.4 · Memes: un estudiante no debe poder publicar un meme ya "aprobado".
-- La política de INSERT de memes debería ser, para no-staff:
--   with check (autor_id = auth.uid() and aprobado = false)
-- y solo owner/admin deben poder hacer UPDATE/DELETE.
-- Además conviene validar el formato de la imagen:
--   check (imagen ~ '^data:image/(png|jpeg|webp|gif);base64,[A-Za-z0-9+/=]+$'
--          and length(imagen) < 3000000)
