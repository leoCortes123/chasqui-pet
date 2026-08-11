-- =====================================================================
-- Chasqui Pet — 077_portal_enlace.sql
-- Botón «Entrar al portal» en el menú del bot (§11.1).
--
-- El ingreso normal empieza en el navegador: la web crea el challenge,
-- muestra seis dígitos y el bot los confirma. Ahí el usuario ya está en
-- el computador. Esto es el camino contrario, para quien está en el chat
-- y no quiere teclear nada: el bot crea un challenge YA APROBADO —la
-- identidad de Telegram es la misma que usa el portal (058)— y devuelve
-- un enlace que lo canjea por sesión.
--
-- El enlace es el secreto, así que se le aplica lo mismo que a cualquier
-- credencial de un solo uso:
--   · vive 5 minutos (el `expira_at` por defecto de auth_challenge),
--   · se consume al abrirlo (`emitir_sesion_web` lo pasa a 'consumido'),
--   · queda auditado y dispara el aviso de sesión nueva en Telegram, que
--     es lo que permite darse cuenta si alguien más lo usó.
--
-- No se inventa emisión de sesión aparte: se reutiliza `emitir_sesion_web`
-- tal cual. Un solo camino para crear sesiones es un solo camino que
-- revisar cuando algo huela mal.
-- =====================================================================

SET client_min_messages = warning;

-- Dirección del portal tal como la ve el personal. El bot arma el enlace
-- con esto: la base no conoce WEB_PUBLIC_URL, que es del contenedor web.
INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('portal_url', 'http://localhost:3100', 'texto',
   'Dirección del portal, para el enlace de ingreso que manda el bot', true)
ON CONFLICT (clave) DO NOTHING;

-- ---------------------------------------------------------------------
-- Enlace de un solo uso, pedido desde el chat
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_enlace_portal(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_id     uuid;
  v_activo boolean;
  v_expira timestamptz;
BEGIN
  SELECT activo INTO v_activo FROM usuario WHERE id = p_usuario_id;
  IF NOT COALESCE(v_activo, false) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_usuario',
             'mensaje', 'Tu usuario no está habilitado para el portal.');
  END IF;

  -- Cada enlace es una sesión potencial. Cinco por hora alcanzan de sobra
  -- para el uso real y ponen techo a un chat secuestrado.
  IF NOT consumir_rate_limit('portal:enlace:' || p_usuario_id::text, 5, 3600) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'rate_limit',
             'mensaje', 'Pediste varios enlaces seguidos. Espera unos minutos.');
  END IF;

  -- Los enlaces anteriores que sigan vivos se anulan: si uno se filtró en
  -- el chat, pedir otro tiene que ser suficiente para dejarlo inservible.
  UPDATE auth_challenge
     SET estado = 'expirado', resuelto_at = now()
   WHERE usuario_id = p_usuario_id
     AND estado = 'aprobado'
     AND device_name = 'Enlace desde Telegram'
     AND expira_at > now();

  INSERT INTO auth_challenge (codigo, estado, usuario_id, device_name, resuelto_at)
  VALUES (lpad((floor(random() * 1000000))::int::text, 6, '0'),
          'aprobado', p_usuario_id, 'Enlace desde Telegram', now())
  RETURNING id, expira_at INTO v_id, v_expira;

  PERFORM auditar('auth_challenge', v_id::text, 'crear_enlace', p_usuario_id, 'telegram',
                  NULL, jsonb_build_object('canal', 'enlace_telegram'));

  RETURN jsonb_build_object(
    'ok', true,
    'url', rtrim(config_txt('portal_url', 'http://localhost:3100'), '/')
           || '/entrar/enlace/' || v_id::text,
    'expira_at', v_expira);
END;
$$;

-- ---------------------------------------------------------------------
-- El lado del bot
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_por_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_array(jsonb_build_array(
           jsonb_build_object('t', '🖥️ Entrar al portal', 'd', 'por:enlace')));
$$;

CREATE OR REPLACE FUNCTION bot_por_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_r     jsonb;
  v_texto text;
  v_alerta text;
BEGIN
  IF p_data <> 'por:enlace' THEN
    RETURN NULL;
  END IF;

  v_r := crear_enlace_portal(p_usuario_id);

  IF NOT (v_r->>'ok')::boolean THEN
    v_alerta := 'No se pudo';
    v_texto  := '⚠️ ' || esc(v_r->>'mensaje');
  ELSE
    v_alerta := 'Enlace listo';
    -- El enlace va como texto plano, sin <a>: en el computador se copia, y
    -- que se vea a dónde lleva es parte de poder desconfiar de él.
    v_texto := '🖥️ <b>Entrar al portal</b>' || E'\n\n' ||
               esc(v_r->>'url') || E'\n\n' ||
               '⏳ Sirve <b>una sola vez</b> y por <b>5 minutos</b>.' || E'\n' ||
               'Si lo abres aquí entras desde el celular; para entrar en el ' ||
               'computador de la clínica, cópialo allá.' || E'\n' ||
               'No se lo pases a nadie: quien lo abra entra con tu usuario.';
  END IF;

  RETURN jsonb_build_object('alerta', v_alerta, 'acciones', jsonb_build_array(
    accion_editar(p_chat_id, p_mensaje_id, v_texto, jsonb_build_array(
      jsonb_build_array(jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_por_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  IF p_texto NOT IN ('/portal', 'portal') THEN
    RETURN NULL;
  END IF;
  RETURN bot_por_callback(p_usuario_id, p_chat_id, NULL, 'por:enlace', p_sede_id);
END;
$$;

-- ---------------------------------------------------------------------
-- Despachadores: se añade el portal a los módulos anteriores
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_cli_menu(p_usuario_id) || bot_inv_menu(p_usuario_id)
      || bot_cob_menu(p_usuario_id) || bot_com_menu(p_usuario_id)
      || bot_por_menu(p_usuario_id);
$$;

CREATE OR REPLACE FUNCTION bot_modulo_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_inv_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_cli_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_cob_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_com_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_por_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_auth_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_modulo_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_auth_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_por_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_inv_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cob_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_com_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cli_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_texto_ayuda(p_usuario_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT '<b>Comandos</b>' || E'\n' ||
         '/menu — menú principal' || E'\n' ||
         '/cola — pacientes en espera' || E'\n' ||
         '/stock — existencias y alertas de inventario' || E'\n' ||
         '/entrada — registrar una compra que llegó' || E'\n' ||
         '/proveedores — proveedores y última compra' || E'\n' ||
         '/cobrar — cuentas abiertas por cobrar' || E'\n' ||
         '/caja — estado de la caja del día' || E'\n' ||
         '/portal — enlace para entrar al portal' || E'\n' ||
         '/sesiones — sesiones abiertas en el portal' || E'\n' ||
         '/ayuda — esta ayuda';
$$;
