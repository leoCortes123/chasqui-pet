-- =====================================================================
-- Chasqui Pet — 020_identidad.sql
-- Usuarios, roles, permisos, sesiones web y autenticación por Telegram.
-- Los permisos son DATOS (§4), nunca constantes en código ni en n8n.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Usuarios. Nadie se autoregistra: un superadmin/admin aprovisiona.
-- ---------------------------------------------------------------------
CREATE TABLE usuario (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  telegram_user_id bigint UNIQUE,
  telegram_chat_id bigint,
  nombre_completo  text NOT NULL,
  telefono         text,
  email            text,
  sede_id          uuid REFERENCES sede(id),
  activo           boolean NOT NULL DEFAULT true,
  creado_por       uuid REFERENCES usuario(id),
  notas            text,
  ultimo_acceso_at timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER usuario_touch BEFORE UPDATE ON usuario
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_usuario_activo ON usuario (activo) WHERE activo;

CREATE TABLE rol (
  codigo      text PRIMARY KEY,
  nombre      text NOT NULL,
  descripcion text NOT NULL,
  nivel       int  NOT NULL DEFAULT 0,   -- mayor = más autoridad; sólo para ordenar en UI
  sistema     boolean NOT NULL DEFAULT false  -- los de seed no se borran
);

CREATE TABLE permiso (
  codigo      text PRIMARY KEY,
  modulo      text NOT NULL,
  descripcion text NOT NULL
);

CREATE TABLE rol_permiso (
  rol_codigo     text NOT NULL REFERENCES rol(codigo) ON DELETE CASCADE,
  permiso_codigo text NOT NULL REFERENCES permiso(codigo) ON DELETE CASCADE,
  PRIMARY KEY (rol_codigo, permiso_codigo)
);

CREATE TABLE usuario_rol (
  usuario_id  uuid NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
  rol_codigo  text NOT NULL REFERENCES rol(codigo),
  asignado_por uuid REFERENCES usuario(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (usuario_id, rol_codigo)
);

-- Permisos individuales por usuario: el "auxiliar con permiso explícito"
-- de §7.3 y el "auxiliar habilitado para entradas" de §4 se resuelven aquí,
-- sin inventar roles nuevos.
CREATE TABLE usuario_permiso (
  usuario_id     uuid NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
  permiso_codigo text NOT NULL REFERENCES permiso(codigo) ON DELETE CASCADE,
  otorgado       boolean NOT NULL DEFAULT true,  -- false = revocación explícita
  motivo         text,
  asignado_por   uuid REFERENCES usuario(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (usuario_id, permiso_codigo)
);

-- Permisos efectivos = (unión de los roles) + otorgados − revocados.
CREATE OR REPLACE VIEW v_usuario_permiso AS
  SELECT u.id AS usuario_id, p.codigo AS permiso_codigo
    FROM usuario u
    JOIN usuario_rol ur ON ur.usuario_id = u.id
    JOIN rol_permiso rp ON rp.rol_codigo = ur.rol_codigo
    JOIN permiso p      ON p.codigo = rp.permiso_codigo
   WHERE u.activo
     AND NOT EXISTS (SELECT 1 FROM usuario_permiso up
                      WHERE up.usuario_id = u.id
                        AND up.permiso_codigo = p.codigo
                        AND up.otorgado = false)
  UNION
  SELECT up.usuario_id, up.permiso_codigo
    FROM usuario_permiso up
    JOIN usuario u ON u.id = up.usuario_id AND u.activo
   WHERE up.otorgado;

CREATE OR REPLACE FUNCTION tiene_permiso(p_usuario_id uuid, p_permiso text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM v_usuario_permiso
     WHERE usuario_id = p_usuario_id AND permiso_codigo = p_permiso
  );
$$;

CREATE OR REPLACE FUNCTION exigir_permiso(p_usuario_id uuid, p_permiso text)
RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_usuario_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING ERRCODE = '28000';
  END IF;
  IF NOT tiene_permiso(p_usuario_id, p_permiso) THEN
    RAISE EXCEPTION 'No tienes permiso para esta acción (%)', p_permiso
      USING ERRCODE = '42501';
  END IF;
END;
$$;

-- Resuelve el usuario a partir del Telegram. Devuelve NULL si no está
-- aprovisionado o está inactivo: el bot responde igual en ambos casos.
CREATE OR REPLACE FUNCTION usuario_por_telegram(p_telegram_user_id bigint)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM usuario
   WHERE telegram_user_id = p_telegram_user_id AND activo;
$$;

-- Perfil completo para armar el menú del bot en una sola llamada.
CREATE OR REPLACE FUNCTION perfil_telegram(p_telegram_user_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT jsonb_build_object(
        'usuario_id',  u.id,
        'nombre',      u.nombre_completo,
        'sede_id',     u.sede_id,
        'es_personal', true,
        'roles',       COALESCE((SELECT jsonb_agg(ur.rol_codigo ORDER BY ur.rol_codigo)
                                   FROM usuario_rol ur WHERE ur.usuario_id = u.id), '[]'::jsonb),
        'permisos',    COALESCE((SELECT jsonb_agg(vp.permiso_codigo ORDER BY vp.permiso_codigo)
                                   FROM v_usuario_permiso vp WHERE vp.usuario_id = u.id), '[]'::jsonb)
      )
       FROM usuario u
      WHERE u.telegram_user_id = p_telegram_user_id AND u.activo),
    jsonb_build_object('es_personal', false, 'roles', '[]'::jsonb, 'permisos', '[]'::jsonb)
  );
$$;

-- Registra/actualiza el chat_id del personal (cambia si el usuario borra el chat).
CREATE OR REPLACE FUNCTION vincular_chat_usuario(p_telegram_user_id bigint, p_chat_id bigint)
RETURNS void LANGUAGE sql AS $$
  UPDATE usuario
     SET telegram_chat_id = p_chat_id, ultimo_acceso_at = now()
   WHERE telegram_user_id = p_telegram_user_id AND activo
     AND telegram_chat_id IS DISTINCT FROM p_chat_id;
$$;

-- ---------------------------------------------------------------------
-- Estado conversacional (§2.2.1): n8n NO guarda estado.
-- Si n8n se reinicia a mitad de un flujo, el usuario continúa donde iba.
-- ---------------------------------------------------------------------
CREATE TABLE conversacion_estado (
  chat_id      bigint PRIMARY KEY,
  usuario_id   uuid REFERENCES usuario(id) ON DELETE SET NULL,
  flujo        text,          -- 'salida_medicamento', 'consulta', 'cobro', ...
  paso         text,          -- paso dentro del flujo
  datos        jsonb NOT NULL DEFAULT '{}'::jsonb,
  mensaje_id   bigint,        -- último mensaje editable del bot
  expira_at    timestamptz NOT NULL DEFAULT now() + interval '2 hours',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER conversacion_estado_touch BEFORE UPDATE ON conversacion_estado
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE FUNCTION estado_guardar(
  p_chat_id bigint, p_flujo text, p_paso text,
  p_datos jsonb DEFAULT '{}'::jsonb, p_usuario_id uuid DEFAULT NULL,
  p_mensaje_id bigint DEFAULT NULL, p_ttl_min int DEFAULT 120
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  INSERT INTO conversacion_estado (chat_id, usuario_id, flujo, paso, datos, mensaje_id, expira_at)
  VALUES (p_chat_id, p_usuario_id, p_flujo, p_paso, p_datos, p_mensaje_id,
          now() + make_interval(mins => p_ttl_min))
  ON CONFLICT (chat_id) DO UPDATE
    SET usuario_id = COALESCE(EXCLUDED.usuario_id, conversacion_estado.usuario_id),
        flujo = EXCLUDED.flujo,
        paso  = EXCLUDED.paso,
        -- merge superficial: el paso nuevo sólo aporta lo que cambió
        datos = conversacion_estado.datos || EXCLUDED.datos,
        mensaje_id = COALESCE(EXCLUDED.mensaje_id, conversacion_estado.mensaje_id),
        expira_at = EXCLUDED.expira_at
  RETURNING datos INTO v;
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION estado_leer(p_chat_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT jsonb_build_object('flujo', flujo, 'paso', paso, 'datos', datos,
                               'mensaje_id', mensaje_id, 'usuario_id', usuario_id)
       FROM conversacion_estado
      WHERE chat_id = p_chat_id AND expira_at > now()),
    '{}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION estado_limpiar(p_chat_id bigint)
RETURNS void LANGUAGE sql AS $$
  DELETE FROM conversacion_estado WHERE chat_id = p_chat_id;
$$;

-- ---------------------------------------------------------------------
-- Autenticación al portal vía Telegram (§11.1)
-- ---------------------------------------------------------------------
CREATE TABLE auth_challenge (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo       char(6) NOT NULL,
  estado       text NOT NULL DEFAULT 'pendiente'
                 CHECK (estado IN ('pendiente','aprobado','rechazado','expirado','consumido')),
  intentos     int NOT NULL DEFAULT 0,
  usuario_id   uuid REFERENCES usuario(id),   -- se llena al aprobar
  ip           inet,
  user_agent   text,
  device_name  text,
  sesion_id    uuid,                          -- sesión emitida
  created_at   timestamptz NOT NULL DEFAULT now(),
  expira_at    timestamptz NOT NULL DEFAULT now() + interval '5 minutes',
  resuelto_at  timestamptz
);

CREATE INDEX idx_auth_challenge_pendiente ON auth_challenge (codigo)
  WHERE estado = 'pendiente';

CREATE TABLE sesion (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id   uuid NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
  token_hash   text NOT NULL UNIQUE,   -- sha256 del token; el token sólo viaja al cliente
  device_name  text,
  ip           inet,
  user_agent   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL DEFAULT now() + interval '30 days',
  revocada     boolean NOT NULL DEFAULT false,
  revocada_at  timestamptz,
  revocada_por uuid REFERENCES usuario(id)
);

CREATE INDEX idx_sesion_usuario ON sesion (usuario_id, revocada, expires_at DESC);

-- ---------------------------------------------------------------------
-- Aprovisionamiento de personal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_usuario(
  p_actor_id uuid,
  p_telegram_user_id bigint,
  p_nombre text,
  p_roles text[],
  p_sede_id uuid DEFAULT NULL,
  p_telefono text DEFAULT NULL,
  p_canal text DEFAULT 'web'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
  v_rol text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');

  IF p_roles IS NULL OR array_length(p_roles, 1) IS NULL THEN
    RAISE EXCEPTION 'Debes asignar al menos un rol';
  END IF;

  -- Sólo el superadmin puede crear otro superadmin.
  IF 'superadmin' = ANY (p_roles)
     AND NOT EXISTS (SELECT 1 FROM usuario_rol
                      WHERE usuario_id = p_actor_id AND rol_codigo = 'superadmin') THEN
    RAISE EXCEPTION 'Sólo un superadmin puede crear otro superadmin' USING ERRCODE = '42501';
  END IF;

  INSERT INTO usuario (telegram_user_id, nombre_completo, telefono, sede_id, creado_por)
  VALUES (p_telegram_user_id, p_nombre, p_telefono,
          COALESCE(p_sede_id, (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1)),
          p_actor_id)
  RETURNING id INTO v_id;

  FOREACH v_rol IN ARRAY p_roles LOOP
    INSERT INTO usuario_rol (usuario_id, rol_codigo, asignado_por)
    VALUES (v_id, v_rol, p_actor_id);
  END LOOP;

  PERFORM auditar('usuario', v_id::text, 'crear', p_actor_id, p_canal, NULL,
                  jsonb_build_object('nombre', p_nombre, 'roles', to_jsonb(p_roles)));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION desactivar_usuario(p_actor_id uuid, p_usuario_id uuid, p_canal text DEFAULT 'web')
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');
  IF p_actor_id = p_usuario_id THEN
    RAISE EXCEPTION 'No puedes desactivar tu propio usuario';
  END IF;

  UPDATE usuario SET activo = false WHERE id = p_usuario_id;
  UPDATE sesion SET revocada = true, revocada_at = now(), revocada_por = p_actor_id
   WHERE usuario_id = p_usuario_id AND NOT revocada;

  PERFORM auditar('usuario', p_usuario_id::text, 'desactivar', p_actor_id, p_canal);
END;
$$;
