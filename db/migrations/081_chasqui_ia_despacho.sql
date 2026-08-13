-- =====================================================================
-- Chasqui Pet — 081_chasqui_ia_despacho.sql
-- Fase 3: despacho múltiple de recetas asistido por «Habla con Chasqui».
--
-- Despachar una receta es la operación más frecuente y la que más toca el
-- inventario: varios medicamentos, y cada uno puede salir de varios lotes.
-- El menú lo hace producto por producto; el asistente lo hará de una vez:
--
--   «despacha 2 de amoxicilina y 1 de metronidazol para Luna»
--
-- El diseño sigue las tres reglas de 078 y de la fase 2:
--
--   1. NADA de SQL libre: el modelo escoge la herramienta
--      `despachar_receta_multiple` y pasa una lista tipada de ítems
--      ({medicamento_id | nombre, cantidad, motivo}). Lo que no esté en
--      `ia_herramienta` no existe para él.
--
--   2. Los permisos son los del usuario: la herramienta pide
--      `inventario.salida` en el catálogo, `ia_llamar` la filtra y
--      `ia_despacho_borrador`/`ia_despacho_ejecutar` vuelven a exigirlo.
--
--   3. ESCRIBIR se confirma con un botón (C6.9). El borrador arma la
--      tarjeta de desglose —producto, lote, cantidad, precio, total— y
--      deja la propuesta en `ia_accion_pendiente`. La confirmación dispara
--      la ejecución, que es la única que toca `movimiento_inventario`.
--
-- FEFO sobre la arquitectura existente (045_inventario.sql): la resolución
-- escoge, por cada medicamento, los lotes en orden de vencimiento próximo
-- (`v_lote_disponible`) hasta cubrir la cantidad pedida. Este archivo NO
-- introduce un mecanismo nuevo de stock: rehusa `salida_medicamento`
-- (misma transacción, misma auditoría, mismo encolado de `agregar_linea_cuenta`
-- para el cobro). La diferencia es que la resolución es ATÓMICA: en la
-- ejecución se bloquean de una vez (FOR UPDATE en un solo orden) todos los
-- lotes candidatos de todos los medicamentos antes de descontar, de modo
-- que dos despachos simultáneos no lean dos veces la misma existencia.
--
-- La tarjeta que se confirma se armó con los datos de ESE instante; si el
-- stock cambió antes del botón, la ejecución re-resuelve sobre los lotes
-- bloqueados y, si algo no alcanza, no despacha NADA (rollback completo).
-- Se falla, no se adivina.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1. La herramienta en el catálogo
-- ---------------------------------------------------------------------
INSERT INTO ia_herramienta (nombre, permiso, escribe, critica, orden, descripcion, esquema) VALUES
('despachar_receta_multiple', 'inventario.salida', true, true, 265,
 'Despacha de una sola vez varios medicamentos de una receta: descuenta del inventario las '
 'cantidades pedidas de cada uno, escogiendo en cada producto el lote que vence primero (FEFO). '
 'Úsala cuando pidan sacar o despachar más de un medicamento en conjunto (una receta, un turno, '
 'un tratamiento completo). Para cada medicamento pasa su medicamento_id —que sale de '
 'buscar_medicamento— o su nombre, y la cantidad en la unidad del producto. NUNCA la uses para '
 'un solo medicamento: para eso está registrar_salida_medicamento. No ejecuta nada sola: deja '
 'una tarjeta con el desglose por lote y por cantidad y espera la confirmación.',
 '{"type":"object","properties":{
    "items":{"type":"array","description":"Medicamentos a despachar",
      "items":{"type":"object","properties":{
        "medicamento_id":{"type":"string","description":"UUID del medicamento, que sale de buscar_medicamento"},
        "nombre":{"type":"string","description":"Nombre del medicamento, alternativo a medicamento_id. Búsqueda tolerante"},
        "cantidad":{"type":"number","description":"Cantidad a despachar, en la unidad del medicamento"},
        "motivo":{"type":"string","description":"Para qué se despacha (receta, tratamiento...). Opcional"}},
      "required":["cantidad"]}},
    "notas":{"type":"string","description":"Nota general del despacho. Opcional"}},
  "required":["items"]}'::jsonb)
ON CONFLICT (nombre) DO UPDATE
  SET permiso = EXCLUDED.permiso, escribe = EXCLUDED.escribe, critica = EXCLUDED.critica,
      descripcion = EXCLUDED.descripcion, esquema = EXCLUDED.esquema, orden = EXCLUDED.orden;


-- ---------------------------------------------------------------------
-- 2. Resolución FEFO (compartida por borrador y ejecución)
--
-- Toma la lista normalizada de ítems {medicamento_id, cantidad} y devuelve,
-- para cada uno, los lotes en orden de vencimiento más próximo con la
-- cantidad que aportaría cada uno hasta cubrir lo pedido. No descuenta
-- nada ni bloquea filas: es una proyección del estado actual. La ejecución
-- la vuelve a llamar DESPUÉS de bloquear los lotes, así que el plan que
-- produce allí es el mismo que se va a ejecutar.
--
-- Contrato de salida:
--   {ok, items: [{
--      medicamento_id, nombre, presentacion, unidad, precio_venta,
--      cantidad, cubierto, faltante, valor,
--      lotes: [{lote_id, numero_lote, vence, dias_para_vencer, cantidad}]}],
--    total}
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_despacho_asignar(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_item     jsonb;
  v_med      record;
  v_lot      record;
  v_med_id   uuid;
  v_cant     numeric;
  v_pend     numeric;
  v_chunk    numeric;
  v_lotes    jsonb := '[]'::jsonb;
  v_salida   jsonb := '[]'::jsonb;
  v_total    numeric := 0;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta la lista de medicamentos a despachar.');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Cada medicamento de la lista debe ser un objeto con medicamento_id o nombre y cantidad.');
    END IF;

    v_med_id := NULLIF(v_item->>'medicamento_id', '')::uuid;

    IF v_med_id IS NULL THEN
      SELECT b.medicamento_id INTO v_med_id
        FROM buscar_medicamento(v_item->>'nombre', 1) b;
      IF v_med_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
          format('No encontré «%s» en el catálogo. Búscalo con buscar_medicamento y pasa su medicamento_id.',
                 v_item->>'nombre'));
      END IF;
    END IF;

    SELECT m.id, m.nombre_generico, m.nombre_comercial, m.presentacion,
           m.unidad_base, m.precio_venta
      INTO v_med
      FROM medicamento m
     WHERE m.id = v_med_id AND m.activo;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Ese medicamento ya no existe o está inactivo. Vuelve a buscarlo con buscar_medicamento.');
    END IF;

    BEGIN
      v_cant := (v_item->>'cantidad')::numeric;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('«%s» no es una cantidad válida para %s.',
               v_item->>'cantidad',
               v_med.nombre_generico || COALESCE(' (' || v_med.nombre_comercial || ')', '')));
    END;

    IF v_cant IS NULL OR v_cant <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('La cantidad de %s debe ser mayor que cero.',
               v_med.nombre_generico || COALESCE(' (' || v_med.nombre_comercial || ')', '')));
    END IF;

    -- FEFO: lotes disponibles en orden de vencimiento, hasta cubrir.
    v_pend  := v_cant;
    v_lotes := '[]'::jsonb;
    FOR v_lot IN
      SELECT lote_id, numero_lote, fecha_vencimiento, dias_para_vencer, cantidad_actual
        FROM v_lote_disponible
       WHERE medicamento_id = v_med_id
       ORDER BY fecha_vencimiento, lote_id
    LOOP
      EXIT WHEN v_pend <= 0;
      v_chunk := LEAST(v_pend, v_lot.cantidad_actual);
      IF v_chunk > 0 THEN
        v_lotes := v_lotes || jsonb_build_object(
          'lote_id',           v_lot.lote_id,
          'numero_lote',       v_lot.numero_lote,
          'vence',             v_lot.fecha_vencimiento,
          'dias_para_vencer',  v_lot.dias_para_vencer,
          'cantidad',          v_chunk);
        v_pend := v_pend - v_chunk;
      END IF;
    END LOOP;

    v_salida := v_salida || jsonb_build_object(
      'medicamento_id', v_med_id,
      'nombre', v_med.nombre_generico || COALESCE(' (' || v_med.nombre_comercial || ')', ''),
      'presentacion', v_med.presentacion,
      'unidad', v_med.unidad_base,
      'precio_venta', v_med.precio_venta,
      'cantidad', v_cant,
      'cubierto', v_cant - GREATEST(v_pend, 0),
      'faltante', GREATEST(v_pend, 0),
      'valor', round(v_med.precio_venta * (v_cant - GREATEST(v_pend, 0)), 2),
      'lotes', v_lotes);

    v_total := v_total + (v_med.precio_venta * (v_cant - GREATEST(v_pend, 0)));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'items', v_salida, 'total', round(v_total, 2));
END;
$$;


-- ---------------------------------------------------------------------
-- 3. El borrador: estructura lo dictado, arma la tarjeta de desglose y
--    deja la propuesta en `ia_accion_pendiente`
--
-- Igual que el alta (F1) y el borrador de consulta (F2), no toca inventario.
-- Si hoy no alcanza para algún producto, NO propone: se lo devuelve al
-- modelo como error para que le diga al usuario y ajuste.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_despacho_borrador(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_items_in  jsonb := p_args->'items';
  v_items     jsonb := '[]'::jsonb;
  v_elem      jsonb;
  v_med_id    uuid;
  v_nombre    text;
  v_r         jsonb;
  v_item      jsonb;
  v_lot       jsonb;
  v_faltan    text[] := ARRAY[]::text[];
  v_accion    uuid;
  v_total     numeric := 0;
  v_resumen   text;
  v_notas     text := NULLIF(trim(COALESCE(p_args->>'notas', '')), '');
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'inventario.salida');

  IF v_items_in IS NULL OR jsonb_typeof(v_items_in) <> 'array'
     OR jsonb_array_length(v_items_in) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta la lista de medicamentos a despachar. Pasa al menos uno con su cantidad.');
  END IF;

  -- 1) Normalizar: resolver cada medicamento (por id o por nombre) y su cantidad.
  FOR v_elem IN SELECT * FROM jsonb_array_elements(v_items_in) LOOP
    IF jsonb_typeof(v_elem) <> 'object' THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Cada medicamento de la lista debe ser un objeto con nombre o medicamento_id y cantidad.');
    END IF;

    v_med_id := NULLIF(v_elem->>'medicamento_id', '')::uuid;
    v_nombre := NULL;

    IF v_med_id IS NULL THEN
      SELECT b.medicamento_id INTO v_med_id
        FROM buscar_medicamento(v_elem->>'nombre', 1) b;
      IF v_med_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
          format('No encontré «%s» en el catálogo. Búscalo con buscar_medicamento y pasa su medicamento_id.',
                 v_elem->>'nombre'));
      END IF;
    ELSE
      SELECT nombre_generico INTO v_nombre
        FROM medicamento WHERE id = v_med_id AND activo;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Ese medicamento ya no existe o está inactivo. Vuelve a buscarlo con buscar_medicamento.');
      END IF;
    END IF;

    IF v_elem->>'cantidad' IS NULL
       OR (regexp_match(v_elem->>'cantidad', '^[0-9]+([.,][0-9]+)?$')) IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('«%s» no es una cantidad válida de %s. Pide la cantidad de nuevo.',
               v_elem->>'cantidad', COALESCE(v_nombre, v_elem->>'nombre')));
    END IF;

    v_items := v_items || jsonb_build_object(
      'medicamento_id', v_med_id,
      'cantidad', replace(v_elem->>'cantidad', ',', '.')::numeric,
      'motivo', NULLIF(trim(COALESCE(v_elem->>'motivo', '')), ''));
  END LOOP;

  -- 2) Resolver FEFO sobre el estado actual.
  v_r := ia_despacho_asignar(v_items);
  IF NOT (v_r->>'ok')::boolean THEN RETURN v_r; END IF;

  -- 3) Si algo no alcanza HOY, no se arma propuesta: la tarjeta nunca
  --    propone algo que la ejecución rechazaría.
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_r->'items') LOOP
    IF COALESCE((v_item->>'faltante')::numeric, 0) > 0 THEN
      v_faltan := v_faltan ||
        format('%s (pide %s %s y solo hay %s)', v_item->>'nombre',
               fmt_cant((v_item->>'cantidad')::numeric), v_item->>'unidad',
               fmt_cant((v_item->>'cubierto')::numeric));
    END IF;
  END LOOP;

  IF array_length(v_faltan, 1) IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No alcanza el inventario para: ' || frase_lista(v_faltan) || '.' ||
      ' Dilo con naturalidad y pregúntale al usuario si ajusta la cantidad o cambia de medicamento.');
  END IF;

  -- 4) La tarjeta de desglose: cantidades, lotes FEFO y precios.
  v_total := (v_r->>'total')::numeric;

  v_resumen := '💊 <b>Despacho de receta — ' ||
               jsonb_array_length(v_r->'items') ||
               CASE WHEN jsonb_array_length(v_r->'items') = 1 THEN ' medicamento</b>'
                    ELSE ' medicamentos</b>' END;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_r->'items') LOOP
    v_resumen := v_resumen || E'\n\n' ||
                 '💊 <b>' || esc(v_item->>'nombre') || '</b>' ||
                 CASE WHEN v_item->>'presentacion' IS NOT NULL
                      THEN ' · ' || esc(v_item->>'presentacion') ELSE '' END ||
                 E'\n' ||
                 '   ' || fmt_cant((v_item->>'cantidad')::numeric) || ' ' ||
                 esc(v_item->>'unidad') || ' × ' ||
                 pesos((v_item->>'precio_venta')::numeric) || ' = <b>' ||
                 pesos((v_item->>'valor')::numeric) || '</b>';

    FOR v_lot IN SELECT * FROM jsonb_array_elements(v_item->'lotes') LOOP
      v_resumen := v_resumen || E'\n' ||
                   '   · Lote <b>' || esc(v_lot->>'numero_lote') || '</b>: ' ||
                   fmt_cant((v_lot->>'cantidad')::numeric) || ' — vence ' ||
                   to_char((v_lot->>'vence')::date, 'DD/MM/YYYY');
    END LOOP;
  END LOOP;

  v_resumen := v_resumen || E'\n\n' || '💰 <b>Total: ' || pesos(v_total) || '</b>' ||
               E'\n' || 'De cada uno sale el lote que vence primero (FEFO).' ||
               E'\n' || '⚠️ El stock se revalida al confirmar; no se descuenta nada ahora.' ||
               CASE WHEN v_notas IS NOT NULL
                    THEN E'\n' || '📝 ' || esc(v_notas) ELSE '' END;

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, 'despachar_receta_multiple',
          jsonb_build_object('items', v_items, 'notas', v_notas), v_resumen)
  RETURNING id INTO v_accion;

  RETURN jsonb_build_object('ok', true, 'requiere_confirmacion', true,
    'accion_id', v_accion, 'critica', true, 'resumen', v_resumen);
END;
$$;


-- ---------------------------------------------------------------------
-- 4. La ejecución: confirmó la persona, se descuenta.
--
-- Atómica de verdad (C6.5 + C6.12): exige `inventario.salida`, bloquea en
-- UN SOLO orden todos los lotes candidatos de todos los medicamentos
-- (FOR UPDATE), re-resuelve FEFO sobre esos lotes bloqueados y entonces
-- rehusa `salida_medicamento` por cada tramo — misma auditoría y mismo
-- encolado de cobro que el menú. Si entre la propuesta y el botón algo ya
-- no alcanza, no se descuenta NADA: la transacción se revierte entera.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_despacho_ejecutar(p_usuario_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_items     jsonb := p_args->'items';
  v_med_ids   uuid[] := ARRAY[]::uuid[];
  v_elem      jsonb;
  v_item      jsonb;
  v_lot       jsonb;
  v_r         jsonb;
  v_s         jsonb;
  v_out       jsonb := '[]'::jsonb;
  v_total     numeric := 0;
  v_idx       int    := 0;
  v_j         int;
  v_motivo    text;
  v_motivo_chunk text;
  v_prev_lote text;
  v_cant      numeric;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'inventario.salida');

  IF v_items IS NULL OR jsonb_typeof(v_items) <> 'array'
     OR jsonb_array_length(v_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
      'No llegó la lista de medicamentos a despachar. Vuelve a pedirlo.');
  END IF;

  BEGIN
    -- Reunir los medicamentos y bloquear en un solo orden determinista
    -- todos sus lotes aprovechables: nadie más puede tocar esa existencia
    -- hasta que este despacho termine.
    FOR v_elem IN SELECT * FROM jsonb_array_elements(v_items) LOOP
      IF NULLIF(v_elem->>'medicamento_id', '') IS NOT NULL
         AND NOT v_med_ids @> ARRAY[(v_elem->>'medicamento_id')::uuid] THEN
        v_med_ids := array_append(v_med_ids, (v_elem->>'medicamento_id')::uuid);
      END IF;
    END LOOP;

    IF COALESCE(array_length(v_med_ids, 1), 0) = 0 THEN
      RETURN jsonb_build_object('ok', false, 'mensaje',
        'La propuesta no trae medicamentos válidos. Vuelve a pedir el despacho.');
    END IF;

    PERFORM 1
      FROM lote l
     WHERE l.medicamento_id = ANY(v_med_ids)
       AND NOT l.bloqueado
       AND l.cantidad_actual > 0
       AND l.fecha_vencimiento >= hoy_bogota()
     ORDER BY l.medicamento_id, l.id
       FOR UPDATE;

    -- Re-resolver FEFO sobre los lotes bloqueados: es el plan que se ejecuta.
    v_r := ia_despacho_asignar(v_items);
    IF NOT (v_r->>'ok')::boolean THEN RETURN v_r; END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_r->'items') LOOP
      IF COALESCE((v_item->>'faltante')::numeric, 0) > 0 THEN
        RETURN jsonb_build_object('ok', false, 'mensaje',
          'Mientras esperabas el botón, ya no alcanza para ' || esc(v_item->>'nombre') ||
          ': faltan ' || fmt_cant((v_item->>'faltante')::numeric) || ' ' ||
          esc(v_item->>'unidad') || '. No se descontó nada.');
      END IF;
    END LOOP;

    -- Despachar tramo por tramo. Un tramo que no sea el primero pide motivo
    -- por FEFO (045): se deja constancia de que el lote que vence primero
    -- se agotó. Esto queda en `movimiento_inventario.motivo`.
    v_idx := 0;
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_r->'items') LOOP
      v_motivo  := COALESCE(NULLIF((v_items->v_idx)->>'motivo', ''), '');
      v_prev_lote := NULL;
      v_j := 0;
      FOR v_lot IN SELECT * FROM jsonb_array_elements(v_item->'lotes') LOOP
        v_cant := (v_lot->>'cantidad')::numeric;

        IF v_j > 0 THEN
          v_motivo_chunk := 'FEFO: agotado el lote ' || COALESCE(v_prev_lote, 'anterior');
          IF v_motivo <> '' THEN v_motivo_chunk := v_motivo || ' · ' || v_motivo_chunk; END IF;
        ELSE
          v_motivo_chunk := NULLIF(v_motivo, '');
        END IF;

        v_s := salida_medicamento(
                 p_usuario_id, (v_lot->>'lote_id')::uuid, v_cant,
                 v_motivo_chunk, NULL, NULL, NULL, 'telegram');

        IF NOT (v_s->>'ok')::boolean THEN RETURN v_s; END IF;

        v_out := v_out || jsonb_build_object(
          'medicamento', v_item->>'nombre',
          'numero_lote', v_lot->>'numero_lote',
          'cantidad', v_cant,
          'unidad', v_item->>'unidad',
          'precio_venta', (v_item->>'precio_venta')::numeric,
          'valor', round((v_item->>'precio_venta')::numeric * v_cant, 2),
          'restante', v_s->'movimiento'->>'restante');

        v_total := v_total + (v_item->>'precio_venta')::numeric * v_cant;
        v_prev_lote := v_lot->>'numero_lote';
        v_j := v_j + 1;
      END LOOP;
      v_idx := v_idx + 1;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'despacho',
      jsonb_build_object('productos', jsonb_array_length(v_r->'items'),
                         'total', round(v_total, 2),
                         'items', v_out));
  EXCEPTION
    WHEN deadlock_detected OR serialization_failure THEN
      RETURN jsonb_build_object('ok', false, 'mensaje',
        'Otra persona estaba despachando los mismos medicamentos en este instante. '
        'Nada se descontó; pídelo de nuevo.');
  END;
END;
$$;


-- ---------------------------------------------------------------------
-- 5. Enganches con el asistente
-- ---------------------------------------------------------------------

-- `despachar_receta_multiple` tiene su propio engranaje (normalización +
-- tarjeta), como el alta y el borrador de consulta, así que escapa del
-- camino genérico de escritura de `ia_llamar`.
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
  -- borrador de consulta F2, despacho múltiple F3): preparan su propuesta
  -- aquí y ya dejan `ia_accion_pendiente`.
  IF p_nombre IN ('preparar_alta_paciente', 'preparar_consulta_clinica',
                  'despachar_receta_multiple') THEN
    CASE p_nombre
      WHEN 'preparar_alta_paciente'    THEN RETURN ia_alta_paciente_borrador(
        p_usuario_id, p_chat_id, p_sede_id, COALESCE(p_args, '{}'::jsonb));
      WHEN 'preparar_consulta_clinica' THEN RETURN ia_consulta_borrador(
        p_usuario_id, p_chat_id, p_sede_id, COALESCE(p_args, '{}'::jsonb));
      WHEN 'despachar_receta_multiple' THEN RETURN ia_despacho_borrador(
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

-- La confirmación ejecuta la misma transacción atómica del despacho.
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

    ELSE
      RETURN jsonb_build_object('ok', false,
        'mensaje', format('La herramienta %s no existe.', p_nombre));
  END CASE;

  RETURN v;
END;
$$;

-- Resultado que ve la persona tras confirmar.
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
      ELSE NULL
    END);
$$;

-- Bienvenida: un ejemplo para quien despacha recetas con el asistente.
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
  IF tiene_permiso(p_usuario_id, 'pacientes.ver') THEN
    v_ej := v_ej || E'\n' || '· «tráeme la historia de Luna»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'consulta.crear') THEN
    v_ej := v_ej || E'\n' || '· «déjame el borrador de Luna: vómito, 4.2 kg, gastroenteritis»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'pacientes.editar') THEN
    v_ej := v_ej || E'\n' || '· «registra a Luna, gata de 2 años, dueña María Gómez»';
  END IF;

  RETURN '💬 <b>Habla con Chasqui</b>' || E'\n\n' ||
         'Escríbeme como le escribirías a un compañero. Consulto los datos reales de ' ||
         esc(config_txt('nombre_clinica', 'Chasqui Pet')) || ' y también te explico cómo ' ||
         'funciona algo de la clínica.' ||
         CASE WHEN v_ej <> '' THEN E'\n\n' || 'Por ejemplo:' || v_ej ELSE '' END ||
         E'\n\n' || 'Si te ayudo con algo que <b>cambia</b> datos —llamar un turno, sacar un ' ||
         'medicamento, registrar un pago— te muestro primero qué va a pasar y lo confirmas tú.' ||
         E'\n\n' || 'Para volver a los botones, escribe /menu.';
END;
$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON ia_mensaje, ia_accion_pendiente TO chasquipet_app;