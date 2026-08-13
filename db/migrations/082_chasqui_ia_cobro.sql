-- =====================================================================
-- Chasqui Pet — 082_chasqui_ia_cobro.sql
-- Fase 4: paquetes de servicios y descuentos asistidos en «Habla con Chasqui».
--
-- Dos escrituras del mostrador que hoy se hacen servicio por servicio
-- (agregar_servicio_a_cuenta) quedan como herramientas de una sola vuelta:
--
--   «cárgale a la cuenta de Luna la consulta y el antipulgas»
--   «aplícale un descuento del 10 % a la cuenta de Luna»
--   «arregla la cuenta de Luna y cobra»
--
-- El diseño sigue las mismas reglas de 078/079/081:
--
--   1. NADA de SQL libre: dos herramientas, `cargar_paquete_servicios` y
--      `aplicar_descuento_asistido`, con esquemas tipados. La primera
--      agrega de una vez varios servicios (por tarifa_id de ver_tarifas o
--      por nombre tolerante) y trae un descuento opcional; la segunda
--      rebaja una cuenta ya hecha.
--
--   2. Los permisos son los del usuario: `cobro.linea` para armar la
--      pre-factura, `cobro.descuento` para rebajar (lo re-exige el borrador
--      si el paquete trae descuento, y la ejecución), y `cobro.pago` para
--      cobrar. Tres rejas como en las fases anteriores (catálogo,
--      ia_llamar, exigir_permiso en la función de negocio).
--
--   3. ESCRIBIR se confirma con un botón (C6.9). El borrador arma la
--      tarjeta de PRE-FACTURA —líneas nuevas, subtotal, descuento y total
--      del resultado— y deja la propuesta en `ia_accion_pendiente`. La
--      confirmación es la única que toca `cuenta_linea`/`descuento`.
--
--   4. La operación económica es append-only por construcción: se rehusan
--      `agregar_linea_servicio` y `aplicar_descuento` (060_cobro.sql), que
--      ya auditan y cuya mutación corre por los triggers de inmutabilidad.
--      La ejecución es atómica: si un servicio o el descuento falla en
--      medio, no queda NINGUNA línea ni rebaja (rollback de la propuesta).
--
--   5. El botón «💳 Cobrar y cerrar» cierra la pre-factura de una vez:
--      confirma la propuesta, registra el pago del saldo (efectivo) y
--      cierra la cuenta con su recibo. Rehusa `registrar_pago` y
--      `cerrar_cuenta` y se comporta igual que la confirmación normal.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1. Herramientas en el catálogo
-- ---------------------------------------------------------------------
INSERT INTO ia_herramienta (nombre, permiso, escribe, critica, orden, descripcion, esquema) VALUES
('cargar_paquete_servicios', 'cobro.linea', true, true, 275,
 'Agrega de una sola vez varios servicios a una cuenta abierta y, opcionalmente, un descuento '
 'sobre toda la pre-factura. Úsala cuando pidan cargar a una cuenta varios servicios en conjunto '
 '(un plan de vacunación, consulta más desparasitación, un paquete) o cuando quieran dejar la '
 'cuenta lista para cobrar. Para cada servicio pasa su tarifa_id —que sale de ver_tarifas— o su '
 'nombre. Necesita el cuenta_id, que sale de cuentas_por_cobrar. Si lleva descuento, primero '
 'verifica que quien pide tenga permiso de descuento. No cobra nada sola: deja una pre-factura '
 'con el subtotal, el descuento y el total y espera la confirmación.',
 '{"type":"object","properties":{
    "cuenta_id":{"type":"string","description":"UUID de la cuenta abierta, que sale de cuentas_por_cobrar"},
    "items":{"type":"array","description":"Servicios a cargar en la cuenta",
      "items":{"type":"object","properties":{
        "tarifa_id":{"type":"string","description":"UUID de la tarifa del servicio, que sale de ver_tarifas"},
        "nombre":{"type":"string","description":"Nombre del servicio, alternativo a tarifa_id. Búsqueda tolerante"},
        "descripcion":{"type":"string","description":"Descripción del servicio si no está tarifado (valor libre)"},
        "cantidad":{"type":"number","description":"Cantidad, por defecto 1"},
        "valor":{"type":"number","description":"Valor unitario en pesos. Solo si el servicio es de valor libre o no tiene tarifa"}}},
      "required":[]},
    "descuento":{"type":"object","description":"Descuento opcional sobre la pre-factura, aplicado en la misma cuenta",
      "properties":{
        "valor":{"type":"string","description":"Monto en pesos o porcentaje, por ejemplo 10000 o 10%"},
        "motivo":{"type":"string","description":"Motivo escrito del descuento, obligatorio si va descuento"}}},
    "notas":{"type":"string","description":"Nota general del paquete. Opcional"}},
  "required":["cuenta_id","items"]}'::jsonb)

,('aplicar_descuento_asistido', 'cobro.descuento', true, true, 285,
 'Aplica un descuento a una cuenta abierta, ya sea de una vez (con su motivo) y queda registrado '
 'quién lo autorizó. Úsala cuando pidan «déjame un descuento», «rebaja», «aplícale el buen '
 'cliente» a una cuenta que ya tiene servicios o medicamentos. Necesita el cuenta_id, que sale de '
 'cuentas_por_cobrar. El valor puede ser un monto en pesos o un porcentaje (por ejemplo 10000 o '
 '10%). Todo descuento exige un motivo escrito. No aplica nada sola: deja la pre-factura con el '
 'subtotal, el descuento y el total y espera la confirmación.',
 '{"type":"object","properties":{
    "cuenta_id":{"type":"string","description":"UUID de la cuenta abierta, que sale de cuentas_por_cobrar"},
    "valor":{"type":"string","description":"Monto en pesos o porcentaje de descuento, por ejemplo 10000 o 10%"},
    "motivo":{"type":"string","description":"Motivo escrito y obligatorio del descuento"}},
  "required":["cuenta_id","valor","motivo"]}'::jsonb)

ON CONFLICT (nombre) DO UPDATE
  SET permiso = EXCLUDED.permiso, escribe = EXCLUDED.escribe, critica = EXCLUDED.critica,
      descripcion = EXCLUDED.descripcion, esquema = EXCLUDED.esquema, orden = EXCLUDED.orden;


-- ---------------------------------------------------------------------
-- 2. Auxiliares de normalización
-- ---------------------------------------------------------------------

-- Resuelve un servicio por nombre de forma tolerante (igual, o que lo
-- contenga, o por código), prefiriendo la coincidencia exacta. Devuelve la
-- tarifa vigente más corta; se usa en el borrador del paquete.
CREATE OR REPLACE FUNCTION ia_buscar_tarifa(p_texto text)
RETURNS TABLE (
  tarifa_id uuid, nombre text, valor_sugerido numeric, permite_valor_libre boolean
)
LANGUAGE sql STABLE AS $$
  SELECT id, nombre, valor_sugerido, permite_valor_libre
    FROM tarifa
   WHERE activa
     AND (normalizar(nombre) = normalizar(p_texto)
          OR normalizar(nombre) LIKE '%' || normalizar(p_texto) || '%'
          OR normalizar(COALESCE(codigo, '')) = normalizar(p_texto))
   ORDER BY CASE WHEN normalizar(nombre) = normalizar(p_texto) THEN 0 ELSE 1 END,
            length(nombre)
   LIMIT 1;
$$;

-- «10000», «10%», «12 %» → el monto. El porcentaje se calcula sobre la
-- base que le pase el llamador (lo que queda por cobrar antes del
-- descuento). Igual que parse_pesos, la puntuación se ignora.
CREATE OR REPLACE FUNCTION ia_parse_descuento(p_valor text, p_base numeric)
RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE v_t text := NULLIF(trim(COALESCE(p_valor, '')), '');
        v_m text[];
        v_n numeric;
BEGIN
  IF v_t IS NULL THEN RETURN NULL; END IF;

  v_m := regexp_match(v_t, '^(\d+(?:[.,]\d+)?)\s*%$');
  IF v_m IS NOT NULL THEN
    RETURN round(p_base * replace(v_m[1], ',', '.')::numeric / 100, 2);
  END IF;

  v_n := NULLIF(regexp_replace(v_t, '\D', '', 'g'), '');
  RETURN v_n;
END;
$$;


-- ---------------------------------------------------------------------
-- 3. El borrador del paquete: pre-factura
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_cargar_paquete_borrador(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_cuenta_id    uuid := NULLIF(p_args->>'cuenta_id', '')::uuid;
  v_items_in     jsonb := p_args->'items';
  v_elem         jsonb;
  v_tid          uuid;
  v_tnom         text;
  v_tvalor       numeric;
  v_cant         numeric;
  v_valor        numeric;
  v_items        jsonb := '[]'::jsonb;
  v_sum          numeric := 0;      -- suma de esta propuesta
  v_c_sub        numeric;           -- subtotal actual de la cuenta
  v_c_desc       numeric;           -- descuento actual de la cuenta
  v_estado       text;
  v_paciente     text;
  v_esp          text;
  v_desc_obj     jsonb := p_args->'descuento';
  v_desc_ok      boolean := false;
  v_desc_monto   numeric;
  v_desc_motivo  text;
  v_mont_base    numeric;
  v_res_sub      numeric;
  v_res_desc     numeric;
  v_res_total    numeric;
  v_notas        text := NULLIF(trim(COALESCE(p_args->>'notas', '')), '');
  v_resumen      text;
  v_accion       uuid;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'cobro.linea');

  IF v_cuenta_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta la cuenta. Usa cuentas_por_cobrar y pasa su cuenta_id.');
  END IF;

  SELECT c.subtotal, c.descuento, c.estado, p.nombre, p.especie
    INTO v_c_sub, v_c_desc, v_estado, v_paciente, v_esp
    FROM cuenta c LEFT JOIN paciente p ON p.id = c.paciente_id
   WHERE c.id = v_cuenta_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Esa cuenta ya no existe.');
  END IF;
  IF v_estado <> 'abierta' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('La cuenta está %s y ya no admite servicios.', v_estado));
  END IF;
  v_esp := COALESCE(v_esp, 'otro');

  IF v_items_in IS NULL OR jsonb_typeof(v_items_in) <> 'array'
     OR jsonb_array_length(v_items_in) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta la lista de servicios a cargar. Pasa al menos uno con su cantidad.');
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(v_items_in) LOOP
    IF jsonb_typeof(v_elem) <> 'object' THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Cada servicio de la lista debe ser un objeto con tarifa_id o nombre.');
    END IF;

    v_tid    := NULLIF(v_elem->>'tarifa_id', '')::uuid;
    v_tnom   := NULL;
    v_tvalor := NULL;

    -- Servicio libre (sin tarifa): necesita su descripción y su valor.
    IF v_tid IS NULL AND COALESCE(v_elem->>'nombre', '') = '' THEN
      v_tnom   := NULLIF(trim(COALESCE(v_elem->>'descripcion', '')), '');
      IF v_tnom IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
          'Un servicio sin tarifa necesita su descripción.');
      END IF;
    ELSE
      IF v_tid IS NULL THEN
        SELECT t.tarifa_id, t.nombre, t.valor_sugerido
          INTO v_tid, v_tnom, v_tvalor
          FROM ia_buscar_tarifa(v_elem->>'nombre') t;
        IF v_tid IS NULL THEN
          RETURN jsonb_build_object('ok', false, 'error',
            format('No encontré «%s» en los servicios. Usa ver_tarifas y pasa su tarifa_id.',
                   v_elem->>'nombre'));
        END IF;
      ELSE
        SELECT nombre, valor_sugerido
          INTO v_tnom, v_tvalor
          FROM tarifa WHERE id = v_tid AND activa;
        IF NOT FOUND THEN
          RETURN jsonb_build_object('ok', false, 'error',
            'Ese servicio ya no existe o está inactivo. Vuelve a buscarlo con ver_tarifas.');
        END IF;
      END IF;
    END IF;

    -- Cantidad: por defecto 1; no se acepta un número mal escrito ni ≤ 0.
    IF v_elem->>'cantidad' IS NULL THEN
      v_cant := 1;
    ELSIF (regexp_match(v_elem->>'cantidad', '^[0-9]+([.,][0-9]+)?$')) IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('«%s» no es una cantidad válida de %s.',
               v_elem->>'cantidad', COALESCE(v_tnom, v_elem->>'nombre')));
    ELSE
      v_cant := replace(v_elem->>'cantidad', ',', '.')::numeric;
    END IF;
    IF v_cant <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('La cantidad de %s debe ser mayor que cero.',
               COALESCE(v_tnom, v_elem->>'nombre')));
    END IF;

    -- Valor: el que pase el modelo, o el sugerido de la tarifa. Igual que
    -- agregar_linea_servicio, un valor explícito se respeta tal cual.
    IF v_elem->>'valor' IS NOT NULL AND v_elem->>'valor' <> '' THEN
      v_valor := NULLIF(regexp_replace(v_elem->>'valor', '\D', '', 'g'), '')::numeric;
    ELSE
      v_valor := v_tvalor;
    END IF;
    IF v_valor IS NULL OR v_valor < 0 THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('El servicio «%s» necesita un valor en pesos.', COALESCE(v_tnom, v_elem->>'nombre')));
    END IF;

    v_items := v_items || jsonb_build_object(
      'tarifa_id',       v_tid,
      'descripcion',     v_tnom,
      'cantidad',        v_cant,
      'valor_unitario',  round(v_valor, 2));

    v_sum := v_sum + round(v_valor * v_cant, 2);
  END LOOP;

  -- Descuento opcional: primero el permiso (C6.5) y luego la forma.
  IF v_desc_obj IS NOT NULL THEN
    IF jsonb_typeof(v_desc_obj) <> 'object' OR v_desc_obj->>'valor' IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'El descuento va en un objeto con su valor (monto o porcentaje) y su motivo.');
    END IF;
    PERFORM exigir_permiso(p_usuario_id, 'cobro.descuento');

    v_desc_motivo := NULLIF(trim(COALESCE(v_desc_obj->>'motivo', '')), '');
    IF v_desc_motivo IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Todo descuento necesita un motivo escrito.');
    END IF;

    v_mont_base  := v_c_sub + v_sum - v_c_desc;
    v_desc_monto := ia_parse_descuento(v_desc_obj->>'valor', v_mont_base);
    IF v_desc_monto IS NULL OR v_desc_monto <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'El descuento debe ser un monto o un porcentaje, por ejemplo 10000 o 10%.');
    END IF;
    IF v_desc_monto > v_mont_base THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('El descuento no puede pasar de %s.', pesos(v_mont_base)));
    END IF;
    v_desc_ok := true;
  END IF;

  v_res_sub   := v_c_sub + v_sum;
  v_res_desc  := v_c_desc + CASE WHEN v_desc_ok THEN v_desc_monto ELSE 0 END;
  v_res_total := v_res_sub - v_res_desc;

  -- La tarjeta de pre-factura: lo nuevo, y el resultado con subtotal,
  -- descuento y total por separado.
  v_resumen := '🧾 <b>Pre-factura</b>' ||
               CASE WHEN v_paciente IS NOT NULL
                    THEN ' · ' || esc(emoji_especie(v_esp)) || ' ' || esc(v_paciente)
                    ELSE '' END;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_resumen := v_resumen || E'\n' ||
                 '🩺 <b>' || esc(v_elem->>'descripcion') || '</b>' ||
                 CASE WHEN (v_elem->>'cantidad')::numeric <> 1
                      THEN ' × ' || fmt_cant((v_elem->>'cantidad')::numeric) ELSE '' END ||
                 ' = <b>' ||
                 pesos(round((v_elem->>'valor_unitario')::numeric
                             * (v_elem->>'cantidad')::numeric, 2)) || '</b>';
  END LOOP;

  v_resumen := v_resumen || E'\n\n' ||
               'Subtotal: <b>' || pesos(v_res_sub) || '</b>' ||
               CASE WHEN v_c_desc > 0
                    THEN E'\n' || 'Descuento ya aplicado: −' || pesos(v_c_desc) ELSE '' END ||
               CASE WHEN v_desc_ok
                    THEN E'\n' || '✓ Descuento nuevo: −' || pesos(v_desc_monto) ||
                         ' (' || esc(v_desc_motivo) || ')'
                    ELSE '' END ||
               E'\n' || '💰 <b>Total: ' || pesos(v_res_total) || '</b>' ||
               E'\n' || 'Aún no se cobra nada: al confirmar queda lista para el cobro.' ||
               CASE WHEN v_notas IS NOT NULL
                    THEN E'\n' || '📝 ' || esc(v_notas) ELSE '' END;

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, 'cargar_paquete_servicios',
          jsonb_build_object('cuenta_id', v_cuenta_id, 'items', v_items,
                             'descuento', CASE WHEN v_desc_ok
                                               THEN jsonb_build_object(
                                                      'valor', v_desc_monto,
                                                      'motivo', v_desc_motivo)
                                               ELSE NULL END,
                             'notas', v_notas),
          v_resumen)
  RETURNING id INTO v_accion;

  RETURN jsonb_build_object('ok', true, 'requiere_confirmacion', true,
    'accion_id', v_accion, 'critica', true, 'resumen', v_resumen);
END;
$$;

-- ---------------------------------------------------------------------
-- 4. La ejecución del paquete: confirmó la persona, se escribe.
--
-- Atómica de verdad: si un servicio o el descuento no se pueden escribir,
-- se aborta todo (una sola transacción). Cada pieza rehusa la función ya
-- probada del menú, con su auditoría y su append-only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_paquete_ejecutar(p_usuario_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_cuenta  uuid := (p_args->>'cuenta_id')::uuid;
  v_items   jsonb := p_args->'items';
  v_estado  text;
  v_elem    jsonb;
  v_r       jsonb;
  v_lineas  int := 0;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'cobro.linea');

  IF v_cuenta IS NULL OR v_items IS NULL OR jsonb_typeof(v_items) <> 'array'
     OR jsonb_array_length(v_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
      'La propuesta no trae una cuenta o una lista de servicios válida. Vuelve a pedirlo.');
  END IF;

  SELECT estado INTO v_estado FROM cuenta WHERE id = v_cuenta FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa cuenta ya no existe.');
  END IF;
  IF v_estado <> 'abierta' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
      format('La cuenta está %s y ya no admite servicios.', v_estado));
  END IF;

  BEGIN
    FOR v_elem IN SELECT * FROM jsonb_array_elements(v_items) LOOP
      IF jsonb_typeof(v_elem) <> 'object' THEN
        RAISE EXCEPTION 'La propuesta trae un servicio sin datos.'
          USING ERRCODE = '23514';
      END IF;

      v_r := agregar_linea_servicio(
               p_usuario_id, v_cuenta,
               NULLIF(v_elem->>'tarifa_id', '')::uuid,
               (v_elem->>'valor_unitario')::numeric,
               (v_elem->>'cantidad')::numeric,
               v_elem->>'descripcion',
               'telegram');
      IF NOT (v_r->>'ok')::boolean THEN
        RAISE EXCEPTION '%', COALESCE(v_r->>'mensaje', 'No se pudo agregar el servicio.')
          USING ERRCODE = '23514';
      END IF;
      v_lineas := v_lineas + 1;
    END LOOP;

    IF (p_args->'descuento') IS NOT NULL
       AND COALESCE((p_args->'descuento'->>'valor')::numeric, 0) > 0 THEN
      v_r := aplicar_descuento(p_usuario_id, v_cuenta,
               (p_args->'descuento'->>'valor')::numeric,
               p_args->'descuento'->>'motivo', 'telegram');
      IF NOT (v_r->>'ok')::boolean THEN
        RAISE EXCEPTION '%', COALESCE(v_r->>'mensaje', 'No se pudo aplicar el descuento.')
          USING ERRCODE = '23514';
      END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'lineas', v_lineas,
                              'cuenta', cuenta_json(v_cuenta));
  EXCEPTION
    WHEN insufficient_privilege THEN
      RETURN jsonb_build_object('ok', false, 'mensaje', 'No tienes permiso para esa acción.');
    WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'mensaje', SQLERRM);
  END;
END;
$$;


-- ---------------------------------------------------------------------
-- 5. El borrador del descuento asistido: pre-factura de una cuenta hecha
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_aplicar_descuento_borrador(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_cuenta_id  uuid := NULLIF(p_args->>'cuenta_id', '')::uuid;
  v_valor_txt  text := NULLIF(trim(COALESCE(p_args->>'valor', '')), '');
  v_motivo     text := NULLIF(trim(COALESCE(p_args->>'motivo', '')), '');
  c            cuenta;
  v_monto      numeric;
  v_base       numeric;
  v_paciente   text;
  v_esp        text;
  v_resumen    text;
  v_accion     uuid;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'cobro.descuento');

  IF v_cuenta_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta la cuenta. Usa cuentas_por_cobrar y pasa su cuenta_id.');
  END IF;

  SELECT * INTO c FROM cuenta WHERE id = v_cuenta_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Esa cuenta ya no existe.');
  END IF;
  IF c.estado <> 'abierta' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('La cuenta está %s.', c.estado));
  END IF;

  IF v_motivo IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Todo descuento necesita un motivo escrito.');
  END IF;

  v_base := c.subtotal - c.descuento;
  IF v_base <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Esa cuenta no tiene nada por descontar.');
  END IF;

  v_monto := ia_parse_descuento(v_valor_txt, v_base);
  IF v_monto IS NULL OR v_monto <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'El descuento debe ser un monto o un porcentaje, por ejemplo 10000 o 10%.');
  END IF;
  IF v_monto > v_base THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('El descuento no puede pasar de %s.', pesos(v_base)));
  END IF;

  SELECT p.nombre, p.especie INTO v_paciente, v_esp
    FROM paciente p WHERE p.id = c.paciente_id;
  v_esp := COALESCE(v_esp, 'otro');

  v_resumen := '🧾 <b>Pre-factura</b>' ||
               CASE WHEN v_paciente IS NOT NULL
                    THEN ' · ' || esc(emoji_especie(v_esp)) || ' ' || esc(v_paciente)
                    ELSE '' END ||
               E'\n\n' ||
               'Subtotal: <b>' || pesos(c.subtotal) || '</b>' ||
               CASE WHEN c.descuento > 0
                    THEN E'\n' || 'Descuento ya aplicado: −' || pesos(c.descuento) ELSE '' END ||
               E'\n' || '✓ Descuento nuevo: −' || pesos(v_monto) || ' (' || esc(v_motivo) || ')' ||
               E'\n' || '💰 <b>Total: ' || pesos(c.subtotal - c.descuento - v_monto) || '</b>' ||
               E'\n' || 'El descuento queda registrado con su motivo y quién lo autoriza.';

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, 'aplicar_descuento_asistido',
          jsonb_build_object('cuenta_id', v_cuenta_id,
                             'valor', v_monto, 'motivo', v_motivo),
          v_resumen)
  RETURNING id INTO v_accion;

  RETURN jsonb_build_object('ok', true, 'requiere_confirmacion', true,
    'accion_id', v_accion, 'critica', true, 'resumen', v_resumen);
END;
$$;

-- ---------------------------------------------------------------------
-- 6. La ejecución del descuento asistido
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_descuento_ejecutar(p_usuario_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'cobro.descuento');

  RETURN aplicar_descuento(p_usuario_id,
                           (p_args->>'cuenta_id')::uuid,
                           (p_args->>'valor')::numeric,
                           p_args->>'motivo',
                           'telegram');
END;
$$;


-- ---------------------------------------------------------------------
-- 7. Cobrar y cerrar la pre-factura en un toque (C6.9)
--
-- Rehusa las funciones del menú —registrar_pago + cerrar_cuenta— dentro
-- de la misma transacción atómica: o se paga todo y se cierra, o no queda
-- nada.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_cobrar_cerrar(
  p_actor_id uuid, p_cuenta_id uuid, p_canal text DEFAULT 'telegram')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_r jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'cobro.pago');

  BEGIN
    v_r := registrar_pago(p_actor_id, p_cuenta_id, 'efectivo', NULL, NULL, p_canal);
    IF NOT (v_r->>'ok')::boolean THEN
      RAISE EXCEPTION 'No se pudo cobrar: %', COALESCE(v_r->>'mensaje', 'cuenta inválida')
        USING ERRCODE = '23514';
    END IF;

    v_r := cerrar_cuenta(p_actor_id, p_cuenta_id, p_canal);
    IF NOT (v_r->>'ok')::boolean THEN
      RAISE EXCEPTION 'No se pudo cerrar la cuenta: %', COALESCE(v_r->>'mensaje', 'error interno')
        USING ERRCODE = '23514';
    END IF;

    RETURN jsonb_build_object('ok', true, 'cuenta', v_r->'cuenta');
  EXCEPTION
    WHEN insufficient_privilege THEN
      RETURN jsonb_build_object('ok', false, 'mensaje', 'No tienes permiso para esa acción.');
    WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'mensaje', SQLERRM);
  END;
END;
$$;

-- Confirmar la propuesta de pre-factura y, si salió bien, cobrar y cerrar
-- la cuenta. El botón «💳 Cobrar y cerrar» no toca nada por sí mismo: es
-- un ia_confirmar que además cierra la caja de la atención.
CREATE OR REPLACE FUNCTION ia_confirmar_cobrar(p_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  a ia_accion_pendiente%ROWTYPE;
  v jsonb;
BEGIN
  SELECT * INTO a FROM ia_accion_pendiente
   WHERE id = p_id AND estado = 'pendiente' FOR UPDATE;

  IF a.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa confirmación ya no está disponible.');
  END IF;
  IF a.usuario_id <> p_usuario_id THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa confirmación no es tuya.');
  END IF;
  IF a.expira_at < now() THEN
    UPDATE ia_accion_pendiente SET estado = 'expirada', resuelta_at = now() WHERE id = p_id;
    RETURN jsonb_build_object('ok', false, 'mensaje',
      'Pasaron más de 10 minutos y los datos pudieron cambiar. Pídemelo otra vez.');
  END IF;
  IF a.herramienta NOT IN ('cargar_paquete_servicios', 'aplicar_descuento_asistido') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa acción no se puede cobrar directamente.');
  END IF;
  IF NOT tiene_permiso(p_usuario_id, 'cobro.pago') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'No tienes permiso para cobrar.');
  END IF;

  BEGIN
    v := ia_escribir(a.usuario_id, a.sede_id, a.herramienta, a.argumentos);
  EXCEPTION
    WHEN insufficient_privilege THEN
      v := jsonb_build_object('ok', false, 'mensaje', 'No tienes permiso para esa acción.');
    WHEN others THEN
      v := jsonb_build_object('ok', false, 'mensaje', SQLERRM);
  END;

  IF (v->>'ok')::boolean THEN
    BEGIN
      v := ia_cobrar_cerrar(p_usuario_id, (a.argumentos->>'cuenta_id')::uuid, 'telegram');
    EXCEPTION
      WHEN insufficient_privilege THEN
        v := jsonb_build_object('ok', false, 'mensaje', 'No tienes permiso para cobrar.');
      WHEN others THEN
        v := jsonb_build_object('ok', false, 'mensaje', SQLERRM);
    END;
  END IF;

  UPDATE ia_accion_pendiente
     SET estado = 'confirmada', resultado = v, resuelta_at = now()
   WHERE id = p_id;

  PERFORM auditar('ia_accion_pendiente', p_id::text, 'confirmar_cobrar', p_usuario_id, 'telegram',
                  NULL, jsonb_build_object('herramienta', a.herramienta,
                                           'argumentos', a.argumentos,
                                           'ok', v->'ok'));

  RETURN v;
END;
$$;


-- ---------------------------------------------------------------------
-- 8. Enganches con el asistente
-- ---------------------------------------------------------------------

-- `cargar_paquete_servicios` y `aplicar_descuento_asistido` tienen su
-- propio engranaje (normalización + pre-factura), como el alta y el
-- despacho, así que escapan del camino genérico de escritura de ia_llamar.
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
  -- borrador de consulta F2, despacho múltiple F3, pre-factura F4):
  -- preparan su propuesta aquí y ya dejan `ia_accion_pendiente`.
  IF p_nombre IN ('preparar_alta_paciente', 'preparar_consulta_clinica',
                  'despachar_receta_multiple', 'cargar_paquete_servicios',
                  'aplicar_descuento_asistido') THEN
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

-- La confirmación ejecuta la misma transacción atómica de la pre-factura.
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

    ELSE
      RETURN jsonb_build_object('ok', false,
        'mensaje', format('La herramienta %s no existe.', p_nombre));
  END CASE;

  RETURN v;
END;
$$;

-- Resultado que ve la persona tras confirmar: la pre-factura ya escrita.
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
      ELSE NULL
    END);
$$;

-- Bienvenida: ejemplos para quien arma cuentas y descuenta con el asistente.
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

-- La tarjeta de confirmación de la pre-factura suma el botón «💳 Cobrar y
-- cerrar» cuando quien debe confirmar puede cobrar. Se arma en SQL con los
-- datos de la propuesta; el botón lo dispara la persona, no el modelo.
CREATE OR REPLACE FUNCTION bot_ia_tarjeta_confirmacion(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  a ia_accion_pendiente%ROWTYPE;
  v_botones jsonb;
BEGIN
  SELECT * INTO a FROM ia_accion_pendiente WHERE id = p_id;
  IF a.id IS NULL THEN
    RETURN jsonb_build_object('texto', 'Esa acción ya no está disponible.', 'botones', '[]'::jsonb);
  END IF;

  v_botones := jsonb_build_array(
    jsonb_build_array(
      jsonb_build_object('t', '✅ Sí, hazlo', 'd', 'ia:ok:' || a.id)));

  IF a.herramienta IN ('cargar_paquete_servicios', 'aplicar_descuento_asistido')
     AND tiene_permiso(a.usuario_id, 'cobro.pago') THEN
    v_botones := v_botones || jsonb_build_array(jsonb_build_array(
                   jsonb_build_object('t', '💳 Cobrar y cerrar', 'd', 'ia:cobrar:' || a.id)));
  END IF;

  v_botones := v_botones || jsonb_build_array(jsonb_build_array(
                 jsonb_build_object('t', '✖️ No', 'd', 'ia:no:' || a.id)));

  RETURN jsonb_build_object(
    'texto', a.resumen || E'\n\n' || '¿Lo hago?',
    'botones', v_botones);
END;
$$;

-- El callback agrega «ia:cobrar», que cierra la pre-factura de una vez.
CREATE OR REPLACE FUNCTION bot_ia_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_partes text[] := string_to_array(p_data, ':');
  v_r      jsonb;
  v_texto  text;
  v_txt    text;
  v_bot    jsonb;
BEGIN
  IF v_partes[1] <> 'ia' THEN RETURN NULL; END IF;

  -- Entrar al modo conversación. El estado es el que hace que el
  -- enrutador mande el texto suelto aquí y no al menú principal.
  IF p_data = 'ia:abrir' THEN
    IF NOT ia_disponible(p_usuario_id) THEN
      RETURN jsonb_build_object('alerta', 'No disponible', 'acciones', jsonb_build_array(
        accion_editar(p_chat_id, p_mensaje_id,
          '💬 Chasqui está apagado ahora mismo. Habla con el administrador.',
          jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))))));
    END IF;

    PERFORM estado_guardar(p_chat_id, 'ia', 'conversando', '{}'::jsonb, p_usuario_id, p_mensaje_id);

    RETURN jsonb_build_object('alerta', 'Cuéntame', 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, bot_ia_bienvenida(p_usuario_id),
        jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '🧹 Olvidar lo hablado', 'd', 'ia:limpiar'),
          jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
  END IF;

  IF p_data = 'ia:salir' THEN
    PERFORM estado_limpiar(p_chat_id);
    v_r := bot_menu_principal(p_usuario_id);
    RETURN jsonb_build_object('alerta', NULL, 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_r->>'texto', v_r->'botones')));
  END IF;

  IF p_data = 'ia:limpiar' THEN
    PERFORM ia_olvidar(p_chat_id);
    RETURN jsonb_build_object('alerta', 'Listo, empezamos de cero', 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, bot_ia_bienvenida(p_usuario_id),
        jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
  END IF;

  -- Confirmar / cancelar una propuesta.
  IF v_partes[2] IN ('ok', 'no') AND v_partes[3] IS NOT NULL THEN
    IF v_partes[2] = 'no' THEN
      PERFORM ia_cancelar(v_partes[3]::uuid, p_usuario_id);
      RETURN jsonb_build_object('alerta', 'Cancelado', 'acciones', jsonb_build_array(
        accion_editar(p_chat_id, p_mensaje_id,
          '✖️ Listo, no hice nada. Dime otra cosa.',
          jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
    END IF;

    v_r := ia_confirmar(v_partes[3]::uuid, p_usuario_id);

    SELECT herramienta INTO v_txt FROM ia_accion_pendiente WHERE id = v_partes[3]::uuid;

    v_texto := CASE WHEN COALESCE((v_r->>'ok')::boolean, false)
                    THEN '✅ Hecho.' ELSE '⚠️ No se pudo.' END
               || COALESCE(E'\n' || ia_texto_resultado(v_txt, v_r), '');

    v_bot := jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '💬 Seguir hablando', 'd', 'ia:abrir'),
               jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir')));

    -- Un borrador de consulta recién confirmado se sigue más útil en el
    -- flujo clínico (resumen y firma) que en la conversación.
    IF v_txt = 'preparar_consulta_clinica' AND COALESCE((v_r->>'ok')::boolean, false) THEN
      v_bot := jsonb_build_array(jsonb_build_array(
                 jsonb_build_object('t', '🩺 Seguir esta consulta', 'd', 'cli:consulta')))
               || v_bot;
    END IF;

    -- Queda en la memoria de la conversación para que el modelo sepa que
    -- eso ya pasó y no vuelva a proponerlo en el siguiente mensaje.
    PERFORM ia_registrar(p_chat_id, p_usuario_id, 'user',
      to_jsonb('[El usuario confirmó la acción y el sistema respondió: ' ||
               COALESCE(v_r::text, 'sin respuesta') || ']'));

    RETURN jsonb_build_object('alerta', NULL, 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_texto, v_bot)));
  END IF;

  -- «💳 Cobrar y cerrar» de la pre-factura: confirma la propuesta, registra
  -- el pago del saldo y cierra la cuenta en un solo toque (C6.9).
  IF v_partes[2] = 'cobrar' AND v_partes[3] IS NOT NULL THEN
    v_r := ia_confirmar_cobrar(v_partes[3]::uuid, p_usuario_id);

    IF COALESCE((v_r->>'ok')::boolean, false) THEN
      v_texto := '✅ <b>Cuenta cobrada y cerrada.</b>' || E'\n\n' ||
                 COALESCE(recibo_texto((v_r->'cuenta'->>'cuenta_id')::uuid), '');
    ELSE
      v_texto := '⚠️ No se pudo.' || COALESCE(E'\n' || esc(v_r->>'mensaje'), '');
    END IF;

    PERFORM ia_registrar(p_chat_id, p_usuario_id, 'user',
      to_jsonb('[El usuario cobró y cerró la pre-factura y el sistema respondió: ' ||
               COALESCE(v_r::text, 'sin respuesta') || ']'));

    RETURN jsonb_build_object('alerta', NULL, 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_texto,
        jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '💬 Seguir hablando', 'd', 'ia:abrir'),
          jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
  END IF;

  RETURN NULL;
END;
$$;

GRANT SELECT ON ia_herramienta TO chasquipet_app;