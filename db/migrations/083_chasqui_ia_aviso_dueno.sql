-- =====================================================================
-- Chasqui Pet — 083_chasqui_ia_aviso_dueno.sql
-- Fase 5: envío asistido de avisos y recordatorios a los clientes.
--
-- Herramienta de escritura de una sola vuelta:
--
--   «envíale un aviso a la dueña de Luna que ya está lista para recoger»
--   «recuérdale a Jorge que vence la vacuna de Michifú»
--
-- El diseño sigue las mismas reglas de 078/079/081/082:
--
--   1. NADA de SQL libre: `preparar_aviso_dueno`, con esquema tipado
--      (dueno_id desde buscar_dueno + el texto del mensaje). El texto lo
--      redacta el asistente, pero quién lo recibe siempre sale de la base.
--
--   2. Los permisos son del usuario: `avisos.enviar`, nuevo y otorgado a
--      los roles de mostrador (recepcion, auxiliar, admin, superadmin).
--      Tres rejas como siempre (catálogo, ia_llamar, exigir_permiso).
--
--   3. Ley 1581 de 2012 (§12): un aviso por Telegram solo puede salir si
--      el dueño autorizó el contacto Y tenemos su chat. Se valida en el
--      borrador (no se ofrece lo que no se puede hacer) y se vuelve a
--      validar en la ejecución (el consentimiento pudo retirarse entre
--      la propuesta y el botón). No hay camino alternativo.
--
--   4. ESCRIBIR se confirma con un botón (C6.9). El borrador arma la
--      tarjeta de vista previa —a quién, por qué canal y el mensaje
--      exacto— y deja la propuesta en `ia_accion_pendiente`. La
--      confirmación es la única que encola el envío.
--
--   5. El envío es ASÍNCRONO (C6.7/C6.10): la confirmación encola
--      `enviar_aviso_dueno` en tarea_async y responde en <1 s. El worker
--      lo manda por Telegram con la misma comprobación de consentimiento
--      (el dueño pudo retirarlo incluso entre confirmar y enviar).
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 0. Permiso nuevo: comunicarse con los clientes es un permiso aparte
-- ---------------------------------------------------------------------
INSERT INTO permiso (codigo, modulo, descripcion) VALUES
('avisos.enviar', 'avisos', 'Enviar avisos y recordatorios por Telegram a los dueños')
ON CONFLICT (codigo) DO NOTHING;

-- Otorgado a los roles de mostrador y administración. No es una tarea del
-- veterinario atender mensajes masivos; los permisos son datos (§4) y se
-- otorga por rol o por usuario si hace falta.
INSERT INTO rol_permiso (rol_codigo, permiso_codigo) VALUES
('superadmin', 'avisos.enviar'),
('admin',      'avisos.enviar'),
('auxiliar',   'avisos.enviar'),
('recepcion',  'avisos.enviar')
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------
-- 1. Herramienta en el catálogo
-- ---------------------------------------------------------------------
INSERT INTO ia_herramienta (nombre, permiso, escribe, critica, orden, descripcion, esquema) VALUES
('preparar_aviso_dueno', 'avisos.enviar', true, false, 290,
 'Envía un aviso o recordatorio por Telegram al dueño de una mascota: que ya está lista, '
 'que vence una vacuna, el resultado de un examen, una cita próxima. Necesita el dueno_id —que '
 'sale de buscar_dueno— y el texto del aviso. Solo puede hacerse si el dueño autorizó el '
 'contacto (consentimiento, Ley 1581 de 2012); si no lo autorizó, el aviso no se puede enviar '
 'por ningún canal. No envía nada sola: muestra la vista previa del mensaje y quién lo recibe, '
 'y espera confirmación. El envío sale por Telegram en segundo plano.',
 '{"type":"object","properties":{
    "dueno_id":{"type":"string","description":"UUID del dueño, que sale de buscar_dueno"},
    "mensaje":{"type":"string","description":"Texto del aviso que recibirá el dueño por Telegram. Cero HTML: lo escribes tú, se manda tal cual"}},
  "required":["dueno_id","mensaje"]}'::jsonb)
ON CONFLICT (nombre) DO UPDATE
  SET permiso = EXCLUDED.permiso, escribe = EXCLUDED.escribe, critica = EXCLUDED.critica,
      descripcion = EXCLUDED.descripcion, esquema = EXCLUDED.esquema, orden = EXCLUDED.orden;


-- ---------------------------------------------------------------------
-- 2. El borrador: vista previa del aviso (C6.9)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_aviso_dueno_borrador(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_dueno_id  uuid := NULLIF(p_args->>'dueno_id', '')::uuid;
  v_mensaje   text := NULLIF(trim(COALESCE(p_args->>'mensaje', '')), '');
  v_dueno     dueno%ROWTYPE;
  v_mascotas  text;
  v_resumen   text;
  v_accion    uuid;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'avisos.enviar');

  IF v_dueno_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta el dueño. Usa buscar_dueno y pasa su dueno_id.');
  END IF;

  SELECT * INTO v_dueno FROM dueno WHERE id = v_dueno_id AND activo;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Ese dueño ya no existe.');
  END IF;

  IF v_mensaje IS NULL OR length(v_mensaje) > 3000 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'El mensaje del aviso está vacío o es demasiado largo (máximo 3000 caracteres).');
  END IF;

  -- Ley 1581 de 2012 (§12): sin consentimiento o sin chat vinculado no hay
  -- canal, y este error se dice aquí para que ni se ofrezca la propuesta.
  IF NOT v_dueno.consentimiento_datos OR v_dueno.telegram_chat_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('«%s» no autorizó recibir mensajes o no tiene un chat de Telegram vinculado: '
             'ese dato está protegido por la Ley 1581 y no se puede enviar el aviso.',
             v_dueno.nombre_completo));
  END IF;

  SELECT string_agg(p.nombre, ', ' ORDER BY p.nombre) INTO v_mascotas
    FROM paciente p
   WHERE p.dueno_id = v_dueno_id AND p.estado = 'activo';

  v_resumen := '📨 <b>Aviso por Telegram</b>' || E'\n' ||
               'Para: <b>' || esc(v_dueno.nombre_completo) || '</b>' ||
               CASE WHEN v_mascotas IS NOT NULL
                    THEN ' (' || esc(v_mascotas) || ')' ELSE '' END || E'\n' ||
               'Canal: <b>Telegram</b> · autorizado ✓' || E'\n\n' ||
               '💬 <b>Mensaje a enviar:</b>' || E'\n' ||
               esc(v_mensaje) || E'\n\n' ||
               'Se manda exactamente así, en segundo plano, nada más confirmar.';

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, 'preparar_aviso_dueno',
          jsonb_build_object('dueno_id', v_dueno_id, 'mensaje', v_mensaje),
          v_resumen)
  RETURNING id INTO v_accion;

  RETURN jsonb_build_object('ok', true, 'requiere_confirmacion', true,
    'accion_id', v_accion, 'critica', false, 'resumen', v_resumen);
END;
$$;

-- ---------------------------------------------------------------------
-- 3. La ejecución: confirma la persona, se encola el envío (C6.10)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_aviso_dueno_ejecutar(p_usuario_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_dueno_id uuid := NULLIF(p_args->>'dueno_id', '')::uuid;
  v_mensaje  text := p_args->>'mensaje';
  v_dueno    dueno%ROWTYPE;
  v_tarea    bigint;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'avisos.enviar');

  SELECT * INTO v_dueno FROM dueno WHERE id = v_dueno_id AND activo;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese dueño ya no existe.');
  END IF;

  -- Se revalida el consentimiento al confirmar: pudo retirarse entre la
  -- vista previa y el botón (§12). Si se retiró, NO se envía.
  IF NOT v_dueno.consentimiento_datos OR v_dueno.telegram_chat_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
      'El dueño ya no autoriza el envío por Telegram: no se envió nada.');
  END IF;

  v_tarea := encolar_tarea('enviar_aviso_dueno',
    jsonb_build_object('dueno_id', v_dueno_id, 'mensaje', COALESCE(v_mensaje, '')),
    5, 'aviso_dueno_' || v_dueno_id::text || '_' || md5(COALESCE(v_mensaje, '')),
    0, 5);

  PERFORM auditar('dueno', v_dueno_id::text, 'avisar', p_usuario_id, 'telegram',
                  NULL, jsonb_build_object('mensaje', COALESCE(v_mensaje, '')),
                  'Aviso encolado para envío por Telegram');

  RETURN jsonb_build_object('ok', true,
    'mensaje', format('Aviso en camino para %s por Telegram.', v_dueno.nombre_completo),
    'dueno', v_dueno.nombre_completo,
    'tarea_id', v_tarea);
END;
$$;


-- ---------------------------------------------------------------------
-- 4. Enganches con el asistente
-- ---------------------------------------------------------------------

-- `preparar_aviso_dueno` tiene su propio borrador (validación de
-- consentimiento + vista previa), así que escapa del camino genérico de
-- escritura de ia_llamar, como el alta, la consulta, el despacho y la
-- pre-factura.
CREATE OR REPLACE FUNCTION ia_llamar(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  h        ia_herramienta%ROWTYPE;
  v_id     uuid;
  v_resumen text;
BEGIN
  SELECT * INTO h FROM ia_herramienta WHERE nombre = p_nombre AND activa;

  IF h.nombre IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', format('No existe una herramienta llamada %s.', p_nombre));
  END IF;

  IF h.permiso IS NOT NULL AND NOT tiene_permiso(p_usuario_id, h.permiso) THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'El usuario no tiene permiso para esto. Díselo con naturalidad y ofrécele '
               'otra cosa; no lo intentes por otro camino.');
  END IF;

  -- Herramientas cuyas propuestas se normalizan en la base (alta F1,
  -- borrador de consulta F2, despacho múltiple F3, pre-factura F4 y
  -- aviso a dueño F5): preparan su propuesta aquí y ya dejan
  -- `ia_accion_pendiente`.
  IF p_nombre IN ('preparar_alta_paciente', 'preparar_consulta_clinica',
                  'despachar_receta_multiple', 'cargar_paquete_servicios',
                  'aplicar_descuento_asistido', 'preparar_aviso_dueno') THEN
    CASE p_nombre
      WHEN 'preparar_alta_paciente'    THEN RETURN ia_alta_paciente_borrador(
        p_usuario_id, p_chat_id, p_sede_id, COALESCE(p_args, '{}'::jsonb));
      WHEN 'preparar_consulta_clinica' THEN RETURN ia_consulta_borrador(
        p_usuario_id, p_chat_id, p_sede_id, COALESCE(p_args, '{}'::jsonb));
      WHEN 'despachar_receta_multiple' THEN RETURN ia_despacho_borrador(
        p_usuario_id, p_chat_id, p_sede_id, COALESCE(p_args, '{}'::jsonb));
      WHEN 'cargar_paquete_servicios'  THEN RETURN ia_cargar_paquete_borrador(
        p_usuario_id, p_chat_id, p_sede_id, COALESCE(p_args, '{}'::jsonb));
      WHEN 'aplicar_descuento_asistido' THEN RETURN ia_aplicar_descuento_borrador(
        p_usuario_id, p_chat_id, p_sede_id, COALESCE(p_args, '{}'::jsonb));
      WHEN 'preparar_aviso_dueno'      THEN RETURN ia_aviso_dueno_borrador(
        p_usuario_id, p_chat_id, p_sede_id, COALESCE(p_args, '{}'::jsonb));
    END CASE;
  END IF;

  IF NOT h.escribe THEN
    BEGIN
      RETURN ia_leer(p_usuario_id, p_sede_id, p_nombre, COALESCE(p_args, '{}'::jsonb));
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  v_resumen := ia_resumen_accion(p_usuario_id, p_sede_id, p_nombre, COALESCE(p_args, '{}'::jsonb));

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, p_nombre, COALESCE(p_args, '{}'::jsonb), v_resumen)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'requiere_confirmacion', true,
    'accion_id', v_id,
    'critica', h.critica,
    'resumen', v_resumen);
END;
$$;

-- La confirmación encola el envío del aviso (no manda en línea).
CREATE OR REPLACE FUNCTION ia_escribir(
  p_usuario_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v jsonb;
BEGIN
  CASE p_nombre

    WHEN 'llamar_siguiente' THEN
      v := llamar_siguiente(p_usuario_id);

    WHEN 'crear_turno' THEN
      v := crear_turno_manual(
             p_usuario_id, p_sede_id,
             COALESCE(NULLIF(p_args->>'tipo', ''), 'general'),
             COALESCE((p_args->>'urgencia')::boolean, false),
             NULL, NULL, NULLIF(p_args->>'notas', ''));

    WHEN 'cambiar_estado_turno' THEN
      v := CASE p_args->>'accion'
             WHEN 'presento'  THEN iniciar_atencion(p_usuario_id, (p_args->>'turno_id')::uuid)
             WHEN 'ausente'   THEN marcar_ausente(p_usuario_id, (p_args->>'turno_id')::uuid)
             WHEN 'finalizar' THEN finalizar_turno(p_usuario_id, (p_args->>'turno_id')::uuid)
             WHEN 'reencolar' THEN reencolar_turno(p_usuario_id, (p_args->>'turno_id')::uuid)
             ELSE jsonb_build_object('ok', false, 'mensaje', 'Esa acción sobre el turno no existe.')
           END;

    WHEN 'registrar_salida_medicamento' THEN
      v := salida_medicamento(
             p_usuario_id, (p_args->>'lote_id')::uuid, (p_args->>'cantidad')::numeric,
             NULLIF(p_args->>'motivo', ''));

    WHEN 'agregar_servicio_a_cuenta' THEN
      v := agregar_linea_servicio(
             p_usuario_id, (p_args->>'cuenta_id')::uuid,
             NULLIF(p_args->>'tarifa_id', '')::uuid,
             NULLIF(p_args->>'valor', '')::numeric,
             COALESCE((p_args->>'cantidad')::numeric, 1),
             NULLIF(p_args->>'descripcion', ''));

    WHEN 'cobrar_cuenta' THEN
      v := registrar_pago(
             p_usuario_id, (p_args->>'cuenta_id')::uuid, p_args->>'medio',
             NULLIF(p_args->>'valor', '')::numeric,
             NULLIF(p_args->>'referencia', ''));

    WHEN 'preparar_alta_paciente' THEN
      v := ia_alta_paciente_ejecutar(p_usuario_id, p_args);

    WHEN 'preparar_consulta_clinica' THEN
      v := ia_consulta_ejecutar(p_usuario_id, p_args);

    WHEN 'despachar_receta_multiple' THEN
      v := ia_despacho_ejecutar(p_usuario_id, p_args);

    WHEN 'cargar_paquete_servicios' THEN
      v := ia_paquete_ejecutar(p_usuario_id, p_args);

    WHEN 'aplicar_descuento_asistido' THEN
      v := ia_descuento_ejecutar(p_usuario_id, p_args);

    WHEN 'preparar_aviso_dueno' THEN
      v := ia_aviso_dueno_ejecutar(p_usuario_id, p_args);

    ELSE
      RETURN jsonb_build_object('ok', false,
        'mensaje', format('La herramienta %s no existe.', p_nombre));
  END CASE;

  RETURN v;
END;
$$;

-- Resultado que ve la persona tras confirmar: el aviso quedó en camino.
CREATE OR REPLACE FUNCTION ia_texto_resultado(p_herramienta text, p_resultado jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(esc(p_resultado->>'mensaje'), ''),
    CASE p_herramienta
      WHEN 'crear_turno' THEN
        'Turno <b>' || esc(p_resultado->'turno'->>'codigo') || '</b> creado.'
      WHEN 'llamar_siguiente' THEN
        'Llamaste el turno <b>' || esc(p_resultado->'turno'->>'codigo') || '</b>.'
      WHEN 'registrar_salida_medicamento' THEN
        esc(p_resultado->'movimiento'->>'medicamento') || ': quedan <b>' ||
        fmt_cant((p_resultado->'movimiento'->>'restante')::numeric) || ' ' ||
        esc(p_resultado->'movimiento'->>'unidad') || '</b>.'
      WHEN 'agregar_servicio_a_cuenta' THEN
        'La cuenta va en <b>' || pesos((p_resultado->'cuenta'->>'total')::numeric) || '</b>.'
      WHEN 'cobrar_cuenta' THEN
        CASE WHEN COALESCE((p_resultado->'cuenta'->>'pendiente')::numeric, 0) > 0
             THEN 'Falta <b>' || pesos((p_resultado->'cuenta'->>'pendiente')::numeric) || '</b>.'
             ELSE 'Cuenta saldada.' END ||
        CASE WHEN COALESCE((p_resultado->>'vuelto')::numeric, 0) > 0
             THEN ' Devuelve <b>' || pesos((p_resultado->>'vuelto')::numeric) || '</b>.'
             ELSE '' END
      WHEN 'preparar_alta_paciente' THEN
        'Quedó registrada <b>' || esc(p_resultado->'paciente'->>'nombre') || '</b>' ||
        ' (' || esc(nombre_especie(p_resultado->'paciente'->>'especie')) || ').'
      WHEN 'preparar_consulta_clinica' THEN
        'Quedó el borrador de <b>' || esc(p_resultado->'consulta'->'paciente'->>'nombre') || '</b>.' ||
        E'\n' || '<i>Es un borrador: no es registro clínico hasta que lo firmes.</i>' ||
        E'\n' || '🔗 Revísalo y fírmalo aquí: ' ||
        esc(rtrim(config_txt('portal_url', 'http://localhost:3100'), '/') ||
            '/consulta/' || (p_resultado->'consulta'->>'consulta_id'))
      WHEN 'despachar_receta_multiple' THEN
        'Despachados <b>' || esc(p_resultado->'despacho'->>'productos') || '</b> medicamento(s) por <b>' ||
        pesos((p_resultado->'despacho'->>'total')::numeric) || '</b>.'
      WHEN 'cargar_paquete_servicios' THEN
        '🧾 <b>Pre-factura lista.</b> Subtotal <b>' ||
        pesos((p_resultado->'cuenta'->>'subtotal')::numeric) || '</b>' ||
        CASE WHEN COALESCE((p_resultado->'cuenta'->>'descuento')::numeric, 0) > 0
             THEN ' · Descuento −<b>' ||
                  pesos((p_resultado->'cuenta'->>'descuento')::numeric) || '</b>'
             ELSE '' END ||
        ' · Total <b>' || pesos((p_resultado->'cuenta'->>'total')::numeric) || '</b>.'
      WHEN 'aplicar_descuento_asistido' THEN
        '🧾 <b>Pre-factura:</b> Subtotal <b>' ||
        pesos((p_resultado->'cuenta'->>'subtotal')::numeric) || '</b>' ||
        ' · Descuento −<b>' ||
        pesos((p_resultado->'cuenta'->>'descuento')::numeric) || '</b>' ||
        ' · Total <b>' || pesos((p_resultado->'cuenta'->>'total')::numeric) || '</b>.'
      WHEN 'preparar_aviso_dueno' THEN
        '📨 Aviso en camino para <b>' || esc(p_resultado->>'dueno') || '</b> por Telegram.'
      ELSE NULL
    END);
$$;

-- Bienvenida: ejemplos para quien avisa a los clientes con el asistente.
CREATE OR REPLACE FUNCTION bot_ia_bienvenida(p_usuario_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE v_ej text := '';
BEGIN
  IF tiene_permiso(p_usuario_id, 'turnos.ver') THEN
    v_ej := v_ej || E'\n' || '· «¿cómo va la cola?»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'inventario.ver') THEN
    v_ej := v_ej || E'\n' || '· «¿cuánta amoxicilina queda?»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'inventario.salida') THEN
    v_ej := v_ej || E'\n' || '· «despacha 2 amoxicilina y 1 metronidazol»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'cobro.ver') THEN
    v_ej := v_ej || E'\n' || '· «¿qué falta por cobrar hoy?»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'cobro.linea') THEN
    v_ej := v_ej || E'\n' || '· «cárgale a la cuenta de Luna la consulta y el antipulgas»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'cobro.descuento') THEN
    v_ej := v_ej || E'\n' || '· «aplícale un descuento del 10 % a la cuenta de Luna»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'pacientes.ver') THEN
    v_ej := v_ej || E'\n' || '· «tráeme la historia de Luna»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'consulta.crear') THEN
    v_ej := v_ej || E'\n' || '· «déjame el borrador de Luna: vómito, 4.2 kg, gastroenteritis»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'pacientes.editar') THEN
    v_ej := v_ej || E'\n' || '· «registra a Luna, gata de 2 años, dueña María Gómez»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'avisos.enviar') THEN
    v_ej := v_ej || E'\n' || '· «avísale a la dueña de Luna que ya está lista para recoger»';
  END IF;

  RETURN '💬 <b>Habla con Chasqui</b>' || E'\n\n' ||
         'Escríbeme como le escribirías a un compañero. Consulto los datos reales de ' ||
         esc(config_txt('nombre_clinica', 'Chasqui Pet')) || ' y también te explico cómo ' ||
         'funciona algo de la clínica.' ||
         CASE WHEN v_ej <> '' THEN E'\n\n' || 'Por ejemplo:' || v_ej ELSE '' END ||
         E'\n\n' || 'Si te ayudo con algo que <b>cambia</b> datos —llamar un turno, sacar un ' ||
         'medicamento, registrar un pago, enviar un aviso— te muestro primero qué va a pasar y lo confirmas tú.' ||
         E'\n\n' || 'Para volver a los botones, escribe /menu.';
END;
$$;

GRANT SELECT ON ia_herramienta TO chasquipet_app;