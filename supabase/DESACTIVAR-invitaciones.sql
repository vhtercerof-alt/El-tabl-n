-- =====================================================================
-- EL TABLÓN · QUITAR los códigos de invitación
-- =====================================================================
-- Vuelve a permitir crear cuentas SIN código (como era antes).
-- Iniciar sesión nunca necesitó código; esto afecta solo al registro.
--
-- Cómo ejecutarlo: Supabase → SQL Editor → New query (pestaña vacía) →
-- pega TODO este archivo sin seleccionar nada → Run.
-- Se puede ejecutar varias veces sin problema.
-- =====================================================================

drop trigger if exists tb_validar_invitacion on auth.users;
drop function if exists public.tb_validar_invitacion();
drop function if exists public.tb_invitacion_requerida();
drop table if exists public.tb_invitaciones;
drop table if exists public.tb_ajustes;

select 'Códigos de invitación eliminados: ya se puede crear cuenta sin código' as resultado;
