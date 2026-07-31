-- =====================================================================
-- Chasqui Pet — 010_base.sql
-- Extensiones, utilidades, configuración del sistema, sedes y auditoría.
-- =====================================================================

SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- búsqueda tolerante a errores de tipeo
CREATE EXTENSION IF NOT EXISTS unaccent;   -- búsqueda sin tildes

-- Toda fecha "de negocio" (día operativo, corte de caja, numeración de
-- turnos) se calcula en America/Bogota. Los timestamptz se guardan en UTC.
CREATE OR REPLACE FUNCTION hoy_bogota() RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE 'America/Bogota')::date;
$$;

CREATE OR REPLACE FUNCTION ahora_bogota() RETURNS timestamp
LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE 'America/Bogota');
$$;

-- Normaliza texto para búsqueda: sin tildes, minúsculas, sin espacios extra.
CREATE OR REPLACE FUNCTION normalizar(txt text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT lower(unaccent('unaccent', regexp_replace(trim(txt), '\s+', ' ', 'g')));
$$;

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- Configuración del sistema (§11.2: editable desde el portal)
-- ---------------------------------------------------------------------
CREATE TABLE config (
  clave        text PRIMARY KEY,
  valor        text NOT NULL,
  tipo         text NOT NULL DEFAULT 'texto'
                 CHECK (tipo IN ('texto','entero','decimal','booleano','json')),
  descripcion  text NOT NULL,
  editable_ui  boolean NOT NULL DEFAULT true,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER config_touch BEFORE UPDATE ON config
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE FUNCTION config_int(p_clave text, p_default int DEFAULT NULL)
RETURNS int LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT valor::int FROM config WHERE clave = p_clave), p_default);
$$;

CREATE OR REPLACE FUNCTION config_txt(p_clave text, p_default text DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT valor FROM config WHERE clave = p_clave), p_default);
$$;

CREATE OR REPLACE FUNCTION config_bool(p_clave text, p_default boolean DEFAULT false)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT valor::boolean FROM config WHERE clave = p_clave), p_default);
$$;

-- ---------------------------------------------------------------------
-- Sede y consultorios
-- ---------------------------------------------------------------------
CREATE TABLE sede (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre      text NOT NULL,
  direccion   text,
  telefono    text,
  ciudad      text NOT NULL DEFAULT 'Bogotá',
  activa      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER sede_touch BEFORE UPDATE ON sede
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE consultorio (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sede_id     uuid NOT NULL REFERENCES sede(id),
  nombre      text NOT NULL,
  orden       int  NOT NULL DEFAULT 0,
  activo      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sede_id, nombre)
);

CREATE TRIGGER consultorio_touch BEFORE UPDATE ON consultorio
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ---------------------------------------------------------------------
-- Auditoría — append-only (§2.2.8). Los REVOKE están en 090_grants.sql
-- ---------------------------------------------------------------------
CREATE TABLE evento_auditoria (
  id           bigserial PRIMARY KEY,
  entidad      text NOT NULL,          -- 'turno', 'lote', 'cuenta', ...
  entidad_id   text,                   -- texto: hay PK uuid y bigint
  accion       text NOT NULL,          -- 'crear','llamar','confirmar_pago', ...
  usuario_id   uuid,                   -- FK lógica; sin REFERENCES para no bloquear borrados de demo
  canal        text NOT NULL DEFAULT 'sistema'
                 CHECK (canal IN ('telegram','web','sistema','job')),
  datos_antes  jsonb,
  datos_despues jsonb,
  detalle      text,
  ip           inet,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_auditoria_entidad ON evento_auditoria (entidad, entidad_id, created_at DESC);
CREATE INDEX idx_auditoria_usuario ON evento_auditoria (usuario_id, created_at DESC);
CREATE INDEX idx_auditoria_fecha   ON evento_auditoria (created_at DESC);

CREATE OR REPLACE FUNCTION auditar(
  p_entidad text,
  p_entidad_id text,
  p_accion text,
  p_usuario_id uuid DEFAULT NULL,
  p_canal text DEFAULT 'sistema',
  p_antes jsonb DEFAULT NULL,
  p_despues jsonb DEFAULT NULL,
  p_detalle text DEFAULT NULL
) RETURNS bigint
LANGUAGE sql AS $$
  INSERT INTO evento_auditoria
    (entidad, entidad_id, accion, usuario_id, canal, datos_antes, datos_despues, detalle)
  VALUES
    (p_entidad, p_entidad_id, p_accion, p_usuario_id, p_canal, p_antes, p_despues, p_detalle)
  RETURNING id;
$$;

-- ---------------------------------------------------------------------
-- Idempotencia del webhook de Telegram (§2.2.2)
-- Telegram reintenta los updates. Sin esta tabla se duplican turnos y
-- movimientos de inventario.
-- ---------------------------------------------------------------------
CREATE TABLE telegram_update (
  update_id       bigint PRIMARY KEY,
  telegram_user_id bigint,
  chat_id         bigint,
  tipo            text,
  payload         jsonb NOT NULL,
  procesado       boolean NOT NULL DEFAULT false,
  error           text,
  recibido_at     timestamptz NOT NULL DEFAULT now(),
  procesado_at    timestamptz
);

CREATE INDEX idx_telegram_update_fecha ON telegram_update (recibido_at DESC);

-- Devuelve true si el update es nuevo (hay que procesarlo);
-- false si ya se había recibido (descartar sin procesar).
CREATE OR REPLACE FUNCTION registrar_update_telegram(p_payload jsonb)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
  v_update_id bigint := (p_payload->>'update_id')::bigint;
  v_msg       jsonb  := COALESCE(p_payload->'message',
                                 p_payload->'edited_message',
                                 p_payload->'callback_query');
  v_tipo      text;
BEGIN
  IF v_update_id IS NULL THEN
    RAISE EXCEPTION 'update_id ausente en el payload de Telegram';
  END IF;

  v_tipo := CASE
              WHEN p_payload ? 'callback_query' THEN 'callback_query'
              WHEN p_payload ? 'message'        THEN 'message'
              WHEN p_payload ? 'edited_message' THEN 'edited_message'
              ELSE 'otro'
            END;

  INSERT INTO telegram_update (update_id, telegram_user_id, chat_id, tipo, payload)
  VALUES (
    v_update_id,
    (v_msg->'from'->>'id')::bigint,
    COALESCE((v_msg->'chat'->>'id')::bigint,
             (v_msg->'message'->'chat'->>'id')::bigint),
    v_tipo,
    p_payload
  )
  ON CONFLICT (update_id) DO NOTHING;

  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION marcar_update_procesado(p_update_id bigint, p_error text DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
  UPDATE telegram_update
     SET procesado = (p_error IS NULL),
         error = p_error,
         procesado_at = now()
   WHERE update_id = p_update_id;
$$;

-- ---------------------------------------------------------------------
-- Cola de tareas asíncronas (§2.2.3 y §2.2.4)
-- El webhook responde en <1s; todo lo pesado se encola aquí.
-- ---------------------------------------------------------------------
CREATE TABLE tarea_async (
  id                bigserial PRIMARY KEY,
  tipo              text NOT NULL,
  payload           jsonb NOT NULL DEFAULT '{}'::jsonb,
  estado            text NOT NULL DEFAULT 'pendiente'
                      CHECK (estado IN ('pendiente','procesando','completada','fallida')),
  prioridad         int NOT NULL DEFAULT 0,
  intentos          int NOT NULL DEFAULT 0,
  max_intentos      int NOT NULL DEFAULT 5,
  proxima_ejecucion timestamptz NOT NULL DEFAULT now(),
  ultimo_error      text,
  clave_unicidad    text,        -- evita encolar dos veces lo mismo
  resultado         jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  completada_at     timestamptz
);

CREATE TRIGGER tarea_async_touch BEFORE UPDATE ON tarea_async
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_tarea_pendiente ON tarea_async (proxima_ejecucion, prioridad DESC)
  WHERE estado = 'pendiente';
CREATE INDEX idx_tarea_estado ON tarea_async (estado, created_at DESC);
CREATE UNIQUE INDEX idx_tarea_clave_unicidad ON tarea_async (clave_unicidad)
  WHERE clave_unicidad IS NOT NULL AND estado IN ('pendiente','procesando');

CREATE OR REPLACE FUNCTION encolar_tarea(
  p_tipo text,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_prioridad int DEFAULT 0,
  p_clave_unicidad text DEFAULT NULL,
  p_retraso_seg int DEFAULT 0,
  p_max_intentos int DEFAULT 5
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO tarea_async (tipo, payload, prioridad, clave_unicidad, proxima_ejecucion, max_intentos)
  VALUES (p_tipo, p_payload, p_prioridad, p_clave_unicidad,
          now() + make_interval(secs => p_retraso_seg), p_max_intentos)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Reclama tareas para un worker. SKIP LOCKED permite varios workers.
CREATE OR REPLACE FUNCTION reclamar_tareas(p_limite int DEFAULT 10)
RETURNS SETOF tarea_async
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  WITH candidatas AS (
    SELECT id FROM tarea_async
     WHERE estado = 'pendiente' AND proxima_ejecucion <= now()
     ORDER BY prioridad DESC, proxima_ejecucion
     LIMIT p_limite
     FOR UPDATE SKIP LOCKED
  )
  UPDATE tarea_async t
     SET estado = 'procesando', intentos = t.intentos + 1, updated_at = now()
    FROM candidatas c
   WHERE t.id = c.id
  RETURNING t.*;
END;
$$;

CREATE OR REPLACE FUNCTION completar_tarea(p_id bigint, p_resultado jsonb DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
  UPDATE tarea_async
     SET estado = 'completada', resultado = p_resultado,
         completada_at = now(), ultimo_error = NULL
   WHERE id = p_id;
$$;

-- Backoff exponencial: 30s, 60s, 120s, 240s… tope 1 hora.
-- Al agotar intentos pasa a 'fallida' y se notifica al superadmin.
CREATE OR REPLACE FUNCTION fallar_tarea(p_id bigint, p_error text)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v_tarea tarea_async;
  v_espera int;
BEGIN
  SELECT * INTO v_tarea FROM tarea_async WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'inexistente'; END IF;

  IF v_tarea.intentos >= v_tarea.max_intentos THEN
    UPDATE tarea_async
       SET estado = 'fallida', ultimo_error = p_error, completada_at = now()
     WHERE id = p_id;

    PERFORM auditar('tarea_async', p_id::text, 'agotada', NULL, 'job', NULL,
                    jsonb_build_object('tipo', v_tarea.tipo, 'error', p_error),
                    'Tarea a dead letter tras agotar reintentos');

    -- Aviso al superadmin, sin reintentos infinitos si el aviso también falla.
    PERFORM encolar_tarea('notificar_superadmin',
             jsonb_build_object('texto',
               format('⚠️ Tarea %s (%s) falló definitivamente tras %s intentos.%sÚltimo error: %s',
                      p_id, v_tarea.tipo, v_tarea.intentos, E'\n', p_error)),
             10, 'dead_letter_' || p_id, 0, 2);
    RETURN 'fallida';
  END IF;

  v_espera := LEAST(30 * power(2, v_tarea.intentos - 1)::int, 3600);
  UPDATE tarea_async
     SET estado = 'pendiente', ultimo_error = p_error,
         proxima_ejecucion = now() + make_interval(secs => v_espera)
   WHERE id = p_id;
  RETURN 'reintentar';
END;
$$;

-- Rescata tareas que quedaron 'procesando' porque el worker murió.
CREATE OR REPLACE FUNCTION rescatar_tareas_colgadas(p_minutos int DEFAULT 15)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  UPDATE tarea_async
     SET estado = 'pendiente', proxima_ejecucion = now(),
         ultimo_error = 'Rescatada: el worker no reportó resultado'
   WHERE estado = 'procesando'
     AND updated_at < now() - make_interval(mins => p_minutos);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------
-- Rate limiting genérico, sin estado en n8n (§5.3)
-- ---------------------------------------------------------------------
CREATE TABLE rate_limit (
  clave      text PRIMARY KEY,   -- ej: 'turno:chat:12345', 'login:ip:1.2.3.4'
  ventana_at timestamptz NOT NULL DEFAULT now(),
  conteo     int NOT NULL DEFAULT 0
);

-- true = permitido; false = excede el límite.
CREATE OR REPLACE FUNCTION consumir_rate_limit(
  p_clave text, p_max int, p_ventana_seg int
) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE v_conteo int;
BEGIN
  INSERT INTO rate_limit (clave, ventana_at, conteo)
  VALUES (p_clave, now(), 1)
  ON CONFLICT (clave) DO UPDATE
    SET conteo = CASE
                   WHEN rate_limit.ventana_at < now() - make_interval(secs => p_ventana_seg)
                   THEN 1 ELSE rate_limit.conteo + 1 END,
        ventana_at = CASE
                   WHEN rate_limit.ventana_at < now() - make_interval(secs => p_ventana_seg)
                   THEN now() ELSE rate_limit.ventana_at END
  RETURNING conteo INTO v_conteo;

  RETURN v_conteo <= p_max;
END;
$$;
