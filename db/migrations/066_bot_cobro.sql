-- =====================================================================
-- Chasqui Pet — 066_bot_cobro.sql
-- Cobro desde el chat (§7.2): abrir la cuenta, ver el detalle, registrar
-- el pago y cerrar. Y el cuadre de caja al final del día.
--
-- Quien cobra está de pie en recepción, con el dueño enfrente y la fila
-- detrás. De ahí las reglas de este archivo:
--
--   1. La ruta feliz es de tres toques: [💵 Cobrar] → [la cuenta] →
--      [💵 Efectivo]. El valor no se pregunta: por defecto es lo que
--      falta, que es lo que se cobra el 95 % de las veces.
--   2. Los medicamentos ya están en la cuenta sin que nadie los teclee:
--      los puso el worker al despacharlos (§6.3).
--   3. Lo que mueve dinero muestra siempre el total antes de tocarlo, y
--      nada se registra en dos pasos distintos: un pago es un toque.
--   4. El descuento pide motivo escrito y sólo lo ve quien tiene el
--      permiso (§7.3). No aparece como botón para los demás.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Botones propios en el menú principal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_cob_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_fila jsonb := '[]'::jsonb;
BEGIN
  IF tiene_permiso(p_usuario_id, 'cobro.ver') THEN
    v_fila := v_fila || jsonb_build_object('t', '💵 Cobrar', 'd', 'cob:cobrar');
  END IF;
  IF tiene_permiso(p_usuario_id, 'caja.cerrar') THEN
    v_fila := v_fila || jsonb_build_object('t', '🧾 Caja', 'd', 'cob:caja');
  END IF;

  IF jsonb_array_length(v_fila) = 0 THEN RETURN '[]'::jsonb; END IF;
  RETURN jsonb_build_array(v_fila);
END;
$$;

-- ---------------------------------------------------------------------
-- Piezas de interfaz
-- ---------------------------------------------------------------------

-- Las cuentas que esperan cobro. Primero las de los turnos ya
-- finalizados: ese dueño está en el mostrador ahora mismo.
CREATE OR REPLACE FUNCTION bot_cob_pendientes(p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb; v_n int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', CASE WHEN estado_turno = 'finalizado' THEN '✅ ' ELSE '🩺 ' END ||
                COALESCE(turno || ' · ', '') || paciente || ' · ' ||
                CASE WHEN total = 0 THEN 'sin cobros' ELSE pesos(pendiente) END,
           'd', 'cob:cta:' || cuenta_id))), '[]'::jsonb),
         count(*)
    INTO v_bot, v_n
    FROM cuentas_abiertas(p_sede_id, 8);

  IF v_n = 0 THEN
    RETURN jsonb_build_object('texto',
      '💵 <b>Cobro</b>' || E'\n' || 'No hay cuentas abiertas ahora mismo.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'cob:cancelar'))));
  END IF;

  RETURN jsonb_build_object('texto',
    format('💵 <b>Cuentas abiertas</b> · %s%s✅ = ya terminó la consulta.', v_n, E'\n'),
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Menú', 'd', 'cob:cancelar'))));
END;
$$;

-- El detalle de la cuenta: lo que se va a cobrar y qué se puede hacer con
-- ella. Los botones dependen del permiso y de lo que falte por pagar.
CREATE OR REPLACE FUNCTION bot_cob_cuenta(p_cuenta_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  c jsonb := cuenta_json(p_cuenta_id);
  v_texto text;
  v_lineas text;
  v_pagos text;
  v_bot jsonb := '[]'::jsonb;
  v_fila jsonb := '[]'::jsonb;
  v_pendiente numeric;
BEGIN
  IF c IS NULL THEN
    RETURN jsonb_build_object('texto', 'Esa cuenta ya no existe.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'cob:cancelar'))));
  END IF;

  v_pendiente := (c->>'pendiente')::numeric;

  v_texto := format('%s <b>%s</b>%s',
               COALESCE(c->>'especie_emoji', '🐾'),
               esc(COALESCE(c->>'paciente', 'Sin paciente')),
               CASE WHEN c->>'turno' IS NOT NULL
                    THEN ' · turno ' || esc(c->>'turno') ELSE '' END);

  IF c->>'dueno' IS NOT NULL THEN
    v_texto := v_texto || E'\n' || '👤 ' || esc(c->>'dueno');
  END IF;

  SELECT string_agg(format('• %s%s · %s',
                           esc(l->>'descripcion'),
                           CASE WHEN (l->>'cantidad')::numeric <> 1
                                THEN ' ×' || fmt_cant((l->>'cantidad')::numeric) ELSE '' END,
                           pesos((l->>'valor_total')::numeric)), E'\n')
    INTO v_lineas FROM jsonb_array_elements(c->'lineas') l;

  v_texto := v_texto || E'\n\n' ||
             COALESCE(v_lineas, '<i>La cuenta está vacía: agrega el servicio.</i>');

  IF (c->>'descuento')::numeric > 0 THEN
    v_texto := v_texto || E'\n\n' ||
               format('Subtotal: %s%sDescuento: −%s',
                      pesos((c->>'subtotal')::numeric), E'\n',
                      pesos((c->>'descuento')::numeric));
  END IF;

  v_texto := v_texto || E'\n\n' || format('<b>Total: %s</b>', pesos((c->>'total')::numeric));

  SELECT string_agg(format('%s %s %s %s', x->>'emoji',
                           CASE WHEN x->>'tipo' = 'reverso' THEN 'Reverso' ELSE 'Pagado' END,
                           esc(x->>'medio_nombre'), pesos((x->>'valor')::numeric)), E'\n')
    INTO v_pagos FROM jsonb_array_elements(c->'pagos') x;

  IF v_pagos IS NOT NULL THEN
    v_texto := v_texto || E'\n' || v_pagos;
    v_texto := v_texto || E'\n' || format('Falta: <b>%s</b>', pesos(v_pendiente));
  END IF;

  IF c->>'estado' <> 'abierta' THEN
    v_texto := v_texto || E'\n\n' ||
      CASE c->>'estado'
        WHEN 'cerrada' THEN format('✅ Cerrada · recibo N.° %s', c->>'recibo_numero')
        ELSE '🚫 Anulada: ' || esc(COALESCE(c->>'motivo_anulacion', ''))
      END;

    RETURN jsonb_build_object('texto', v_texto, 'botones', jsonb_build_array(
      jsonb_build_array(
        jsonb_build_object('t', '💵 Otra cuenta', 'd', 'cob:cobrar'),
        jsonb_build_object('t', '⬅️ Menú', 'd', 'cob:cancelar'))));
  END IF;

  -- Fila 1: el dinero. Es lo que casi siempre se viene a hacer.
  IF tiene_permiso(p_usuario_id, 'cobro.pago') AND v_pendiente > 0 THEN
    v_fila := v_fila || jsonb_build_object('t', '💵 Cobrar ' || pesos(v_pendiente),
                                           'd', 'cob:pagar');
  END IF;
  IF tiene_permiso(p_usuario_id, 'cobro.pago') AND v_pendiente = 0
     AND (c->>'total')::numeric >= 0 THEN
    v_fila := v_fila || jsonb_build_object('t', '🧾 Cerrar y dar recibo', 'd', 'cob:cerrar');
  END IF;
  IF jsonb_array_length(v_fila) > 0 THEN
    v_bot := v_bot || jsonb_build_array(v_fila);
    v_fila := '[]'::jsonb;
  END IF;

  -- Fila 2: armar la cuenta.
  IF tiene_permiso(p_usuario_id, 'cobro.linea') THEN
    v_fila := v_fila || jsonb_build_object('t', '➕ Servicio', 'd', 'cob:serv');
    IF jsonb_array_length(c->'lineas') > 0 THEN
      v_fila := v_fila || jsonb_build_object('t', '➖ Quitar', 'd', 'cob:quitar');
    END IF;
  END IF;
  IF tiene_permiso(p_usuario_id, 'cobro.descuento') AND (c->>'subtotal')::numeric > 0 THEN
    v_fila := v_fila || jsonb_build_object('t', '🏷️ Descuento', 'd', 'cob:desc');
  END IF;
  IF jsonb_array_length(v_fila) > 0 THEN
    v_bot := v_bot || jsonb_build_array(v_fila);
  END IF;

  RETURN jsonb_build_object('texto', v_texto,
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '💵 Otra cuenta', 'd', 'cob:cobrar'),
      jsonb_build_object('t', '⬅️ Menú', 'd', 'cob:cancelar'))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_cob_tarifas()
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', nombre || CASE WHEN permite_valor_libre THEN ' · ✏️'
                               ELSE ' · ' || pesos(valor_sugerido) END,
           'd', 'cob:tar:' || tarifa_id))), '[]'::jsonb)
    INTO v_bot
    FROM tarifas_activas(10);

  IF jsonb_array_length(v_bot) = 0 THEN
    RETURN jsonb_build_object('texto',
      'No hay tarifas configuradas todavía. Se cargan desde el portal.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));
  END IF;

  RETURN jsonb_build_object('texto',
    '➕ <b>Agregar al cobro</b>' || E'\n' || '✏️ = el valor se escribe.',
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));
END;
$$;

-- Cuadre de caja. El texto tiene que poder leerse en voz alta mientras se
-- cuentan los billetes.
CREATE OR REPLACE FUNCTION bot_cob_caja(p_sede_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_id uuid := caja_abierta(p_sede_id);
  k jsonb;
  r jsonb := resumen_caja_dia(p_sede_id);
  v_texto text;
  v_bot jsonb := '[]'::jsonb;
BEGIN
  IF v_id IS NULL THEN
    v_texto := format('🧾 <b>Caja</b> · %s%sNo hay caja abierta.%sHoy se cerraron %s cuenta(s) por %s.',
                 to_char(hoy_bogota(), 'DD/MM/YYYY'), E'\n', E'\n',
                 r->>'cuentas_cerradas', pesos((r->>'total_ingresos')::numeric));

    IF (r->>'por_cobrar')::numeric > 0 THEN
      v_texto := v_texto || E'\n' ||
                 format('⚠️ Quedan %s por cobrar en %s cuenta(s) abierta(s).',
                        pesos((r->>'por_cobrar')::numeric), r->>'cuentas_abiertas');
    END IF;

    RETURN jsonb_build_object('texto', v_texto, 'botones', jsonb_build_array(
      jsonb_build_array(jsonb_build_object('t', '🔓 Abrir caja', 'd', 'cob:cajabrir')),
      jsonb_build_array(jsonb_build_object('t', '⬅️ Menú', 'd', 'cob:cancelar'))));
  END IF;

  k := caja_json(v_id);

  v_texto := format('🧾 <b>Caja del %s</b>%sAbierta %s por %s.%s',
               to_char((k->>'fecha')::date, 'DD/MM/YYYY'), E'\n',
               k->>'abierta_at', esc(COALESCE(k->>'abierta_por', '—')), E'\n');

  v_texto := v_texto || E'\n' || concat_ws(E'\n',
    format('Base inicial: %s', pesos((k->>'base_inicial')::numeric)),
    format('💵 Efectivo recibido: %s', pesos((k->>'efectivo_recibido')::numeric)),
    format('📲 Transferencias: %s', pesos((k->>'transferencia')::numeric)),
    format('💳 Datáfono: %s', pesos((k->>'datafono')::numeric)),
    format('🏷️ Descuentos: %s', pesos((k->>'descuentos')::numeric)),
    format('🧾 Cuentas cerradas: %s', k->>'cuentas'));

  v_texto := v_texto || E'\n\n' ||
             format('<b>Debe haber en caja: %s</b>', pesos((k->>'efectivo')::numeric));

  IF (r->>'por_cobrar')::numeric > 0 THEN
    v_texto := v_texto || E'\n' ||
               format('⚠️ Faltan %s por cobrar en %s cuenta(s).',
                      pesos((r->>'por_cobrar')::numeric), r->>'cuentas_abiertas');
  END IF;

  IF tiene_permiso(p_usuario_id, 'caja.cerrar') THEN
    v_bot := jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '🔒 Cerrar caja', 'd', 'cob:cajacerrar')));
  END IF;

  RETURN jsonb_build_object('texto', v_texto,
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '💵 Cobrar', 'd', 'cob:cobrar'),
      jsonb_build_object('t', '⬅️ Menú', 'd', 'cob:cancelar'))));
END;
$$;

-- ---------------------------------------------------------------------
-- Callbacks de cobro
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_cob_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_partes text[] := string_to_array(p_data, ':');
  v_estado jsonb;
  v_datos  jsonb;
  v_vista  jsonb;
  v_alerta text := NULL;
  v_r      jsonb;
  v_cuenta uuid;
  v_tarifa tarifa;
  v_bot    jsonb;
BEGIN
  IF v_partes[1] <> 'cob' THEN
    RETURN NULL;
  END IF;

  v_estado := estado_leer(p_chat_id);
  v_datos  := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_cuenta := NULLIF(v_datos->>'cuenta_id', '')::uuid;

  CASE v_partes[2]

    -- --- Entrada al módulo -----------------------------------------
    WHEN 'cobrar' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.ver');
      PERFORM estado_limpiar(p_chat_id);
      PERFORM estado_guardar(p_chat_id, 'cobro', 'elegir', '{}'::jsonb,
                             p_usuario_id, p_mensaje_id);
      v_vista := bot_cob_pendientes(p_sede_id);

    WHEN 'cta' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.ver');
      v_cuenta := v_partes[3]::uuid;
      PERFORM estado_guardar(p_chat_id, 'cobro', 'cuenta',
                jsonb_build_object('cuenta_id', v_cuenta), p_usuario_id, p_mensaje_id);
      v_vista := bot_cob_cuenta(v_cuenta, p_usuario_id);

    WHEN 'volver' THEN
      IF v_cuenta IS NULL THEN
        v_vista := bot_cob_pendientes(p_sede_id);
      ELSE
        PERFORM estado_guardar(p_chat_id, 'cobro', 'cuenta', v_datos, p_usuario_id, p_mensaje_id);
        v_vista := bot_cob_cuenta(v_cuenta, p_usuario_id);
      END IF;

    -- --- Líneas ------------------------------------------------------
    WHEN 'serv' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.linea');
      v_vista := bot_cob_tarifas();

    WHEN 'tar' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.linea');
      SELECT * INTO v_tarifa FROM tarifa WHERE id = v_partes[3]::uuid;

      IF v_tarifa.permite_valor_libre THEN
        -- Lo que se cobra por peso o por acuerdo: el valor se escribe.
        PERFORM estado_guardar(p_chat_id, 'cobro', 'valor_libre',
                  v_datos || jsonb_build_object('tarifa_id', v_partes[3]),
                  p_usuario_id, p_mensaje_id);
        v_vista := jsonb_build_object('texto',
          format('✏️ <b>%s</b>%s¿Cuánto se cobra? Escribe el valor.',
                 esc(v_tarifa.nombre), E'\n'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));
      ELSE
        v_r := agregar_linea_servicio(p_usuario_id, v_cuenta, v_partes[3]::uuid);
        IF (v_r->>'ok')::boolean THEN
          v_alerta := v_tarifa.nombre || ' agregado';
        ELSE
          v_alerta := v_r->>'mensaje';
        END IF;
        PERFORM estado_guardar(p_chat_id, 'cobro', 'cuenta', v_datos, p_usuario_id, p_mensaje_id);
        v_vista := bot_cob_cuenta(v_cuenta, p_usuario_id);
      END IF;

    WHEN 'quitar' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.linea');
      SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
               't', CASE WHEN (l->>'de_inventario')::boolean THEN '💊 ' ELSE '➖ ' END ||
                    (l->>'descripcion') || ' · ' || pesos((l->>'valor_total')::numeric),
               'd', 'cob:quitarl:' || (l->>'linea_id')))), '[]'::jsonb)
        INTO v_bot
        FROM jsonb_array_elements(cuenta_json(v_cuenta)->'lineas') l;

      v_vista := jsonb_build_object('texto',
        '➖ <b>Quitar de la cuenta</b>' || E'\n' ||
        'Las marcadas con 💊 salieron del inventario: para quitarlas hay que ' ||
        'registrar la devolución del medicamento.',
        'botones', v_bot || jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));

    WHEN 'quitarl' THEN
      v_r := quitar_linea(p_usuario_id, v_partes[3]::uuid);
      v_alerta := CASE WHEN (v_r->>'ok')::boolean THEN 'Línea quitada'
                       ELSE v_r->>'mensaje' END;
      PERFORM estado_guardar(p_chat_id, 'cobro', 'cuenta', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := bot_cob_cuenta(v_cuenta, p_usuario_id);

    -- --- Descuento (§7.3) --------------------------------------------
    WHEN 'desc' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.descuento');
      PERFORM estado_guardar(p_chat_id, 'cobro', 'descuento_valor', v_datos,
                             p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '🏷️ <b>Descuento</b>' || E'\n' ||
        'Escribe cuánto se rebaja (en pesos). Después te pido el motivo.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));

    -- --- Pago ---------------------------------------------------------
    WHEN 'pagar' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.pago');
      PERFORM estado_guardar(p_chat_id, 'cobro', 'medio', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        format('💵 <b>Cobrar %s</b>%s¿Cómo paga?',
               pesos((cuenta_json(v_cuenta)->>'pendiente')::numeric), E'\n'),
        'botones', jsonb_build_array(
          jsonb_build_array(
            jsonb_build_object('t', '💵 Efectivo',      'd', 'cob:medio:efectivo'),
            jsonb_build_object('t', '📲 Transferencia', 'd', 'cob:medio:transferencia'),
            jsonb_build_object('t', '💳 Datáfono',      'd', 'cob:medio:datafono')),
          jsonb_build_array(jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));

    -- El pago completo es un solo toque: es lo que pasa casi siempre.
    WHEN 'medio' THEN
      v_r := registrar_pago(p_usuario_id, v_cuenta, v_partes[3]);

      IF (v_r->>'ok')::boolean THEN
        v_alerta := 'Pago registrado';
        PERFORM estado_guardar(p_chat_id, 'cobro', 'cuenta', v_datos, p_usuario_id, p_mensaje_id);
        v_vista := bot_cob_cuenta(v_cuenta, p_usuario_id);
      ELSE
        v_alerta := v_r->>'mensaje';
        v_vista := bot_cob_cuenta(v_cuenta, p_usuario_id);
      END IF;

    -- --- Cierre de la cuenta -----------------------------------------
    WHEN 'cerrar' THEN
      v_r := cerrar_cuenta(p_usuario_id, v_cuenta);

      IF (v_r->>'ok')::boolean THEN
        PERFORM estado_limpiar(p_chat_id);
        v_alerta := 'Recibo N.° ' || (v_r->'cuenta'->>'recibo_numero');
        v_vista := jsonb_build_object('texto',
          recibo_texto(v_cuenta) ||
          CASE WHEN (v_r->'cuenta'->>'chat_id') IS NOT NULL
                AND (v_r->'cuenta'->>'consentimiento')::boolean
               THEN E'\n' || '📲 Se le envió al dueño por Telegram.'
               ELSE '' END,
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '💵 Otra cuenta', 'd', 'cob:cobrar'),
            jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))));
      ELSE
        v_alerta := v_r->>'mensaje';
        v_vista := bot_cob_cuenta(v_cuenta, p_usuario_id);
      END IF;

    -- --- Caja ---------------------------------------------------------
    WHEN 'caja' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.ver');
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_cob_caja(p_sede_id, p_usuario_id);

    WHEN 'cajabrir' THEN
      PERFORM exigir_permiso(p_usuario_id, 'caja.cerrar');
      PERFORM estado_guardar(p_chat_id, 'cobro', 'caja_base', '{}'::jsonb,
                             p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '🔓 <b>Abrir caja</b>' || E'\n' ||
        'Escribe con cuánta base arranca la caja. Si no hay base, escribe 0.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '🚫 Cancelar', 'd', 'cob:cancelar'))));

    WHEN 'cajacerrar' THEN
      PERFORM exigir_permiso(p_usuario_id, 'caja.cerrar');
      PERFORM estado_guardar(p_chat_id, 'cobro', 'caja_contado',
                jsonb_build_object('caja_id', caja_abierta(p_sede_id)),
                p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '🔒 <b>Cerrar caja</b>' || E'\n' ||
        'Cuenta el efectivo que hay en el cajón —incluida la base— y escribe el total.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '🚫 Cancelar', 'd', 'cob:caja'))));

    WHEN 'cancelar' THEN
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_menu_principal(p_usuario_id);

    ELSE
      v_alerta := 'Esa opción ya no está disponible.';
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_menu_principal(p_usuario_id);
  END CASE;

  RETURN jsonb_build_object(
    'alerta', v_alerta,
    'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;

-- ---------------------------------------------------------------------
-- Texto libre de cobro: valores, motivos y conteo de caja
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_cob_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado jsonb := estado_leer(p_chat_id);
  v_flujo  text  := v_estado->>'flujo';
  v_paso   text  := v_estado->>'paso';
  v_datos  jsonb := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_cuenta uuid  := NULLIF(v_datos->>'cuenta_id', '')::uuid;
  v_vista  jsonb;
  v_r      jsonb;
  v_valor  numeric;
BEGIN
  -- Comandos sueltos, sin pasar por el menú.
  IF p_texto IN ('/caja', 'caja') AND tiene_permiso(p_usuario_id, 'cobro.ver') THEN
    v_vista := bot_cob_caja(p_sede_id, p_usuario_id);
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
  END IF;

  IF p_texto IN ('/cobrar', 'cobrar') AND tiene_permiso(p_usuario_id, 'cobro.ver') THEN
    PERFORM estado_guardar(p_chat_id, 'cobro', 'elegir', '{}'::jsonb, p_usuario_id);
    v_vista := bot_cob_pendientes(p_sede_id);
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
  END IF;

  IF v_flujo IS DISTINCT FROM 'cobro' THEN
    RETURN NULL;   -- no es nuestro: que siga el enrutador
  END IF;

  CASE v_paso

    -- Valor de una tarifa libre.
    WHEN 'valor_libre' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.linea');
      v_valor := parse_pesos(p_texto);

      IF v_valor IS NULL THEN
        v_vista := jsonb_build_object('texto',
          '⚠️ «' || esc(p_texto) || '» no es un valor. Escribe sólo el número, por ejemplo 45000.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));
      ELSE
        v_r := agregar_linea_servicio(p_usuario_id, v_cuenta,
                 NULLIF(v_datos->>'tarifa_id', '')::uuid, v_valor);
        PERFORM estado_guardar(p_chat_id, 'cobro', 'cuenta', v_datos, p_usuario_id);
        IF (v_r->>'ok')::boolean THEN
          v_vista := bot_cob_cuenta(v_cuenta, p_usuario_id);
        ELSE
          v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
            'botones', jsonb_build_array(jsonb_build_array(
              jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));
        END IF;
      END IF;

    -- Descuento: primero cuánto, después por qué. El motivo es
    -- obligatorio, así que se pide en su propio paso y no se puede saltar.
    WHEN 'descuento_valor' THEN
      PERFORM exigir_permiso(p_usuario_id, 'cobro.descuento');
      v_valor := parse_pesos(p_texto);

      IF v_valor IS NULL OR v_valor <= 0 THEN
        v_vista := jsonb_build_object('texto',
          '⚠️ Escribe cuánto se rebaja, sólo el número. Por ejemplo 10000.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));
      ELSE
        PERFORM estado_guardar(p_chat_id, 'cobro', 'descuento_motivo',
                  v_datos || jsonb_build_object('descuento_valor', v_valor), p_usuario_id);
        v_vista := jsonb_build_object('texto',
          format('🏷️ Descuento de %s.%s¿Por qué? (queda registrado con tu nombre)',
                 pesos(v_valor), E'\n'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '🚫 Cancelar', 'd', 'cob:volver'))));
      END IF;

    WHEN 'descuento_motivo' THEN
      v_r := aplicar_descuento(p_usuario_id, v_cuenta,
               (v_datos->>'descuento_valor')::numeric, p_texto);
      PERFORM estado_guardar(p_chat_id, 'cobro', 'cuenta', v_datos, p_usuario_id);

      IF (v_r->>'ok')::boolean THEN
        v_vista := bot_cob_cuenta(v_cuenta, p_usuario_id);
      ELSE
        v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:volver'))));
      END IF;

    -- Apertura y cierre de caja.
    WHEN 'caja_base' THEN
      v_valor := COALESCE(parse_pesos(p_texto), 0);
      v_r := abrir_caja(p_usuario_id, p_sede_id, v_valor);
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_cob_caja(p_sede_id, p_usuario_id);

    WHEN 'caja_contado' THEN
      v_valor := parse_pesos(p_texto);

      IF v_valor IS NULL THEN
        v_vista := jsonb_build_object('texto',
          '⚠️ Escribe cuánto efectivo hay contado, sólo el número.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '🚫 Cancelar', 'd', 'cob:caja'))));
      ELSE
        v_r := cerrar_caja(p_usuario_id, NULLIF(v_datos->>'caja_id', '')::uuid, v_valor);

        IF (v_r->>'ok')::boolean THEN
          PERFORM estado_limpiar(p_chat_id);
          v_vista := jsonb_build_object('texto',
            format('🔒 <b>Caja cerrada</b>%sEsperado: %s%sContado: %s%s%s',
                   E'\n',
                   pesos((v_r->'caja'->>'efectivo')::numeric), E'\n',
                   pesos((v_r->'caja'->>'contado')::numeric), E'\n',
                   CASE WHEN (v_r->'caja'->>'diferencia')::numeric = 0
                        THEN '✅ Cuadra exacto.'
                        WHEN (v_r->'caja'->>'diferencia')::numeric > 0
                        THEN format('⚠️ Sobran %s.', pesos((v_r->'caja'->>'diferencia')::numeric))
                        ELSE format('⚠️ Faltan %s.',
                                    pesos(-(v_r->'caja'->>'diferencia')::numeric)) END),
            'botones', jsonb_build_array(jsonb_build_array(
              jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))));
        ELSE
          v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
            'botones', jsonb_build_array(jsonb_build_array(
              jsonb_build_object('t', '💵 Cobrar', 'd', 'cob:cobrar'),
              jsonb_build_object('t', '⬅️ Volver', 'd', 'cob:caja'))));
        END IF;
      END IF;

    ELSE
      RETURN NULL;
  END CASE;

  RETURN jsonb_build_object('acciones', jsonb_build_array(
    accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;

-- ---------------------------------------------------------------------
-- Despachadores: se añade cobro a los módulos anteriores
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_cli_menu(p_usuario_id) || bot_inv_menu(p_usuario_id)
      || bot_cob_menu(p_usuario_id);
$$;

CREATE OR REPLACE FUNCTION bot_modulo_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_inv_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_cli_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_cob_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_auth_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_modulo_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_auth_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_inv_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cob_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cli_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_texto_ayuda(p_usuario_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT '<b>Comandos</b>' || E'\n' ||
         '/menu — menú principal' || E'\n' ||
         '/cola — pacientes en espera' || E'\n' ||
         '/stock — existencias y alertas de inventario' || E'\n' ||
         '/cobrar — cuentas abiertas por cobrar' || E'\n' ||
         '/caja — estado de la caja del día' || E'\n' ||
         '/sesiones — sesiones abiertas en el portal' || E'\n' ||
         '/ayuda — esta ayuda';
$$;

-- Al finalizar el turno, lo que sigue es cobrar. El botón lo pone aquí el
-- módulo de cobro, sin tocar el enrutador de turnos: bot_tarjeta_turno se
-- reescribe añadiendo la cuenta cuando la hay.
CREATE OR REPLACE FUNCTION bot_tarjeta_turno(p_turno_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  t jsonb := turno_json(p_turno_id);
  v_texto text;
  v_botones jsonb := '[]'::jsonb;
  v_cuenta jsonb;
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

  IF t->>'cuenta_id' IS NOT NULL THEN
    v_cuenta := cuenta_json((t->>'cuenta_id')::uuid);

    IF v_cuenta->>'estado' = 'abierta' THEN
      v_texto := v_texto || E'\n' ||
                 format('💵 Cuenta: %s', pesos((v_cuenta->>'total')::numeric));
      v_botones := jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '💵 Ver cuenta', 'd', 'cob:cta:' || (v_cuenta->>'cuenta_id'))));
    ELSIF v_cuenta->>'estado' = 'cerrada' THEN
      v_texto := v_texto || E'\n' ||
                 format('🧾 Cobrado %s · recibo N.° %s',
                        pesos((v_cuenta->>'total')::numeric), v_cuenta->>'recibo_numero');
    END IF;
  END IF;

  CASE t->>'estado'
    WHEN 'llamado' THEN
      v_botones := v_botones || jsonb_build_array(
        jsonb_build_array(
          jsonb_build_object('t', '✅ Ya llegó', 'd', 'turno:presento:' || (t->>'turno_id')),
          jsonb_build_object('t', '⚠️ No se presentó', 'd', 'turno:ausente:' || (t->>'turno_id'))));
    WHEN 'en_atencion' THEN
      v_botones := v_botones || jsonb_build_array(
        jsonb_build_array(
          jsonb_build_object('t', '🏁 Finalizar', 'd', 'turno:finalizar:' || (t->>'turno_id'))));
    WHEN 'ausente' THEN
      v_botones := v_botones || jsonb_build_array(
        jsonb_build_array(
          jsonb_build_object('t', '↩️ Reencolar', 'd', 'turno:reencolar:' || (t->>'turno_id'))));
    ELSE
      NULL;
  END CASE;

  v_botones := v_botones || jsonb_build_array(jsonb_build_array(
                 jsonb_build_object('t', '⬅️ Menú', 'd', 'menu')));

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_botones);
END;
$$;
