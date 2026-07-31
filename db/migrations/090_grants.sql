-- =====================================================================
-- Chasqui Pet — 090_grants.sql
-- Roles de base de datos y append-only real (§2.2.8).
--
-- La aplicación (n8n, worker, portal) se conecta como `chasquipet_app`,
-- que NO es superusuario ni dueño de las tablas. Sobre movimiento_inventario
-- y evento_auditoria no tiene UPDATE ni DELETE: la corrección se hace con
-- un movimiento inverso, no editando el original. Que la app no pueda
-- borrar la auditoría es lo que hace que la auditoría sirva de algo.
-- =====================================================================

SET client_min_messages = warning;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chasquipet_app') THEN
    -- La contraseña se fija desde docker-compose (ver .env). Aquí sólo el rol.
    CREATE ROLE chasquipet_app LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chasquipet_lectura') THEN
    CREATE ROLE chasquipet_lectura LOGIN;   -- reportes / BI, sólo lectura
  END IF;
END $$;

DO $$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO chasquipet_app, chasquipet_lectura',
                 current_database());
END $$;

GRANT USAGE ON SCHEMA public TO chasquipet_app, chasquipet_lectura;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO chasquipet_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO chasquipet_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO chasquipet_app;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO chasquipet_lectura;

-- ---------------------------------------------------------------------
-- Append-only: sólo INSERT y SELECT. Sin UPDATE, sin DELETE, sin TRUNCATE.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t text;
  -- Tablas inmutables por diseño. Se listan todas; las que aún no existen
  -- en esta etapa del proyecto se ignoran sin fallar.
  tablas text[] := ARRAY['evento_auditoria', 'movimiento_inventario'];
BEGIN
  FOREACH t IN ARRAY tablas LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON %I FROM chasquipet_app', t);
      EXECUTE format('GRANT SELECT, INSERT ON %I TO chasquipet_app', t);
      EXECUTE format('REVOKE ALL ON %I FROM chasquipet_lectura', t);
      EXECUTE format('GRANT SELECT ON %I TO chasquipet_lectura', t);
    END IF;
  END LOOP;
END $$;

-- El registro de updates de Telegram sí se actualiza (marcar procesado),
-- pero nunca se borra desde la app: la retención la maneja un job.
REVOKE DELETE, TRUNCATE ON telegram_update FROM chasquipet_app;

-- Las funciones que auditan o insertan movimientos corren como SECURITY
-- DEFINER cuando necesitan más privilegio que el llamador. `auditar` es el
-- caso claro: la app no puede escribir directo pero sí a través de ella.
ALTER FUNCTION auditar(text, text, text, uuid, text, jsonb, jsonb, text) SECURITY DEFINER;

-- Nuevas tablas y funciones creadas después heredan estos permisos.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO chasquipet_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO chasquipet_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO chasquipet_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO chasquipet_lectura;
