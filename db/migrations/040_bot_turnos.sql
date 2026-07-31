-- =====================================================================
-- Chasqui Pet — 040_bot_turnos.sql
-- Capa de bot: convierte un update de Telegram en una lista de acciones.
--
-- Por qué está en Postgres y no en n8n: §2.1 exige que n8n sea una capa
-- delgada y §2.2.1 que no guarde estado. Si el árbol de decisión del bot
-- viviera en nodos de n8n, cada cambio de menú sería un despliegue y el
-- estado conversacional acabaría repartido en dos sitios. Aquí el flujo de
-- n8n son seis nodos y toda la lógica es consultable y probable con psql.
--
-- Contrato de salida:
--   { "acciones": [
--       {"tipo":"responder_callback","callback_query_id":"...","texto":"..."},
--       {"tipo":"enviar","chat_id":123,"texto":"...","botones":[[{"t":"Rótulo","d":"callback"}]]},
--       {"tipo":"editar","chat_id":123,"message_id":9,"texto":"...","botones":[...]}
--   ] }
-- =====================================================================

SET client_min_messages = warning;

-- Escape mínimo para parse_mode=HTML de Telegram.
CREATE OR REPLACE FUNCTION esc(txt text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(COALESCE(txt, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

-- Pesos colombianos: separador de miles, sin decimales (§12).
CREATE OR REPLACE FUNCTION pesos(v numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT '$' || to_char(round(COALESCE(v, 0)), 'FM999G999G999G999');
$$;

CREATE OR REPLACE FUNCTION accion_enviar(p_chat_id bigint, p_texto text, p_botones jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'tipo', 'enviar', 'chat_id', p_chat_id, 'texto', p_texto, 'botones', p_botones));
$$;

CREATE OR REPLACE FUNCTION accion_editar(p_chat_id bigint, p_mensaje_id bigint,
                                         p_texto text, p_botones jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'tipo', 'editar', 'chat_id', p_chat_id, 'message_id', p_mensaje_id,
    'texto', p_texto, 'botones', p_botones));
$$;

-- ---------------------------------------------------------------------
-- Puntos de extensión para los módulos que llegan después
--
-- El enrutador vive en este archivo porque el primer módulo operativo fue
-- turnos, pero inventario (§6), clínico (§8) y cobro (§7) también
-- necesitan poner botones en el menú y atender sus propios callbacks. En
-- vez de reescribir bot_manejar_update en cada migración —copiando 300
-- líneas que después se desincronizan— se declaran aquí tres enganches
-- vacíos que las migraciones posteriores reemplazan con CREATE OR REPLACE.
--
-- Contrato de las dos últimas: devuelven NULL si el módulo no reconoce lo
-- que llegó (y el enrutador sigue con su comportamiento por defecto), o
-- {"alerta": text|null, "acciones": [...]} si lo atendieron.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT '[]'::jsonb; $$;

CREATE OR REPLACE FUNCTION bot_modulo_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb LANGUAGE sql AS $$ SELECT NULL::jsonb; $$;

CREATE OR REPLACE FUNCTION bot_modulo_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb LANGUAGE sql AS $$ SELECT NULL::jsonb; $$;

-- Un tercer enganche para lo que no es texto ni botón: la foto de la
-- factura que se adjunta a una entrada de inventario (§9). Recibe el
-- `message` completo porque cada módulo sabe qué mirar dentro —photo,
-- document— y el enrutador no tiene por qué saberlo.
CREATE OR REPLACE FUNCTION bot_modulo_media(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje jsonb, p_sede_id uuid)
RETURNS jsonb LANGUAGE sql AS $$ SELECT NULL::jsonb; $$;

-- /ayuda se atiende antes que los módulos —es un comando del enrutador—,
-- así que su texto también es un enganche: cada módulo nuevo reescribe
-- esta función añadiendo sus comandos, en vez de que la lista se quede
-- vieja en 300 líneas de enrutador que nadie quiere volver a tocar.
CREATE OR REPLACE FUNCTION bot_texto_ayuda(p_usuario_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT '<b>Comandos</b>' || E'\n' ||
         '/menu — menú principal' || E'\n' ||
         '/cola — pacientes en espera' || E'\n' ||
         '/stock — existencias y alertas de inventario' || E'\n' ||
         '/sesiones — sesiones abiertas en el portal' || E'\n' ||
         '/ayuda — esta ayuda';
$$;

-- ---------------------------------------------------------------------
-- Menú principal, armado según los permisos reales del usuario (§4).
-- Máximo 3 botones por fila (§12).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_menu_principal(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_nombre text;
  v_sesion record;
  v_texto text;
  v_filas jsonb := '[]'::jsonb;
  v_fila jsonb;
BEGIN
  SELECT nombre_completo INTO v_nombre FROM usuario WHERE id = p_usuario_id;

  SELECT c.nombre AS consultorio, c.id AS consultorio_id INTO v_sesion
    FROM sesion_consultorio sc JOIN consultorio c ON c.id = sc.consultorio_id
   WHERE sc.usuario_id = p_usuario_id AND sc.cerrada_at IS NULL;

  v_texto := format('<b>%s</b>%s%s',
                    esc(config_txt('nombre_clinica', 'Chasqui Pet')), E'\n',
                    'Hola, ' || esc(split_part(v_nombre, ' ', 1)) || '.');

  IF v_sesion.consultorio IS NOT NULL THEN
    v_texto := v_texto || E'\n' || 'Estás en <b>' || esc(v_sesion.consultorio) || '</b>.';
  END IF;

  -- Fila 1: la operación del turno.
  v_fila := '[]'::jsonb;
  IF tiene_permiso(p_usuario_id, 'turnos.llamar') AND v_sesion.consultorio IS NOT NULL THEN
    v_fila := v_fila || jsonb_build_object('t', '📢 Llamar siguiente', 'd', 'turno:llamar');
  END IF;
  IF tiene_permiso(p_usuario_id, 'turnos.ver') THEN
    v_fila := v_fila || jsonb_build_object('t', '📋 Ver cola', 'd', 'turno:cola');
  END IF;
  IF jsonb_array_length(v_fila) > 0 THEN v_filas := v_filas || jsonb_build_array(v_fila); END IF;

  -- Fila 2: creación de turnos.
  v_fila := '[]'::jsonb;
  IF tiene_permiso(p_usuario_id, 'turnos.crear') THEN
    v_fila := v_fila || jsonb_build_object('t', '➕ Turno manual', 'd', 'turno:manual');
  END IF;
  IF tiene_permiso(p_usuario_id, 'turnos.crear') THEN
    v_fila := v_fila || jsonb_build_object('t', '↩️ Ausentes', 'd', 'turno:ausentes');
  END IF;
  IF jsonb_array_length(v_fila) > 0 THEN v_filas := v_filas || jsonb_build_array(v_fila); END IF;

  -- Filas de los demás módulos (inventario, clínico, cobro).
  v_filas := v_filas || bot_menu_extra(p_usuario_id);

  -- Fila 3: consultorio.
  IF tiene_permiso(p_usuario_id, 'consultorio.abrir') THEN
    v_filas := v_filas || jsonb_build_array(jsonb_build_array(
      CASE WHEN v_sesion.consultorio IS NULL
           THEN jsonb_build_object('t', '🚪 Abrir consultorio', 'd', 'consultorio:elegir')
           ELSE jsonb_build_object('t', '🔒 Cerrar consultorio', 'd', 'consultorio:cerrar')
      END));
  END IF;

  IF jsonb_array_length(v_filas) = 0 THEN
    v_texto := v_texto || E'\n\n' || 'Tu usuario no tiene acciones habilitadas. Habla con el administrador.';
  END IF;

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_filas);
END;
$$;

-- ---------------------------------------------------------------------
-- Tarjeta de un turno, tal como la ve el veterinario
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_tarjeta_turno(p_turno_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  t jsonb := turno_json(p_turno_id);
  v_texto text;
  v_botones jsonb := '[]'::jsonb;
BEGIN
  IF t IS NULL THEN
    RETURN jsonb_build_object('texto', 'Ese turno ya no existe.', 'botones', '[]'::jsonb);
  END IF;

  v_texto := format('<b>%s</b> · %s%s%s',
              esc(t->>'codigo'), esc(t->>'tipo'), E'\n',
              CASE t->>'estado'
                WHEN 'llamado'     THEN '📢 Llamado a ' || esc(COALESCE(t->>'consultorio','—'))
                WHEN 'en_atencion' THEN '🩺 En atención en ' || esc(COALESCE(t->>'consultorio','—'))
                WHEN 'finalizado'  THEN '✅ Finalizado'
                WHEN 'ausente'     THEN '⚠️ No se presentó'
                WHEN 'cancelado'   THEN '🚫 Cancelado'
                ELSE '⏳ En espera'
              END);

  IF t->>'notas' IS NOT NULL THEN
    v_texto := v_texto || E'\n' || '📝 ' || esc(t->>'notas');
  END IF;

  IF (t->>'prioridad')::int > 0 THEN
    v_texto := v_texto || E'\n' || '🚨 <b>Urgencia</b>';
  END IF;

  CASE t->>'estado'
    WHEN 'llamado' THEN
      v_botones := jsonb_build_array(
        jsonb_build_array(
          jsonb_build_object('t', '✅ Ya llegó', 'd', 'turno:presento:' || (t->>'turno_id')),
          jsonb_build_object('t', '⚠️ No se presentó', 'd', 'turno:ausente:' || (t->>'turno_id'))));
    WHEN 'en_atencion' THEN
      v_botones := jsonb_build_array(
        jsonb_build_array(
          jsonb_build_object('t', '🏁 Finalizar', 'd', 'turno:finalizar:' || (t->>'turno_id'))));
    WHEN 'ausente' THEN
      v_botones := jsonb_build_array(
        jsonb_build_array(
          jsonb_build_object('t', '↩️ Reencolar', 'd', 'turno:reencolar:' || (t->>'turno_id'))));
    ELSE
      v_botones := '[]'::jsonb;
  END CASE;

  v_botones := v_botones || jsonb_build_array(jsonb_build_array(
                 jsonb_build_object('t', '⬅️ Menú', 'd', 'menu')));

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_botones);
END;
$$;

-- Cola en texto corto, legible en gama baja. Sin tablas ASCII (§12).
CREATE OR REPLACE FUNCTION bot_texto_cola(p_sede_id uuid, p_limite int DEFAULT 10)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE v_texto text; v_total int; v_lineas text;
BEGIN
  SELECT count(*) INTO v_total FROM v_cola_actual WHERE sede_id = p_sede_id;

  IF v_total = 0 THEN
    RETURN '📋 <b>Cola</b>' || E'\n' || 'No hay pacientes esperando.';
  END IF;

  SELECT string_agg(
           format('%s%s · %s min',
                  CASE WHEN prioridad > 0 THEN '🚨 ' ELSE '' END,
                  '<b>' || esc(codigo) || '</b>',
                  minutos_esperando),
           E'\n' ORDER BY prioridad DESC, numero_secuencial)
    INTO v_lineas
    FROM (SELECT * FROM v_cola_actual WHERE sede_id = p_sede_id LIMIT p_limite) q;

  v_texto := format('📋 <b>Cola</b> · %s esperando%s%s', v_total, E'\n', v_lineas);

  IF v_total > p_limite THEN
    v_texto := v_texto || E'\n' || format('… y %s más.', v_total - p_limite);
  END IF;

  RETURN v_texto;
END;
$$;

-- ---------------------------------------------------------------------
-- Enrutador principal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_manejar_update(p_update jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_cb        jsonb := p_update->'callback_query';
  v_msg       jsonb := COALESCE(p_update->'message', v_cb->'message');
  v_chat_id   bigint;
  v_user_id   bigint;
  v_texto_in  text;
  v_data      text;
  v_mensaje_id bigint;
  v_perfil    jsonb;
  v_usuario   uuid;
  v_sede      uuid;
  v_acciones  jsonb := '[]'::jsonb;
  v_menu      jsonb;
  v_r         jsonb;
  v_turno_id  uuid;
  v_partes    text[];
  v_alerta    text := NULL;
BEGIN
  v_chat_id    := (v_msg->'chat'->>'id')::bigint;
  v_user_id    := COALESCE((v_cb->'from'->>'id')::bigint, (p_update->'message'->'from'->>'id')::bigint);
  v_texto_in   := trim(COALESCE(p_update->'message'->>'text', ''));
  v_data       := v_cb->>'data';
  v_mensaje_id := (v_msg->>'message_id')::bigint;

  IF v_chat_id IS NULL THEN
    RETURN jsonb_build_object('acciones', '[]'::jsonb);
  END IF;

  v_perfil  := perfil_telegram(v_user_id);
  v_usuario := (v_perfil->>'usuario_id')::uuid;

  IF v_usuario IS NOT NULL THEN
    PERFORM vincular_chat_usuario(v_user_id, v_chat_id);
    v_sede := COALESCE((v_perfil->>'sede_id')::uuid,
                       (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1));
  ELSE
    v_sede := (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1);
  END IF;

  -- =================================================================
  -- A) Público: /start desde el QR. Sin autenticación ni registro.
  -- =================================================================
  IF v_texto_in LIKE '/start%' AND v_usuario IS NULL THEN
    DECLARE v_arg text := trim(substring(v_texto_in FROM 7)); v_sede_qr uuid;
    BEGIN
      IF v_arg LIKE 'web-%' THEN
        -- Ingreso al portal de alguien sin usuario aprovisionado. Se
        -- deniega sin decir si el enlace era válido (§11.1.4): quien
        -- prueba enlaces ajenos no debe poder distinguir un código real
        -- de uno inventado.
        RETURN jsonb_build_object('acciones', jsonb_build_array(accion_enviar(v_chat_id,
          'No se pudo iniciar sesión. Habla con el administrador de la clínica.')));
      END IF;

      IF v_arg LIKE 'turno-%' THEN
        BEGIN
          v_sede_qr := substring(v_arg FROM 7)::uuid;
        EXCEPTION WHEN others THEN v_sede_qr := NULL;
        END;
      END IF;

      v_r := crear_turno_qr(v_chat_id, COALESCE(v_sede_qr, v_sede));

      IF NOT (v_r->>'ok')::boolean THEN
        RETURN jsonb_build_object('acciones', jsonb_build_array(
          accion_enviar(v_chat_id, esc(v_r->>'mensaje'))));
      END IF;

      RETURN jsonb_build_object('acciones', jsonb_build_array(
        accion_enviar(v_chat_id, bot_texto_turno_dueno(v_r))));
    END;
  END IF;

  -- El público sin turno que escribe cualquier otra cosa.
  IF v_usuario IS NULL THEN
    SELECT id INTO v_turno_id FROM turno
     WHERE telegram_chat_id = v_chat_id AND fecha = hoy_bogota()
       AND estado IN ('en_espera','llamado','en_atencion');

    IF v_turno_id IS NOT NULL THEN
      RETURN jsonb_build_object('acciones', jsonb_build_array(
        accion_enviar(v_chat_id,
          bot_texto_turno_dueno(jsonb_build_object('ok', true, 'ya_existia', true,
                                                   'turno', turno_json(v_turno_id))))));
    END IF;

    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(v_chat_id,
        'Para tomar un turno, escanea el código QR de la entrada de la clínica.')));
  END IF;

  -- =================================================================
  -- B) Personal: comandos de texto
  -- =================================================================
  IF v_data IS NULL THEN
    v_menu := bot_menu_principal(v_usuario);

    IF v_texto_in IN ('/cola', 'cola') AND tiene_permiso(v_usuario, 'turnos.ver') THEN
      RETURN jsonb_build_object('acciones', jsonb_build_array(
        accion_enviar(v_chat_id, bot_texto_cola(v_sede), v_menu->'botones')));
    END IF;

    IF v_texto_in = '/ayuda' THEN
      RETURN jsonb_build_object('acciones', jsonb_build_array(
        accion_enviar(v_chat_id, bot_texto_ayuda(v_usuario))));
    END IF;

    -- Una foto o un archivo: sólo tiene sentido dentro de un flujo que lo
    -- esté esperando. Se pregunta antes que nada más para que el mensaje
    -- no acabe tratado como texto suelto —que limpiaría el estado y le
    -- borraría al auxiliar la factura a medio digitar—.
    IF p_update->'message' ? 'photo' OR p_update->'message' ? 'document' THEN
      v_r := bot_modulo_media(v_usuario, v_chat_id, p_update->'message', v_sede);
      RETURN jsonb_build_object('acciones',
        COALESCE(v_r->'acciones', jsonb_build_array(accion_enviar(v_chat_id,
          'Recibí el archivo, pero no hay nada esperándolo. Empieza por el menú con /menu.'))));
    END IF;

    -- Si hay un flujo en curso (§2.2.1), el texto es su respuesta: el
    -- nombre del medicamento que se busca, una cantidad, un motivo.
    IF v_texto_in <> '' AND v_texto_in NOT IN ('/start','/menu','/cancelar','menu') THEN
      v_r := bot_modulo_texto(v_usuario, v_chat_id, v_texto_in, v_sede);
      IF v_r IS NOT NULL THEN
        RETURN jsonb_build_object('acciones', COALESCE(v_r->'acciones', '[]'::jsonb));
      END IF;
    END IF;

    -- /start, /menu y cualquier otro texto suelto: menú principal.
    PERFORM estado_limpiar(v_chat_id);
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(v_chat_id, v_menu->>'texto', v_menu->'botones')));
  END IF;

  -- =================================================================
  -- C) Personal: botones (callback_query)
  -- =================================================================
  v_partes := string_to_array(v_data, ':');

  BEGIN
    CASE
      -- --- Menú -----------------------------------------------------
      WHEN v_data = 'menu' THEN
        v_menu := bot_menu_principal(v_usuario);
        v_acciones := jsonb_build_array(
          accion_editar(v_chat_id, v_mensaje_id, v_menu->>'texto', v_menu->'botones'));

      -- --- Llamar siguiente ----------------------------------------
      WHEN v_data = 'turno:llamar' THEN
        v_r := llamar_siguiente(v_usuario);
        IF (v_r->>'ok')::boolean THEN
          v_turno_id := (v_r->'turno'->>'turno_id')::uuid;
          v_menu := bot_tarjeta_turno(v_turno_id);
          v_alerta := 'Turno ' || (v_r->'turno'->>'codigo');
          v_acciones := jsonb_build_array(
            accion_editar(v_chat_id, v_mensaje_id, v_menu->>'texto', v_menu->'botones'));
        ELSE
          v_alerta := v_r->>'mensaje';
          v_menu := bot_menu_principal(v_usuario);
          v_acciones := jsonb_build_array(
            accion_editar(v_chat_id, v_mensaje_id,
              esc(v_r->>'mensaje') || E'\n\n' || (v_menu->>'texto'), v_menu->'botones'));
        END IF;

      -- --- Ver cola -------------------------------------------------
      WHEN v_data = 'turno:cola' THEN
        v_menu := bot_menu_principal(v_usuario);
        v_acciones := jsonb_build_array(
          accion_editar(v_chat_id, v_mensaje_id, bot_texto_cola(v_sede), v_menu->'botones'));

      -- --- Transiciones sobre un turno concreto ---------------------
      WHEN v_partes[1] = 'turno' AND v_partes[3] IS NOT NULL THEN
        v_turno_id := v_partes[3]::uuid;

        v_r := CASE v_partes[2]
                 WHEN 'presento'  THEN iniciar_atencion(v_usuario, v_turno_id)
                 WHEN 'ausente'   THEN marcar_ausente(v_usuario, v_turno_id)
                 WHEN 'reencolar' THEN reencolar_turno(v_usuario, v_turno_id)
                 WHEN 'finalizar' THEN finalizar_turno(v_usuario, v_turno_id)
                 WHEN 'urgencia'  THEN marcar_urgencia(v_usuario, v_turno_id)
                 WHEN 'cancelar'  THEN cancelar_turno(v_usuario, v_turno_id)
                 ELSE jsonb_build_object('ok', false, 'mensaje', 'Acción desconocida.')
               END;

        IF NOT (v_r->>'ok')::boolean THEN
          v_alerta := v_r->>'mensaje';
        END IF;

        v_menu := bot_tarjeta_turno(v_turno_id);

        -- Tras marcar ausente o finalizar, lo útil es ofrecer el siguiente.
        IF (v_r->>'ok')::boolean AND v_partes[2] IN ('ausente','finalizar')
           AND tiene_permiso(v_usuario, 'turnos.llamar') THEN
          v_menu := jsonb_set(v_menu, '{botones}',
            (v_menu->'botones') || jsonb_build_array(jsonb_build_array(
              jsonb_build_object('t', '📢 Llamar siguiente', 'd', 'turno:llamar'))));
        END IF;

        v_acciones := jsonb_build_array(
          accion_editar(v_chat_id, v_mensaje_id, v_menu->>'texto', v_menu->'botones'));

      -- --- Listado de ausentes para reencolar -----------------------
      WHEN v_data = 'turno:ausentes' THEN
        DECLARE v_txt text; v_bot jsonb := '[]'::jsonb;
        BEGIN
          SELECT string_agg('<b>' || esc(codigo) || '</b>', ', ' ORDER BY numero_secuencial),
                 COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
                   't', '↩️ ' || codigo, 'd', 'turno:reencolar:' || id))
                   ORDER BY numero_secuencial), '[]'::jsonb)
            INTO v_txt, v_bot
            FROM turno
           WHERE sede_id = v_sede AND fecha = hoy_bogota() AND estado = 'ausente'
             AND veces_reencolado < config_int('max_reencolados', 1);

          v_bot := v_bot || jsonb_build_array(jsonb_build_array(
                     jsonb_build_object('t', '⬅️ Menú', 'd', 'menu')));

          v_acciones := jsonb_build_array(accion_editar(v_chat_id, v_mensaje_id,
            COALESCE('⚠️ <b>Ausentes por reencolar</b>' || E'\n' || v_txt,
                     'No hay turnos ausentes pendientes.'), v_bot));
        END;

      -- --- Turno manual: elegir tipo de servicio ---------------------
      WHEN v_data = 'turno:manual' THEN
        DECLARE v_bot jsonb;
        BEGIN
          SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                   't', nombre, 'd', 'turno:nuevo:' || codigo)) ORDER BY orden)
            INTO v_bot
            FROM tipo_servicio
           WHERE activo
             AND (prioridad_base = 0 OR tiene_permiso(v_usuario, 'turnos.priorizar'));

          v_acciones := jsonb_build_array(accion_editar(v_chat_id, v_mensaje_id,
            '➕ <b>Turno manual</b>' || E'\n' || '¿Qué necesita el paciente?',
            v_bot || jsonb_build_array(jsonb_build_array(
              jsonb_build_object('t', '⬅️ Menú', 'd', 'menu')))));
        END;

      WHEN v_partes[1] = 'turno' AND v_partes[2] = 'nuevo' THEN
        v_r := crear_turno_manual(v_usuario, v_sede, v_partes[3],
                                  v_partes[3] = 'urgencia');
        v_turno_id := (v_r->'turno'->>'turno_id')::uuid;
        v_alerta := 'Turno ' || (v_r->'turno'->>'codigo') || ' creado';
        v_menu := bot_tarjeta_turno(v_turno_id);
        v_acciones := jsonb_build_array(accion_editar(v_chat_id, v_mensaje_id,
          '✅ Turno creado.' || E'\n' || (v_menu->>'texto'), v_menu->'botones'));

      -- --- Consultorio ----------------------------------------------
      WHEN v_data = 'consultorio:elegir' THEN
        DECLARE v_bot jsonb;
        BEGIN
          SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                   't', '🚪 ' || nombre, 'd', 'consultorio:abrir:' || id)) ORDER BY orden)
            INTO v_bot
            FROM consultorio WHERE sede_id = v_sede AND activo;

          v_acciones := jsonb_build_array(accion_editar(v_chat_id, v_mensaje_id,
            '¿En qué consultorio vas a atender?',
            COALESCE(v_bot, '[]'::jsonb) || jsonb_build_array(jsonb_build_array(
              jsonb_build_object('t', '⬅️ Menú', 'd', 'menu')))));
        END;

      WHEN v_partes[1] = 'consultorio' AND v_partes[2] = 'abrir' THEN
        v_r := abrir_consultorio(v_usuario, v_partes[3]::uuid);
        v_alerta := COALESCE(v_r->>'mensaje',
                             'Abriste ' || COALESCE(v_r->>'consultorio', 'el consultorio'));
        v_menu := bot_menu_principal(v_usuario);
        v_acciones := jsonb_build_array(
          accion_editar(v_chat_id, v_mensaje_id, v_menu->>'texto', v_menu->'botones'));

      WHEN v_data = 'consultorio:cerrar' THEN
        v_r := cerrar_consultorio(v_usuario);
        v_alerta := COALESCE(v_r->>'mensaje', 'Consultorio cerrado');
        v_menu := bot_menu_principal(v_usuario);
        v_acciones := jsonb_build_array(
          accion_editar(v_chat_id, v_mensaje_id, v_menu->>'texto', v_menu->'botones'));

      ELSE
        -- No es de turnos: se ofrece a los demás módulos antes de rendirse.
        v_r := bot_modulo_callback(v_usuario, v_chat_id, v_mensaje_id, v_data, v_sede);

        IF v_r IS NOT NULL THEN
          v_alerta   := v_r->>'alerta';
          v_acciones := COALESCE(v_r->'acciones', '[]'::jsonb);
        ELSE
          v_alerta := 'Esa opción ya no está disponible.';
          v_menu := bot_menu_principal(v_usuario);
          v_acciones := jsonb_build_array(
            accion_editar(v_chat_id, v_mensaje_id, v_menu->>'texto', v_menu->'botones'));
        END IF;
    END CASE;

  EXCEPTION
    WHEN insufficient_privilege THEN
      -- Un permiso revocado a mitad de jornada no debe romper el chat.
      v_alerta := 'No tienes permiso para esa acción.';
      v_menu := bot_menu_principal(v_usuario);
      v_acciones := jsonb_build_array(
        accion_editar(v_chat_id, v_mensaje_id, v_menu->>'texto', v_menu->'botones'));
  END;

  -- Telegram exige responder el callback siempre; si no, el botón queda
  -- girando en el celular del veterinario.
  RETURN jsonb_build_object('acciones',
    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'tipo', 'responder_callback',
      'callback_query_id', v_cb->>'id',
      'texto', v_alerta))) || v_acciones);
END;
$$;

-- Mensaje que ve el dueño (no el personal): su turno, posición y espera.
CREATE OR REPLACE FUNCTION bot_texto_turno_dueno(p_resultado jsonb)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  t jsonb := p_resultado->'turno';
  v_texto text;
  v_espera int := COALESCE((t->>'espera_min')::int, 0);
BEGIN
  v_texto := CASE WHEN (p_resultado->>'ya_existia')::boolean
                  THEN 'Ya tienes un turno para hoy.' || E'\n'
                  ELSE '' END;

  v_texto := v_texto || format('Tu turno es <b>%s</b>', esc(t->>'codigo'));

  IF t->>'estado' = 'en_espera' THEN
    v_texto := v_texto || E'\n' || format('Hay %s antes que tú.',
                 CASE WHEN (t->>'posicion')::int <= 1 THEN 'nadie'
                      WHEN (t->>'posicion')::int = 2 THEN '1 persona'
                      ELSE ((t->>'posicion')::int - 1) || ' personas' END);
    v_texto := v_texto || E'\n' || CASE
                 WHEN v_espera = 0 THEN 'Te llamamos en seguida.'
                 ELSE format('Espera aproximada: <b>%s minutos</b>.', v_espera) END;
    v_texto := v_texto || E'\n\n' || 'Te avisamos por aquí cuando falten pocos turnos y cuando sea el tuyo. No cierres este chat.';
  ELSIF t->>'estado' = 'llamado' THEN
    v_texto := v_texto || E'\n' || format('🔔 Es tu turno. Pasa al <b>%s</b>.',
                 esc(COALESCE(t->>'consultorio', 'consultorio')));
  ELSIF t->>'estado' = 'en_atencion' THEN
    v_texto := v_texto || E'\n' || 'Estás en atención.';
  END IF;

  RETURN v_texto;
END;
$$;
