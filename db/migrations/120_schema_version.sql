-- =====================================================================
-- Chasqui Pet — 120_schema_version.sql
-- Ámbito: NÚCLEO (convención de cabecera, Fase A7a del plan de
-- consolidación).
--
-- Registro de migraciones aplicadas (Fase A1 del plan de consolidación).
--
-- El problema que resuelve: la imagen de Postgres ejecuta
-- /docker-entrypoint-initdb.d una sola vez, cuando el volumen `pgdata`
-- está vacío. En una base ya inicializada, una migración nueva no se
-- aplica sola y NO HAY FORMA de saber cuáles corrieron: hay que
-- adivinar mirando `pg_proc`. Eso ya produjo una dependencia de orden
-- estricta (079 → 081 → 082 → 083) sin red de seguridad.
--
-- La tabla es el registro; quien lo escribe son dos caminos que deben
-- converger:
--   · instalación limpia → `910_registrar_versiones.sh` siembra aquí
--     todo lo que initdb acaba de aplicar;
--   · base viva          → `scripts/migrar.sh` aplica y registra lo que
--     falte, o retro-registra lo ya aplicado sin ejecutarlo.
--
-- Se guarda el `hash` del archivo, no por paranoia sino porque la regla
-- del proyecto es que una migración aplicada NO SE EDITA (ver CLAUDE.md
-- → Database). Si el hash cambia, el archivo se tocó después de correr:
-- el migrador debe fallar ruidosamente en vez de seguir como si nada.
--
-- Esta tabla es infraestructura, no negocio: no se audita con
-- `auditar()` (la auditoría es de actos de usuario) y la aplicación no
-- escribe en ella (ver los REVOKE del final).
-- =====================================================================

SET client_min_messages = warning;

CREATE TABLE IF NOT EXISTS schema_version (
  -- Prefijo numérico del archivo ('010', '079', '120'). Es la clave
  -- porque el prefijo es lo que ordena la ejecución y lo que el
  -- proyecto trata como identidad de la migración; el nombre completo
  -- queda como dato legible.
  version     text PRIMARY KEY,
  nombre      text NOT NULL,
  hash        text NOT NULL,
  aplicada_at timestamptz NOT NULL DEFAULT now(),
  -- De dónde salió el registro. Distinguirlo importa: 'retro' significa
  -- «se dio por aplicada sin ejecutarla», y eso es exactamente lo que
  -- hay que poder auditar el día que algo no cuadre en la base viva.
  origen      text NOT NULL DEFAULT 'migrar'
              CHECK (origen IN ('initdb', 'migrar', 'retro'))
);

COMMENT ON TABLE  schema_version IS
  'Migraciones de db/migrations aplicadas a esta base. Lo escriben 910_registrar_versiones.sh y scripts/migrar.sh.';
COMMENT ON COLUMN schema_version.version IS 'Prefijo de tres dígitos del archivo de migración.';
COMMENT ON COLUMN schema_version.hash   IS 'sha256 del archivo al momento de aplicarlo; si cambia, el archivo se editó después.';
COMMENT ON COLUMN schema_version.origen IS 'initdb = primer arranque; migrar = aplicada por scripts/migrar.sh; retro = dada por aplicada sin ejecutar.';

-- ---------------------------------------------------------------------
-- registrar_version — anota una migración como aplicada.
--
-- Idempotente por diseño: volver a registrar la misma versión con el
-- mismo hash no hace nada y devuelve ok. Registrarla con OTRO hash es
-- un error duro, no un aviso: significa que el archivo cambió después
-- de correr y nadie puede saber qué quedó realmente en la base.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION registrar_version(
  p_version text,
  p_nombre  text,
  p_hash    text,
  p_origen  text DEFAULT 'migrar'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_hash_previo text;
BEGIN
  SELECT hash INTO v_hash_previo FROM schema_version WHERE version = p_version;

  IF v_hash_previo IS NULL THEN
    INSERT INTO schema_version (version, nombre, hash, origen)
    VALUES (p_version, p_nombre, p_hash, p_origen);
    RETURN jsonb_build_object('ok', true, 'estado', 'registrada', 'version', p_version);
  END IF;

  IF v_hash_previo <> p_hash THEN
    RAISE EXCEPTION
      'La migración % ya está registrada con otro contenido (hash aplicado %, hash actual %). Las migraciones aplicadas no se editan: cree una migración nueva.',
      p_version, left(v_hash_previo, 12), left(p_hash, 12)
      USING ERRCODE = 'raise_exception';
  END IF;

  RETURN jsonb_build_object('ok', true, 'estado', 'ya_registrada', 'version', p_version);
END;
$$;

-- ---------------------------------------------------------------------
-- schema_version_estado — qué hacer con un archivo concreto.
--
-- La decisión vive en SQL y no en el script de shell (regla C6.12: la
-- lógica en la base). El migrador se limita a leer la respuesta:
--   'pendiente'  → hay que aplicarlo
--   'aplicada'   → saltarlo
--   'modificada' → detenerse: el archivo cambió después de aplicarse
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION schema_version_estado(p_version text, p_hash text)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT CASE WHEN sv.hash = p_hash THEN 'aplicada' ELSE 'modificada' END
       FROM schema_version sv WHERE sv.version = p_version),
    'pendiente');
$$;

-- ---------------------------------------------------------------------
-- Permisos. `090_grants.sql` dejó privilegios por defecto que darían
-- DML completo a chasquipet_app sobre cualquier tabla nueva. El
-- registro de versiones no lo escribe la aplicación: lo escriben el
-- entrypoint de initdb y el migrador, ambos como dueño de la base.
-- Se deja SELECT para poder diagnosticar desde la app sin abrir nada.
-- ---------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON schema_version FROM chasquipet_app;
REVOKE EXECUTE ON FUNCTION registrar_version(text, text, text, text) FROM chasquipet_app;
