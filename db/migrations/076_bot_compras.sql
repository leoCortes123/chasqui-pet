-- =====================================================================
-- Chasqui Pet — 076_bot_compras.sql
-- Entradas de inventario y proveedores desde el chat (§9).
--
-- Quien digita una factura de proveedor no tiene prisa —el animal no está
-- en la mesa— pero sí tiene doce renglones por delante. Las decisiones de
-- este archivo van todas en la misma dirección:
--
--   1. **La entrada vive en la base desde el primer renglón.** No se
--      acumula nada en el estado conversacional: si el celular se apaga en
--      el renglón nueve, al volver el borrador está entero y el bot
--      ofrece seguir. Lo que sí vive en conversacion_estado es el renglón
--      a medio armar, que es lo único que se puede perder sin dolor.
--   2. **Nada toca el inventario hasta [✅ Confirmar].** El borrador es
--      papel; la confirmación es la que crea lotes y movimientos, y pide
--      confirmación explícita porque mueve existencias (§2.2.9).
--   3. **La foto de la factura es un mensaje más.** Se manda al chat y el
--      bot la engancha al borrador abierto: nadie tiene que buscar un
--      botón de «adjuntar» antes de tomar la foto.
--   4. El proveedor se elige de una lista corta: en la práctica son tres
--      o cuatro, y escribir el nombre completo cada vez es trabajo
--      inventado.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Botones propios en el menú principal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_com_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_fila jsonb := '[]'::jsonb; v_borrador uuid;
BEGIN
  IF tiene_permiso(p_usuario_id, 'inventario.entrada') THEN
    v_borrador := entrada_borrador_de(p_usuario_id);
    -- Si quedó una factura a medio digitar, el botón lo dice: es la forma
    -- de que no se quede ahí para siempre.
    v_fila := v_fila || jsonb_build_object(
                't', CASE WHEN v_borrador IS NULL THEN '📥 Entrada'
                          ELSE '📥 Entrada (sin terminar)' END,
                'd', 'com:entrada');
  END IF;
  IF tiene_permiso(p_usuario_id, 'proveedores.ver') THEN
    v_fila := v_fila || jsonb_build_object('t', '🏭 Proveedores', 'd', 'com:prov');
  END IF;

  IF jsonb_array_length(v_fila) = 0 THEN RETURN '[]'::jsonb; END IF;
  RETURN jsonb_build_array(v_fila);
END;
$$;

-- ---------------------------------------------------------------------
-- Piezas de interfaz
-- ---------------------------------------------------------------------

-- Paso 1: de quién es la factura.
CREATE OR REPLACE FUNCTION bot_com_pedir_proveedor(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb; v_texto text;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', '🏭 ' || nombre ||
                CASE WHEN ultima IS NOT NULL
                     THEN ' · ' || to_char(ultima, 'DD/MM/YY') ELSE '' END,
           'd', 'com:prv:' || proveedor_id))), '[]'::jsonb)
    INTO v_bot
    FROM proveedores_frecuentes(5);

  v_texto := '📥 <b>Entrada de mercancía</b>' || E'\n' ||
             CASE WHEN jsonb_array_length(v_bot) > 0
                  THEN '¿De quién es la factura? Toca uno o escribe el nombre.'
                  ELSE 'No hay proveedores todavía. Escribe el nombre del primero.' END;

  IF tiene_permiso(p_usuario_id, 'proveedores.gestionar') THEN
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '➕ Proveedor nuevo', 'd', 'com:prvnuevo')));
  END IF;

  RETURN jsonb_build_object('texto', v_texto,
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Menú', 'd', 'com:cancelar'))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_com_resultados_proveedor(p_texto text, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb; v_n int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', '🏭 ' || nombre, 'd', 'com:prv:' || proveedor_id)) ORDER BY puntaje DESC), '[]'::jsonb),
         count(*)
    INTO v_bot, v_n
    FROM buscar_proveedor(p_texto, 5);

  IF tiene_permiso(p_usuario_id, 'proveedores.gestionar') THEN
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '➕ Crear «' || left(p_texto, 20) || '»',
                                  'd', 'com:prvcrear')));
  END IF;

  RETURN jsonb_build_object('texto',
    CASE WHEN v_n = 0
         THEN '🔍 Ningún proveedor se parece a «' || esc(p_texto) || '».'
         ELSE '🔍 <b>' || esc(p_texto) || '</b>' || E'\n' || '¿Cuál es?' END,
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Menú', 'd', 'com:cancelar'))));
END;
$$;

-- La tarjeta de la entrada: qué lleva la factura y qué se puede hacer con
-- ella. Es la pantalla a la que se vuelve después de cada renglón.
CREATE OR REPLACE FUNCTION bot_com_entrada(p_entrada_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e jsonb := entrada_json(p_entrada_id);
  v_texto text;
  v_lineas text;
  v_bot jsonb := '[]'::jsonb;
  v_fila jsonb := '[]'::jsonb;
  v_n int;
BEGIN
  IF e IS NULL THEN
    RETURN jsonb_build_object('texto', 'Esa entrada ya no existe.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'com:cancelar'))));
  END IF;

  v_n := jsonb_array_length(e->'lineas');

  v_texto := format('📥 <b>%s</b>%s📅 %s%s',
               esc(COALESCE(e->>'proveedor', 'Sin proveedor')), E'\n',
               to_char((e->>'fecha')::date, 'DD/MM/YYYY'),
               CASE WHEN e->>'documento' IS NOT NULL
                    THEN ' · factura ' || esc(e->>'documento') ELSE '' END);

  SELECT string_agg(format('• %s · %s %s · %s c/u%s',
                           esc(l->>'medicamento'),
                           fmt_cant((l->>'cantidad')::numeric), esc(l->>'unidad'),
                           pesos((l->>'costo_unitario')::numeric),
                           CASE WHEN (l->>'costo_sobre_precio')::boolean
                                THEN ' ⚠️' ELSE '' END) ||
                    E'\n' ||
                    format('   lote %s · vence %s · %s',
                           esc(COALESCE(l->>'lote', 'sin número')),
                           to_char((l->>'vence')::date, 'DD/MM/YYYY'),
                           pesos((l->>'valor_total')::numeric)), E'\n')
    INTO v_lineas FROM jsonb_array_elements(e->'lineas') l;

  v_texto := v_texto || E'\n\n' ||
             COALESCE(v_lineas, '<i>Todavía no has agregado ningún medicamento.</i>');

  IF v_n > 0 THEN
    v_texto := v_texto || E'\n\n' ||
               format('<b>Total: %s</b> · %s renglón(es)', pesos((e->>'valor_total')::numeric), v_n);
  END IF;

  IF (e->>'tiene_adjunto')::boolean THEN
    v_texto := v_texto || E'\n' || '📎 Factura adjunta.';
  END IF;

  -- Confirmada: ya no hay nada que tocar, sólo mirar.
  IF e->>'estado' <> 'borrador' THEN
    v_texto := v_texto || E'\n\n' ||
      CASE e->>'estado'
        WHEN 'confirmada' THEN '✅ Ingresada al inventario el ' || (e->>'confirmada_at')
        ELSE '🚫 Descartada'
      END;

    RETURN jsonb_build_object('texto', v_texto, 'botones', jsonb_build_array(
      jsonb_build_array(
        jsonb_build_object('t', '📥 Otra entrada', 'd', 'com:entrada'),
        jsonb_build_object('t', '⬅️ Menú', 'd', 'com:cancelar'))));
  END IF;

  v_texto := v_texto || E'\n\n' ||
             '<i>Nada de esto ha entrado al inventario todavía.</i>';

  -- Fila 1: lo que se hace la mayoría de las veces, agregar renglones.
  v_fila := jsonb_build_array(jsonb_build_object('t', '➕ Medicamento', 'd', 'com:med'));
  IF v_n > 0 THEN
    v_fila := v_fila || jsonb_build_object('t', '➖ Quitar', 'd', 'com:quitar');
  END IF;
  v_bot := jsonb_build_array(v_fila);

  -- Fila 2: los datos de la factura.
  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
             jsonb_build_object('t', '🧾 N.º de factura', 'd', 'com:doc'),
             jsonb_build_object('t', '📎 Foto', 'd', 'com:foto')));

  -- Fila 3: cerrar.
  v_fila := '[]'::jsonb;
  IF v_n > 0 THEN
    v_fila := v_fila || jsonb_build_object('t', '✅ Ingresar al inventario', 'd', 'com:confirmar');
  END IF;
  v_fila := v_fila || jsonb_build_object('t', '🚫 Descartar', 'd', 'com:descartar');

  RETURN jsonb_build_object('texto', v_texto,
    'botones', v_bot || jsonb_build_array(v_fila) ||
      jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'com:cancelar'))));
END;
$$;

-- Antes de mover existencias, la cuenta clara (§2.2.9).
CREATE OR REPLACE FUNCTION bot_com_confirmacion(p_entrada_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e jsonb := entrada_json(p_entrada_id);
  v_texto text;
  v_aviso text;
BEGIN
  v_texto := format('<b>¿Ingresar esta compra?</b>%s🏭 %s%s🔢 %s renglón(es)%s💵 %s',
               E'\n', esc(COALESCE(e->>'proveedor', 'Sin proveedor')), E'\n',
               jsonb_array_length(e->'lineas'), E'\n',
               pesos((e->>'valor_total')::numeric));

  IF e->>'documento' IS NULL THEN
    v_texto := v_texto || E'\n' || '⚠️ Sin número de factura.';
  END IF;
  IF NOT (e->>'tiene_adjunto')::boolean THEN
    v_texto := v_texto || E'\n' || '⚠️ Sin foto del soporte.';
  END IF;

  -- Costo por encima del precio de venta: casi siempre es un cero de más.
  SELECT string_agg('• ' || esc(l->>'medicamento'), E'\n')
    INTO v_aviso
    FROM jsonb_array_elements(e->'lineas') l
   WHERE (l->>'costo_sobre_precio')::boolean;

  IF v_aviso IS NOT NULL THEN
    v_texto := v_texto || E'\n\n' ||
      '⚠️ <b>Se compró más caro de lo que se vende</b>' || E'\n' || v_aviso ||
      E'\n' || 'Revisa el costo o el precio de venta.';
  END IF;

  v_texto := v_texto || E'\n\n' ||
             'Al confirmar, la mercancía queda disponible para despachar.';

  RETURN jsonb_build_object('texto', v_texto, 'botones', jsonb_build_array(
    jsonb_build_array(
      jsonb_build_object('t', '✅ Sí, ingresar', 'd', 'com:confirmar2'),
      jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
END;
$$;

-- Renglón: cuánto entró.
CREATE OR REPLACE FUNCTION bot_com_pedir_cantidad(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_med jsonb := medicamento_json((p_datos->>'medicamento_id')::uuid);
  v_fila jsonb := '[]'::jsonb;
  v_botones jsonb := '[]'::jsonb;
  v_c text;
BEGIN
  FOREACH v_c IN ARRAY string_to_array(config_txt('cantidades_entrada', '10,20,50,100'), ',') LOOP
    IF trim(v_c) ~ '^[0-9]+([.,][0-9]+)?$' THEN
      v_fila := v_fila || jsonb_build_object('t', replace(trim(v_c), ',', '.'),
                                             'd', 'com:cant:' || replace(trim(v_c), ',', '.'));
    END IF;
    IF jsonb_array_length(v_fila) = 3 THEN
      v_botones := v_botones || jsonb_build_array(v_fila);
      v_fila := '[]'::jsonb;
    END IF;
  END LOOP;
  IF jsonb_array_length(v_fila) > 0 THEN v_botones := v_botones || jsonb_build_array(v_fila); END IF;

  RETURN jsonb_build_object('texto',
    format('💊 <b>%s</b>%s📦 Hay %s %s.%s¿Cuántas unidades entraron? Escríbelo o toca una.',
           esc(v_med->>'nombre'), E'\n',
           fmt_cant((v_med->>'disponible')::numeric), esc(v_med->>'unidad'), E'\n'),
    'botones', v_botones || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
END;
$$;

-- Renglón: a cuánto se compró. Se ofrece el costo de la última compra,
-- que es el mismo el 90 % de las veces.
CREATE OR REPLACE FUNCTION bot_com_pedir_costo(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_med jsonb := medicamento_json((p_datos->>'medicamento_id')::uuid);
  v_ultimo numeric;
  v_bot jsonb := '[]'::jsonb;
BEGIN
  SELECT costo_unitario INTO v_ultimo
    FROM lote WHERE medicamento_id = (p_datos->>'medicamento_id')::uuid
     AND costo_unitario > 0
   ORDER BY created_at DESC LIMIT 1;

  IF v_ultimo IS NOT NULL THEN
    v_bot := jsonb_build_array(jsonb_build_array(jsonb_build_object(
               't', '↩️ Igual que antes · ' || pesos(v_ultimo),
               'd', 'com:costo:' || v_ultimo::text)));
  END IF;

  RETURN jsonb_build_object('texto',
    format('💊 <b>%s</b> · %s %s%s💵 ¿A cuánto salió cada %s?%sSe vende a %s.',
           esc(v_med->>'nombre'),
           fmt_cant((p_datos->>'cantidad')::numeric), esc(v_med->>'unidad'), E'\n',
           esc(v_med->>'unidad'), E'\n', pesos((v_med->>'precio_venta')::numeric)),
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_com_pedir_vencimiento(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_med jsonb := medicamento_json((p_datos->>'medicamento_id')::uuid);
BEGIN
  RETURN jsonb_build_object('texto',
    format('💊 <b>%s</b>%s📅 ¿Cuándo vence?%sEscríbelo como venga en la caja: 12/2027, 31/12/2027.',
           esc(v_med->>'nombre'), E'\n', E'\n'),
    'botones', jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_com_pedir_lote(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_med jsonb := medicamento_json((p_datos->>'medicamento_id')::uuid);
BEGIN
  RETURN jsonb_build_object('texto',
    format('💊 <b>%s</b> · vence %s%s🏷️ ¿Número de lote?',
           esc(v_med->>'nombre'),
           to_char((p_datos->>'vence')::date, 'DD/MM/YYYY'), E'\n'),
    'botones', jsonb_build_array(
      jsonb_build_array(jsonb_build_object('t', '🚫 No trae', 'd', 'com:sinlote')),
      jsonb_build_array(jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
END;
$$;

-- ---------------------------------------------------------------------
-- Proveedores
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_com_proveedores(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_texto text; v_bot jsonb := '[]'::jsonb;
BEGIN
  SELECT string_agg(format('🏭 <b>%s</b>%s   %s',
                           esc(nombre), E'\n',
                           CASE WHEN compras = 0 THEN 'sin compras registradas'
                                ELSE format('%s compra(s) · última %s',
                                            compras, to_char(ultima, 'DD/MM/YYYY')) END),
                    E'\n')
    INTO v_texto
    FROM proveedores_frecuentes(8);

  IF tiene_permiso(p_usuario_id, 'proveedores.gestionar') THEN
    v_bot := jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '➕ Proveedor nuevo', 'd', 'com:prvnuevo')));
  END IF;

  RETURN jsonb_build_object('texto',
    '🏭 <b>Proveedores</b>' || E'\n' ||
    COALESCE(v_texto, 'Todavía no hay proveedores registrados.'),
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Menú', 'd', 'com:cancelar'))));
END;
$$;

-- ---------------------------------------------------------------------
-- Callbacks de compras
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_com_callback(
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
  v_entrada uuid;
  v_bot    jsonb;
BEGIN
  IF v_partes[1] <> 'com' THEN
    RETURN NULL;
  END IF;

  v_estado := estado_leer(p_chat_id);
  v_datos  := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_entrada := NULLIF(v_datos->>'entrada_id', '')::uuid;

  CASE v_partes[2]

    -- --- Entrada al módulo -----------------------------------------
    WHEN 'entrada' THEN
      PERFORM exigir_permiso(p_usuario_id, 'inventario.entrada');
      v_entrada := entrada_borrador_de(p_usuario_id);

      IF v_entrada IS NULL THEN
        PERFORM estado_limpiar(p_chat_id);
        PERFORM estado_guardar(p_chat_id, 'entrada', 'proveedor', '{}'::jsonb,
                               p_usuario_id, p_mensaje_id);
        v_vista := bot_com_pedir_proveedor(p_usuario_id);
      ELSE
        -- Había una factura a medio digitar: se retoma donde iba.
        PERFORM estado_limpiar(p_chat_id);
        PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                  jsonb_build_object('entrada_id', v_entrada), p_usuario_id, p_mensaje_id);
        v_alerta := 'Sigues con la entrada que dejaste abierta';
        v_vista := bot_com_entrada(v_entrada, p_usuario_id);
      END IF;

    -- --- Proveedor ---------------------------------------------------
    WHEN 'prv' THEN
      PERFORM exigir_permiso(p_usuario_id, 'inventario.entrada');
      v_r := crear_entrada(p_usuario_id, v_partes[3]::uuid, p_sede_id);

      IF (v_r->>'ok')::boolean THEN
        v_entrada := (v_r->'entrada'->>'entrada_id')::uuid;
        PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                  jsonb_build_object('entrada_id', v_entrada), p_usuario_id, p_mensaje_id);
        v_vista := bot_com_entrada(v_entrada, p_usuario_id);
      ELSE
        v_alerta := v_r->>'mensaje';
        v_vista := bot_com_pedir_proveedor(p_usuario_id);
      END IF;

    WHEN 'prvnuevo' THEN
      PERFORM exigir_permiso(p_usuario_id, 'proveedores.gestionar');
      PERFORM estado_guardar(p_chat_id, 'entrada', 'prv_nombre', v_datos,
                             p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '➕ <b>Proveedor nuevo</b>' || E'\n' || '¿Cómo se llama?',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Menú', 'd', 'com:cancelar'))));

    -- Crear con lo que ya se escribió en la búsqueda: se buscó, no
    -- apareció, y el nombre ya está tecleado. Volver a pedirlo sobra.
    WHEN 'prvcrear' THEN
      PERFORM exigir_permiso(p_usuario_id, 'proveedores.gestionar');
      v_r := crear_proveedor(p_usuario_id, v_datos->>'buscado');

      IF (v_r->>'ok')::boolean OR v_r->>'motivo' = 'duplicado' THEN
        v_r := crear_entrada(p_usuario_id, (v_r->'proveedor'->>'proveedor_id')::uuid, p_sede_id);
        v_entrada := (v_r->'entrada'->>'entrada_id')::uuid;
        PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                  jsonb_build_object('entrada_id', v_entrada), p_usuario_id, p_mensaje_id);
        v_alerta := 'Proveedor creado';
        v_vista := bot_com_entrada(v_entrada, p_usuario_id);
      ELSE
        v_alerta := v_r->>'mensaje';
        v_vista := bot_com_pedir_proveedor(p_usuario_id);
      END IF;

    WHEN 'prov' THEN
      PERFORM exigir_permiso(p_usuario_id, 'proveedores.ver');
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_com_proveedores(p_usuario_id);

    -- --- Vuelta a la tarjeta ------------------------------------------
    WHEN 'volver' THEN
      IF v_entrada IS NULL THEN
        v_vista := bot_com_pedir_proveedor(p_usuario_id);
      ELSE
        PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                  jsonb_build_object('entrada_id', v_entrada), p_usuario_id, p_mensaje_id);
        v_vista := bot_com_entrada(v_entrada, p_usuario_id);
      END IF;

    -- --- Renglones ----------------------------------------------------
    WHEN 'med' THEN
      PERFORM exigir_permiso(p_usuario_id, 'inventario.entrada');
      PERFORM estado_guardar(p_chat_id, 'entrada', 'buscar_med',
                jsonb_build_object('entrada_id', v_entrada), p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '➕ <b>¿Qué medicamento entró?</b>' || E'\n' ||
        'Escribe el nombre. Si no está en el catálogo, se crea desde el portal.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));

    WHEN 'm' THEN
      v_datos := v_datos || jsonb_build_object('medicamento_id', v_partes[3]);
      PERFORM estado_guardar(p_chat_id, 'entrada', 'cantidad', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := bot_com_pedir_cantidad(v_datos);

    WHEN 'cant' THEN
      v_datos := v_datos || jsonb_build_object('cantidad', v_partes[3]::numeric);
      PERFORM estado_guardar(p_chat_id, 'entrada', 'costo', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := bot_com_pedir_costo(v_datos);

    WHEN 'costo' THEN
      v_datos := v_datos || jsonb_build_object('costo', v_partes[3]::numeric);
      PERFORM estado_guardar(p_chat_id, 'entrada', 'vence', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := bot_com_pedir_vencimiento(v_datos);

    WHEN 'sinlote' THEN
      v_r := agregar_linea_entrada(p_usuario_id, v_entrada,
               (v_datos->>'medicamento_id')::uuid,
               (v_datos->>'cantidad')::numeric,
               (v_datos->>'costo')::numeric,
               (v_datos->>'vence')::date, NULL);

      PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                jsonb_build_object('entrada_id', v_entrada), p_usuario_id, p_mensaje_id);
      v_alerta := CASE WHEN (v_r->>'ok')::boolean THEN 'Renglón agregado'
                       ELSE v_r->>'mensaje' END;
      v_vista := bot_com_entrada(v_entrada, p_usuario_id);

    WHEN 'quitar' THEN
      PERFORM exigir_permiso(p_usuario_id, 'inventario.entrada');
      SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
               't', '➖ ' || (l->>'medicamento') || ' · ' ||
                    fmt_cant((l->>'cantidad')::numeric),
               'd', 'com:quitarl:' || (l->>'linea_id')))), '[]'::jsonb)
        INTO v_bot
        FROM jsonb_array_elements(entrada_json(v_entrada)->'lineas') l;

      v_vista := jsonb_build_object('texto',
        '➖ <b>Quitar de la factura</b>' || E'\n' || '¿Cuál renglón sobra?',
        'botones', v_bot || jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));

    WHEN 'quitarl' THEN
      v_r := quitar_linea_entrada(p_usuario_id, v_partes[3]::uuid);
      v_alerta := CASE WHEN (v_r->>'ok')::boolean THEN 'Renglón quitado'
                       ELSE v_r->>'mensaje' END;
      v_vista := bot_com_entrada(v_entrada, p_usuario_id);

    -- --- Datos de la factura ------------------------------------------
    WHEN 'doc' THEN
      PERFORM estado_guardar(p_chat_id, 'entrada', 'documento',
                jsonb_build_object('entrada_id', v_entrada), p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '🧾 Escribe el número de la factura o remisión.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));

    WHEN 'foto' THEN
      PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                jsonb_build_object('entrada_id', v_entrada), p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '📎 Mándame la foto de la factura por este chat.' || E'\n' ||
        'Queda guardada con la entrada.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));

    -- --- Cierre --------------------------------------------------------
    WHEN 'confirmar' THEN
      PERFORM exigir_permiso(p_usuario_id, 'inventario.entrada');
      v_vista := bot_com_confirmacion(v_entrada);

    WHEN 'confirmar2' THEN
      v_r := confirmar_entrada(p_usuario_id, v_entrada);

      IF (v_r->>'ok')::boolean THEN
        PERFORM estado_limpiar(p_chat_id);
        v_alerta := 'Mercancía ingresada';
        v_vista := jsonb_build_object('texto',
          format('✅ <b>Entrada ingresada</b>%s🏭 %s%s🔢 %s renglón(es) · %s%sYa se puede despachar.',
                 E'\n', esc(COALESCE(v_r->'entrada'->>'proveedor', 'Sin proveedor')), E'\n',
                 v_r->>'lineas', pesos((v_r->'entrada'->>'valor_total')::numeric), E'\n'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '📥 Otra entrada', 'd', 'com:entrada'),
            jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))));
      ELSE
        v_alerta := v_r->>'mensaje';
        v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
      END IF;

    WHEN 'descartar' THEN
      v_vista := jsonb_build_object('texto',
        '🚫 <b>¿Descartar la factura?</b>' || E'\n' ||
        'Se pierde lo digitado. El inventario no cambia.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '🚫 Sí, descartar', 'd', 'com:descartar2'),
          jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));

    WHEN 'descartar2' THEN
      v_r := descartar_entrada(p_usuario_id, v_entrada, 'Descartada desde el bot');
      PERFORM estado_limpiar(p_chat_id);
      v_alerta := CASE WHEN (v_r->>'ok')::boolean THEN 'Entrada descartada'
                       ELSE v_r->>'mensaje' END;
      v_vista := bot_menu_principal(p_usuario_id);

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
-- Texto libre de compras
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_com_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado jsonb := estado_leer(p_chat_id);
  v_flujo  text  := v_estado->>'flujo';
  v_paso   text  := v_estado->>'paso';
  v_datos  jsonb := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_entrada uuid := NULLIF(v_datos->>'entrada_id', '')::uuid;
  v_vista  jsonb;
  v_r      jsonb;
  v_num    numeric;
  v_fecha  date;
  v_bot    jsonb;
BEGIN
  -- Comandos sueltos, sin pasar por el menú.
  IF p_texto IN ('/entrada', 'entrada') AND tiene_permiso(p_usuario_id, 'inventario.entrada') THEN
    v_entrada := entrada_borrador_de(p_usuario_id);
    IF v_entrada IS NULL THEN
      PERFORM estado_guardar(p_chat_id, 'entrada', 'proveedor', '{}'::jsonb, p_usuario_id);
      v_vista := bot_com_pedir_proveedor(p_usuario_id);
    ELSE
      PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                jsonb_build_object('entrada_id', v_entrada), p_usuario_id);
      v_vista := bot_com_entrada(v_entrada, p_usuario_id);
    END IF;
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
  END IF;

  IF p_texto IN ('/proveedores', 'proveedores') AND tiene_permiso(p_usuario_id, 'proveedores.ver') THEN
    v_vista := bot_com_proveedores(p_usuario_id);
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
  END IF;

  IF v_flujo IS DISTINCT FROM 'entrada' THEN
    RETURN NULL;   -- no es nuestro: que siga el enrutador
  END IF;

  PERFORM exigir_permiso(p_usuario_id, 'inventario.entrada');

  CASE v_paso

    -- Búsqueda de proveedor. El texto buscado se guarda para poder crear
    -- el proveedor con él si no apareció.
    WHEN 'proveedor' THEN
      PERFORM estado_guardar(p_chat_id, 'entrada', 'proveedor',
                jsonb_build_object('buscado', p_texto), p_usuario_id);
      v_vista := bot_com_resultados_proveedor(p_texto, p_usuario_id);

    WHEN 'prv_nombre' THEN
      v_r := crear_proveedor(p_usuario_id, p_texto);

      IF (v_r->>'ok')::boolean OR v_r->>'motivo' = 'duplicado' THEN
        v_r := crear_entrada(p_usuario_id, (v_r->'proveedor'->>'proveedor_id')::uuid, p_sede_id);
        v_entrada := (v_r->'entrada'->>'entrada_id')::uuid;
        PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                  jsonb_build_object('entrada_id', v_entrada), p_usuario_id);
        v_vista := bot_com_entrada(v_entrada, p_usuario_id);
      ELSE
        v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Menú', 'd', 'com:cancelar'))));
      END IF;

    -- Renglón: medicamento, cantidad, costo, vencimiento y lote.
    WHEN 'buscar_med' THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
               't', nombre || ' · hay ' || fmt_cant(disponible),
               'd', 'com:m:' || medicamento_id)) ORDER BY puntaje DESC), '[]'::jsonb)
        INTO v_bot
        FROM buscar_medicamento(p_texto, 5);

      IF jsonb_array_length(v_bot) = 0 THEN
        v_vista := jsonb_build_object('texto',
          '🔍 Nada se parece a «' || esc(p_texto) || '» en el catálogo.' || E'\n' ||
          'Los medicamentos nuevos se crean desde el portal.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
      ELSE
        v_vista := jsonb_build_object('texto',
          '🔍 <b>' || esc(p_texto) || '</b>' || E'\n' || '¿Cuál es?',
          'botones', v_bot || jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
      END IF;

    WHEN 'cantidad' THEN
      BEGIN
        v_num := replace(trim(p_texto), ',', '.')::numeric;
      EXCEPTION WHEN others THEN v_num := NULL;
      END;

      IF v_num IS NULL OR v_num <= 0 THEN
        v_vista := jsonb_build_object('texto',
          '⚠️ «' || esc(p_texto) || '» no es una cantidad. Escribe un número, por ejemplo 20.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
      ELSE
        v_datos := v_datos || jsonb_build_object('cantidad', v_num);
        PERFORM estado_guardar(p_chat_id, 'entrada', 'costo', v_datos, p_usuario_id);
        v_vista := bot_com_pedir_costo(v_datos);
      END IF;

    WHEN 'costo' THEN
      v_num := parse_pesos(p_texto);

      IF v_num IS NULL OR v_num < 0 THEN
        v_vista := jsonb_build_object('texto',
          '⚠️ Escribe el costo, sólo el número. Por ejemplo 12500.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
      ELSE
        v_datos := v_datos || jsonb_build_object('costo', v_num);
        PERFORM estado_guardar(p_chat_id, 'entrada', 'vence', v_datos, p_usuario_id);
        v_vista := bot_com_pedir_vencimiento(v_datos);
      END IF;

    WHEN 'vence' THEN
      v_fecha := parse_fecha(p_texto);

      IF v_fecha IS NULL THEN
        v_vista := jsonb_build_object('texto',
          '⚠️ No entendí «' || esc(p_texto) || '» como fecha.' || E'\n' ||
          'Escribe 12/2027 o 31/12/2027.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
      ELSIF v_fecha < hoy_bogota() THEN
        v_vista := jsonb_build_object('texto',
          format('⚠️ Esa fecha ya pasó (%s). No se puede ingresar mercancía vencida.',
                 to_char(v_fecha, 'DD/MM/YYYY')),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
      ELSE
        v_datos := v_datos || jsonb_build_object('vence', v_fecha);
        PERFORM estado_guardar(p_chat_id, 'entrada', 'lote', v_datos, p_usuario_id);
        v_vista := bot_com_pedir_lote(v_datos);
      END IF;

    WHEN 'lote' THEN
      v_r := agregar_linea_entrada(p_usuario_id, v_entrada,
               (v_datos->>'medicamento_id')::uuid,
               (v_datos->>'cantidad')::numeric,
               (v_datos->>'costo')::numeric,
               (v_datos->>'vence')::date, p_texto);

      IF (v_r->>'ok')::boolean THEN
        PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                  jsonb_build_object('entrada_id', v_entrada), p_usuario_id);
        v_vista := bot_com_entrada(v_entrada, p_usuario_id);
      ELSE
        v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'com:volver'))));
      END IF;

    WHEN 'documento' THEN
      v_r := anotar_entrada(p_usuario_id, v_entrada, p_texto);
      PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
                jsonb_build_object('entrada_id', v_entrada), p_usuario_id);
      v_vista := bot_com_entrada(v_entrada, p_usuario_id);

    ELSE
      RETURN NULL;
  END CASE;

  RETURN jsonb_build_object('acciones', jsonb_build_array(
    accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;

-- ---------------------------------------------------------------------
-- Foto de la factura (§9)
--
-- Llega como un mensaje cualquiera: si hay una entrada abierta, se
-- engancha ahí. Telegram manda la misma foto en varios tamaños; el último
-- del arreglo es el de mayor resolución, que es el que sirve para leer un
-- número de factura.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_com_media(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje jsonb, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado jsonb := estado_leer(p_chat_id);
  v_datos  jsonb := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_entrada uuid := NULLIF(v_datos->>'entrada_id', '')::uuid;
  v_file_id text;
  v_vista  jsonb;
BEGIN
  IF v_estado->>'flujo' IS DISTINCT FROM 'entrada' THEN
    -- Puede que el flujo haya expirado pero el borrador siga ahí: si el
    -- usuario manda la foto de la factura que acaba de digitar, engancharla
    -- es lo que espera que pase.
    v_entrada := entrada_borrador_de(p_usuario_id);
    IF v_entrada IS NULL THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_entrada IS NULL THEN
    v_entrada := entrada_borrador_de(p_usuario_id);
  END IF;
  IF v_entrada IS NULL THEN
    RETURN NULL;
  END IF;

  v_file_id := COALESCE(
    (SELECT x->>'file_id' FROM jsonb_array_elements(p_mensaje->'photo') x
      ORDER BY (x->>'file_size')::bigint DESC NULLS LAST LIMIT 1),
    p_mensaje->'document'->>'file_id');

  IF v_file_id IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM adjuntar_soporte_entrada(p_usuario_id, v_entrada, v_file_id);

  -- El pie de la foto, si lo trae, suele ser el número de la factura.
  IF NULLIF(trim(COALESCE(p_mensaje->>'caption', '')), '') IS NOT NULL THEN
    PERFORM anotar_entrada(p_usuario_id, v_entrada, p_mensaje->>'caption');
  END IF;

  PERFORM estado_guardar(p_chat_id, 'entrada', 'entrada',
            jsonb_build_object('entrada_id', v_entrada), p_usuario_id);

  v_vista := bot_com_entrada(v_entrada, p_usuario_id);

  RETURN jsonb_build_object('acciones', jsonb_build_array(
    accion_enviar(p_chat_id, '📎 Factura guardada.' || E'\n\n' || (v_vista->>'texto'),
                  v_vista->'botones')));
END;
$$;

-- ---------------------------------------------------------------------
-- Despachadores: se añade compras a los módulos anteriores
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_cli_menu(p_usuario_id) || bot_inv_menu(p_usuario_id)
      || bot_cob_menu(p_usuario_id) || bot_com_menu(p_usuario_id);
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
    bot_com_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cli_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_modulo_media(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje jsonb, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT bot_com_media(p_usuario_id, p_chat_id, p_mensaje, p_sede_id);
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
         '/sesiones — sesiones abiertas en el portal' || E'\n' ||
         '/ayuda — esta ayuda';
$$;
