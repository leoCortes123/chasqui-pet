-- =====================================================================
-- Chasqui Pet — 046_bot_inventario.sql
-- El flujo de salida de medicamento por chat (§6.3) y la consulta de
-- existencias desde Telegram.
--
-- Requisito de diseño: la ruta feliz en ≤ 4 toques. El veterinario tiene
-- un animal en la mesa. Los cuatro son:
--
--   1. [💊 Salida]            (menú)
--   2. [Amoxicilina 500 mg]   (resultado de la búsqueda, o un frecuente)
--   3. [2]                    (cantidad, botones con las habituales)
--   4. [✅ Confirmar]
--
-- El lote no se pregunta: se toma el de vencimiento más próximo (FEFO).
-- Cambiarlo es posible, pero es un desvío del camino y exige motivo, que
-- queda guardado en el movimiento.
--
-- El estado vive en conversacion_estado, nunca en n8n (§2.2.1): si n8n se
-- reinicia entre el paso 2 y el 3, el veterinario sigue donde iba.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Botones propios en el menú principal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_inv_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_fila jsonb := '[]'::jsonb;
BEGIN
  IF tiene_permiso(p_usuario_id, 'inventario.salida') THEN
    v_fila := v_fila || jsonb_build_object('t', '💊 Salida', 'd', 'inv:salida');
  END IF;
  IF tiene_permiso(p_usuario_id, 'inventario.ver') THEN
    v_fila := v_fila || jsonb_build_object('t', '📦 Stock', 'd', 'inv:stock');
  END IF;

  IF jsonb_array_length(v_fila) = 0 THEN RETURN '[]'::jsonb; END IF;
  RETURN jsonb_build_array(v_fila);
END;
$$;

-- ---------------------------------------------------------------------
-- Piezas de interfaz
-- ---------------------------------------------------------------------

-- Paso 1: pedir el medicamento. Los frecuentes del propio veterinario van
-- como botones, porque en la práctica el 80 % de las salidas son cuatro
-- o cinco productos.
CREATE OR REPLACE FUNCTION bot_inv_pedir_medicamento(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb; v_texto text;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', nombre || ' · ' || fmt_cant(disponible),
           'd', 'inv:med:' || medicamento_id))), '[]'::jsonb)
    INTO v_bot
    FROM medicamentos_frecuentes(p_usuario_id, 4);

  v_texto := '💊 <b>Salida de medicamento</b>' || E'\n' ||
             'Escribe el nombre' ||
             CASE WHEN jsonb_array_length(v_bot) > 0
                  THEN ' o toca uno de los habituales:' ELSE '.' END;

  RETURN jsonb_build_object('texto', v_texto,
           'botones', v_bot || jsonb_build_array(jsonb_build_array(
             jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));
END;
$$;

-- Paso 2: resultados de la búsqueda como botones (top 5, §6.3).
CREATE OR REPLACE FUNCTION bot_inv_resultados(p_texto text)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb; v_n int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', nombre || ' · ' || fmt_cant(disponible) || ' ' || unidad_base,
           'd', 'inv:med:' || medicamento_id)) ORDER BY puntaje DESC), '[]'::jsonb),
         count(*)
    INTO v_bot, v_n
    FROM buscar_medicamento(p_texto, 5);

  IF v_n = 0 THEN
    RETURN jsonb_build_object('texto',
      '🔍 Nada se parece a «' || esc(p_texto) || '».' || E'\n' ||
      'Prueba con otro nombre.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));
  END IF;

  RETURN jsonb_build_object('texto',
    '🔍 <b>' || esc(p_texto) || '</b>' || E'\n' || '¿Cuál es?',
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));
END;
$$;

-- Paso 3: cantidad. Muestra el lote sugerido por FEFO ya elegido.
CREATE OR REPLACE FUNCTION bot_inv_pedir_cantidad(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_med jsonb := medicamento_json((p_datos->>'medicamento_id')::uuid);
  v_lote record;
  v_texto text;
  v_fila jsonb := '[]'::jsonb;
  v_botones jsonb := '[]'::jsonb;
  v_c text;
BEGIN
  SELECT l.numero_lote, l.fecha_vencimiento, l.cantidad_actual,
         (l.fecha_vencimiento - hoy_bogota()) AS dias
    INTO v_lote
    FROM lote l WHERE l.id = (p_datos->>'lote_id')::uuid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('texto', 'Ese lote ya no está disponible.',
             'botones', jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));
  END IF;

  v_texto := format('💊 <b>%s</b>%s📦 Lote %s · vence %s · quedan %s %s%s¿Cuánto?',
               esc(v_med->>'nombre'), E'\n',
               esc(v_lote.numero_lote),
               to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY'),
               fmt_cant(v_lote.cantidad_actual), esc(v_med->>'unidad'), E'\n');

  IF v_lote.dias <= config_int('alerta_vencimiento_dias_critico', 7) THEN
    v_texto := v_texto || E'\n' || format('⚠️ Ese lote vence en %s día(s).', v_lote.dias);
  END IF;

  IF (v_med->>'requiere_receta')::boolean THEN
    v_texto := v_texto || E'\n' || '📄 Requiere receta.';
  END IF;

  -- Cantidades habituales, configurables sin desplegar.
  FOREACH v_c IN ARRAY string_to_array(config_txt('cantidades_frecuentes', '1,2,3,5,10'), ',') LOOP
    -- La configuración la edita una persona desde el portal: se ignora
    -- en silencio lo que no sea un número en vez de romper el flujo.
    IF trim(v_c) ~ '^[0-9]+([.,][0-9]+)?$'
       AND replace(trim(v_c), ',', '.')::numeric <= v_lote.cantidad_actual THEN
      v_fila := v_fila || jsonb_build_object(
                  't', replace(trim(v_c), ',', '.'),
                  'd', 'inv:cant:' || replace(trim(v_c), ',', '.'));
    END IF;
    IF jsonb_array_length(v_fila) = 3 THEN
      v_botones := v_botones || jsonb_build_array(v_fila);
      v_fila := '[]'::jsonb;
    END IF;
  END LOOP;
  IF jsonb_array_length(v_fila) > 0 THEN v_botones := v_botones || jsonb_build_array(v_fila); END IF;

  v_botones := v_botones
    || jsonb_build_array(jsonb_build_array(
         jsonb_build_object('t', '✏️ Otra cantidad', 'd', 'inv:libre'),
         jsonb_build_object('t', '🔁 Otro lote', 'd', 'inv:lotes')))
    || jsonb_build_array(jsonb_build_array(
         jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar')));

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_botones);
END;
$$;

-- Desvío: elegir otro lote. Se listan en FEFO con su vencimiento y su
-- existencia, marcando cuál era el sugerido.
CREATE OR REPLACE FUNCTION bot_inv_lotes(p_medicamento_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', CASE WHEN es_sugerido THEN '⭐ ' ELSE '' END ||
                numero_lote || ' · ' || to_char(fecha_vencimiento, 'DD/MM/YY') ||
                ' · ' || fmt_cant(cantidad_actual),
           'd', 'inv:lote:' || lote_id))), '[]'::jsonb)
    INTO v_bot
    FROM lotes_fefo(p_medicamento_id, 5);

  IF jsonb_array_length(v_bot) = 0 THEN
    RETURN jsonb_build_object('texto', 'No hay lotes disponibles de ese medicamento.',
             'botones', jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));
  END IF;

  RETURN jsonb_build_object('texto',
    '📦 <b>Lotes disponibles</b>' || E'\n' ||
    'El marcado con ⭐ es el que vence primero. Usar otro exige motivo.',
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));
END;
$$;

-- Paso 4: tarjeta de confirmación con todo (§6.3).
CREATE OR REPLACE FUNCTION bot_inv_confirmacion(p_usuario_id uuid, p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_med jsonb := medicamento_json((p_datos->>'medicamento_id')::uuid);
  v_lote lote;
  v_cant numeric := (p_datos->>'cantidad')::numeric;
  v_turno turno;
  v_texto text;
BEGIN
  SELECT * INTO v_lote FROM lote WHERE id = (p_datos->>'lote_id')::uuid;

  IF NOT FOUND OR v_cant IS NULL THEN
    RETURN jsonb_build_object('texto', 'La salida se perdió por el camino. Empieza de nuevo.',
             'botones', jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '💊 Salida', 'd', 'inv:salida'),
               jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));
  END IF;

  v_texto := format('<b>Confirma la salida</b>%s💊 %s%s📦 Lote %s · vence %s%s🔢 %s %s%s💵 %s',
               E'\n',
               esc(v_med->>'nombre'), E'\n',
               esc(v_lote.numero_lote), to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY'), E'\n',
               fmt_cant(v_cant), esc(v_med->>'unidad'), E'\n',
               pesos((v_med->>'precio_venta')::numeric * v_cant));

  SELECT * INTO v_turno FROM turno
   WHERE veterinario_id = p_usuario_id AND fecha = hoy_bogota() AND estado = 'en_atencion'
   ORDER BY en_atencion_at DESC LIMIT 1;

  IF v_turno.id IS NOT NULL THEN
    -- Paso 4 del plan: cuando existan paciente y consulta, aquí se
    -- mostrará el nombre del animal en vez del código del turno.
    v_texto := v_texto || E'\n' || format('🩺 Turno %s (en atención)', esc(v_turno.codigo));
  ELSE
    v_texto := v_texto || E'\n' || '🩺 Sin turno en atención: queda como salida suelta.';
  END IF;

  IF p_datos ? 'motivo' THEN
    v_texto := v_texto || E'\n' || '📝 ' || esc(p_datos->>'motivo');
  END IF;

  v_texto := v_texto || E'\n' ||
             format('Quedarán %s %s en el lote.',
                    fmt_cant(v_lote.cantidad_actual - v_cant), esc(v_med->>'unidad'));

  RETURN jsonb_build_object('texto', v_texto, 'botones', jsonb_build_array(
    jsonb_build_array(
      jsonb_build_object('t', '✅ Confirmar', 'd', 'inv:confirmar'),
      jsonb_build_object('t', '✏️ Corregir',  'd', 'inv:corregir'),
      jsonb_build_object('t', '🚫 Cancelar',  'd', 'inv:cancelar'))));
END;
$$;

-- ---------------------------------------------------------------------
-- Consulta de existencias y alertas
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_texto_alertas_inventario()
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  a jsonb := alertas_inventario();
  v_texto text := '📦 <b>Inventario</b>';
  v_bloque text;
BEGIN
  SELECT string_agg(format('• %s: quedan %s %s (mínimo %s)',
                           esc(x->>'nombre'), fmt_cant((x->>'disponible')::numeric),
                           esc(x->>'unidad'), fmt_cant((x->>'minimo')::numeric)), E'\n')
    INTO v_bloque FROM jsonb_array_elements(a->'bajo_minimo') x;
  IF v_bloque IS NOT NULL THEN
    v_texto := v_texto || E'\n\n' || '🔻 <b>Bajo el mínimo</b>' || E'\n' || v_bloque;
  END IF;

  SELECT string_agg(format('• %s%s · lote %s · vence en %s día(s) · %s',
                           CASE WHEN (x->>'critico')::boolean THEN '🚨 ' ELSE '' END,
                           esc(x->>'nombre'), esc(x->>'lote'), x->>'dias',
                           fmt_cant((x->>'cantidad')::numeric)), E'\n')
    INTO v_bloque FROM jsonb_array_elements(a->'por_vencer') x;
  IF v_bloque IS NOT NULL THEN
    v_texto := v_texto || E'\n\n' ||
               format('⏳ <b>Por vencer (≤ %s días)</b>', a->>'dias_aviso') || E'\n' || v_bloque;
  END IF;

  SELECT string_agg(format('• %s · lote %s · venció %s · %s sin dar de baja',
                           esc(x->>'nombre'), esc(x->>'lote'),
                           to_char((x->>'vencio')::date, 'DD/MM/YYYY'),
                           fmt_cant((x->>'cantidad')::numeric)), E'\n')
    INTO v_bloque FROM jsonb_array_elements(a->'vencidos') x;
  IF v_bloque IS NOT NULL THEN
    v_texto := v_texto || E'\n\n' || '☠️ <b>Vencidos con existencia</b>' || E'\n' || v_bloque;
  END IF;

  IF v_texto = '📦 <b>Inventario</b>' THEN
    v_texto := v_texto || E'\n' || 'Todo en orden: nada bajo mínimo ni por vencerse.';
  END IF;

  RETURN v_texto;
END;
$$;

-- Existencia de lo que el usuario busque, en texto corto.
CREATE OR REPLACE FUNCTION bot_texto_stock(p_texto text)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE v_lineas text;
BEGIN
  SELECT string_agg(format('%s <b>%s</b>%s   %s %s%s',
                           CASE WHEN bajo_minimo THEN '🔻' ELSE '•' END,
                           esc(nombre), E'\n',
                           fmt_cant(disponible), esc(unidad_base),
                           ' · ' || pesos(precio_venta)), E'\n' ORDER BY puntaje DESC)
    INTO v_lineas
    FROM buscar_medicamento(p_texto, 5);

  IF v_lineas IS NULL THEN
    RETURN '🔍 No hay nada parecido a «' || esc(p_texto) || '» en el catálogo.';
  END IF;

  RETURN '📦 <b>Existencias</b>' || E'\n' || v_lineas;
END;
$$;

-- ---------------------------------------------------------------------
-- Callbacks de inventario
--
-- Devuelve NULL si el callback no empieza por 'inv': eso significa «no es
-- mío» y quien despacha sigue preguntando a los demás módulos. El
-- despachador está al final de este archivo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_inv_callback(
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
  v_cant   numeric;
  v_lote   uuid;
BEGIN
  IF v_partes[1] <> 'inv' THEN
    RETURN NULL;
  END IF;

  v_estado := estado_leer(p_chat_id);
  v_datos  := COALESCE(v_estado->'datos', '{}'::jsonb);

  CASE v_partes[2]

    -- Toque 1 -------------------------------------------------------
    WHEN 'salida' THEN
      PERFORM exigir_permiso(p_usuario_id, 'inventario.salida');
      PERFORM estado_limpiar(p_chat_id);
      PERFORM estado_guardar(p_chat_id, 'salida', 'medicamento', '{}'::jsonb, p_usuario_id, p_mensaje_id);
      v_vista := bot_inv_pedir_medicamento(p_usuario_id);

    -- Toque 2: medicamento elegido; el lote lo pone FEFO --------------
    WHEN 'med' THEN
      PERFORM exigir_permiso(p_usuario_id, 'inventario.salida');
      v_lote := lote_fefo(v_partes[3]::uuid);

      IF v_lote IS NULL THEN
        v_alerta := 'Sin existencias';
        v_vista := jsonb_build_object('texto',
          format('%s no tiene existencia disponible.',
                 esc(medicamento_json(v_partes[3]::uuid)->>'nombre')),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));
      ELSE
        v_datos := jsonb_build_object('medicamento_id', v_partes[3], 'lote_id', v_lote,
                                      'lote_sugerido', v_lote);
        PERFORM estado_guardar(p_chat_id, 'salida', 'cantidad', v_datos, p_usuario_id, p_mensaje_id);
        v_vista := bot_inv_pedir_cantidad(v_datos);
      END IF;

    -- Desvío: ver y elegir otro lote ---------------------------------
    WHEN 'lotes' THEN
      v_vista := bot_inv_lotes((v_datos->>'medicamento_id')::uuid);

    WHEN 'lote' THEN
      v_datos := v_datos || jsonb_build_object('lote_id', v_partes[3]);
      PERFORM estado_guardar(p_chat_id, 'salida', 'cantidad', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := bot_inv_pedir_cantidad(v_datos);

    -- Toque 3: cantidad ----------------------------------------------
    WHEN 'cant' THEN
      v_cant := v_partes[3]::numeric;
      v_datos := v_datos || jsonb_build_object('cantidad', v_cant);
      PERFORM estado_guardar(p_chat_id, 'salida', 'confirmar', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := bot_inv_confirmacion(p_usuario_id, v_datos);

    WHEN 'libre' THEN
      PERFORM estado_guardar(p_chat_id, 'salida', 'cantidad_libre', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '✏️ Escribe la cantidad (por ejemplo 0.5 o 12).',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));

    WHEN 'corregir' THEN
      PERFORM estado_guardar(p_chat_id, 'salida', 'cantidad', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := bot_inv_pedir_cantidad(v_datos);

    -- Toque 4: confirmar ---------------------------------------------
    WHEN 'confirmar' THEN
      v_r := salida_medicamento(p_usuario_id,
               (v_datos->>'lote_id')::uuid,
               (v_datos->>'cantidad')::numeric,
               v_datos->>'motivo', NULL, NULL, NULL, 'telegram');

      IF (v_r->>'ok')::boolean THEN
        PERFORM estado_limpiar(p_chat_id);
        v_alerta := 'Salida registrada';
        v_vista := jsonb_build_object('texto',
          format('✅ <b>Salida registrada</b>%s%s %s de %s%s📦 Lote %s · quedan %s%s💵 %s',
                 E'\n',
                 fmt_cant((v_r->'movimiento'->>'cantidad')::numeric),
                 esc(v_r->'movimiento'->>'unidad'),
                 esc(v_r->'movimiento'->>'medicamento'), E'\n',
                 esc(v_r->'movimiento'->>'lote'),
                 fmt_cant((v_r->'movimiento'->>'restante')::numeric), E'\n',
                 pesos((v_r->'movimiento'->>'valor')::numeric)),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '💊 Otra salida', 'd', 'inv:salida'),
            jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))));

      ELSIF v_r->>'motivo' = 'fefo_sin_justificacion' THEN
        -- Se eligió un lote que no es el que vence primero: la
        -- justificación es obligatoria y queda en el movimiento (§6.1).
        PERFORM estado_guardar(p_chat_id, 'salida', 'motivo', v_datos, p_usuario_id, p_mensaje_id);
        v_alerta := 'Falta el motivo';
        v_vista := jsonb_build_object('texto',
          '📝 Ese no es el lote que vence primero.' || E'\n' ||
          'Escribe por qué usas otro (queda registrado).',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '🚫 Cancelar', 'd', 'inv:cancelar'))));
      ELSE
        v_alerta := v_r->>'mensaje';
        v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '💊 Reintentar', 'd', 'inv:salida'),
            jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))));
      END IF;

    -- Consulta de existencias ----------------------------------------
    WHEN 'stock' THEN
      PERFORM exigir_permiso(p_usuario_id, 'inventario.ver');
      PERFORM estado_guardar(p_chat_id, 'stock', 'buscar', '{}'::jsonb, p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        bot_texto_alertas_inventario() || E'\n\n' ||
        'Escribe un nombre para ver su existencia.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Menú', 'd', 'inv:cancelar'))));

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
-- Texto libre de inventario: búsqueda, cantidad y motivo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_inv_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado jsonb := estado_leer(p_chat_id);
  v_flujo  text  := v_estado->>'flujo';
  v_paso   text  := v_estado->>'paso';
  v_datos  jsonb := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_vista  jsonb;
  v_cant   numeric;
  v_r      jsonb;
BEGIN
  -- Comando suelto: la existencia sin pasar por el menú.
  IF p_texto IN ('/stock', 'stock') AND tiene_permiso(p_usuario_id, 'inventario.ver') THEN
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, bot_texto_alertas_inventario() || E'\n\n' ||
        'Escribe «stock <nombre>» para ver un medicamento.')));
  END IF;

  IF p_texto ~* '^stock\s+\S' AND tiene_permiso(p_usuario_id, 'inventario.ver') THEN
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, bot_texto_stock(regexp_replace(p_texto, '^\s*stock\s+', '', 'i')))));
  END IF;

  IF v_flujo = 'stock' THEN
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, bot_texto_stock(p_texto))));
  END IF;

  -- Sin flujo activo (o expirado) el texto no es de inventario.
  IF v_flujo IS DISTINCT FROM 'salida' THEN
    RETURN NULL;   -- que siga el enrutador
  END IF;

  PERFORM exigir_permiso(p_usuario_id, 'inventario.salida');

  CASE v_paso
    WHEN 'medicamento' THEN
      v_vista := bot_inv_resultados(p_texto);

    WHEN 'cantidad_libre' THEN
      -- «0,5» y «0.5» son la misma cantidad para quien escribe deprisa.
      BEGIN
        v_cant := replace(trim(p_texto), ',', '.')::numeric;
      EXCEPTION WHEN others THEN v_cant := NULL;
      END;

      IF v_cant IS NULL OR v_cant <= 0 THEN
        v_vista := jsonb_build_object('texto',
          '⚠️ «' || esc(p_texto) || '» no es una cantidad. Escribe un número, por ejemplo 2 o 0.5.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '🚫 Cancelar', 'd', 'inv:cancelar'))));
      ELSE
        v_datos := v_datos || jsonb_build_object('cantidad', v_cant);
        PERFORM estado_guardar(p_chat_id, 'salida', 'confirmar', v_datos, p_usuario_id);
        v_vista := bot_inv_confirmacion(p_usuario_id, v_datos);
      END IF;

    WHEN 'motivo' THEN
      v_datos := v_datos || jsonb_build_object('motivo', p_texto);
      PERFORM estado_guardar(p_chat_id, 'salida', 'confirmar', v_datos, p_usuario_id);
      v_vista := bot_inv_confirmacion(p_usuario_id, v_datos);

    ELSE
      RETURN NULL;
  END CASE;

  RETURN jsonb_build_object('acciones', jsonb_build_array(
    accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;

-- ---------------------------------------------------------------------
-- Despachador de módulos (reemplaza los enganches vacíos de 040)
--
-- Cada módulo nuevo reescribe estas dos funciones añadiendo su llamada.
-- Son cinco líneas y no contienen lógica de negocio: lo que no se debe
-- duplicar —el CASE de cada módulo— vive en su propia función. COALESCE
-- corta en cuanto uno responde, así que el módulo que no toca no se
-- ejecuta.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_inv_menu(p_usuario_id);
$$;

CREATE OR REPLACE FUNCTION bot_modulo_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT bot_inv_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id);
$$;

CREATE OR REPLACE FUNCTION bot_modulo_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT bot_inv_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id);
$$;
