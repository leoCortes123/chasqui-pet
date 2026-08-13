-- =====================================================================
-- Chasqui Pet — 140_registro_operaciones.sql
-- Ámbito: NÚCLEO (convención de cabecera, Fase A7a).
--
-- Fase A5 del plan de consolidación: el ruteo del asistente pasa de ser
-- código a ser dato.
--
-- El problema: `ia_llamar`, `ia_leer` y `ia_escribir` ramificaban con un
-- CASE por nombre de herramienta, y cada fase del asistente reescribía
-- esas funciones ENTERAS para agregarle una rama (079, 081, 082 y 083
-- hicieron exactamente eso). Agregar una herramienta costaba tocar
-- cuatro funciones, y de ahí salió la dependencia de orden estricta
-- entre migraciones que la Fase A1 tuvo que desenredar.
--
-- La tabla `ia_herramienta` ya era declarativa para el nombre, el
-- permiso, `escribe`, `critica` y el esquema JSON. Lo único que seguía
-- en código era **qué función SQL atiende cada herramienta**. Eso es lo
-- que se muda aquí, a dos columnas:
--
--   · `funcion`          — la operación en sí. Firma uniforme
--                          op_x(p_actor uuid, p_sede uuid, p_args jsonb)
--                          → jsonb. Para una lectura es lo que se
--                          consulta; para una escritura es lo que se
--                          ejecuta DESPUÉS de que la persona confirma.
--   · `funcion_borrador` — solo las seis herramientas que normalizan
--                          lenguaje de mostrador a códigos del sistema
--                          (alta F1, consulta F2, despacho F3, paquete y
--                          descuento F4, aviso F5). Firma
--                          (p_usuario_id uuid, p_chat_id bigint,
--                           p_sede_id uuid, p_args jsonb) → jsonb, que
--                          es la que esas seis ya tenían. Su lógica NO
--                          se mecaniza: ese trabajo es legítimo, no
--                          repetición.
--
-- Y una tercera, `modulo`, que no la usa nadie todavía: es la
-- disciplina multi-negocio del plan. El día que haya que responder «qué
-- sabe hacer esta instalación», es una consulta y no leerse 25 archivos.
--
-- Sobre la inyección: `format('%I')` cita el identificador, y el nombre
-- sale de una tabla en la que solo escribe el administrador de la base.
-- No hay superficie nueva: quien pueda escribir en `ia_herramienta` ya
-- podía crear funciones.
--
-- Lo que NO cambia aquí: `ia_resumen_accion` y `ia_texto_resultado`
-- siguen ramificando. Son presentación —el texto de la tarjeta y el de
-- la respuesta—, no ruteo, y sacarlas del núcleo es la Fase A7b.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1. El registro
-- ---------------------------------------------------------------------
ALTER TABLE ia_herramienta ADD COLUMN IF NOT EXISTS funcion          text;
ALTER TABLE ia_herramienta ADD COLUMN IF NOT EXISTS funcion_borrador text;
ALTER TABLE ia_herramienta ADD COLUMN IF NOT EXISTS modulo           text;

COMMENT ON COLUMN ia_herramienta.funcion IS
  'Función que atiende la herramienta: op_x(uuid, uuid, jsonb) → jsonb. Lectura, o ejecución tras confirmar.';
COMMENT ON COLUMN ia_herramienta.funcion_borrador IS
  'Solo herramientas que normalizan lenguaje libre: prepara la propuesta. (uuid, bigint, uuid, jsonb) → jsonb.';
COMMENT ON COLUMN ia_herramienta.modulo IS
  'Módulo funcional al que pertenece la operación (turnos, inventario, clinico, cobro, compras, admin, avisos).';


-- ---------------------------------------------------------------------
-- 2. Las operaciones de lectura
--
-- Cada cuerpo sale, palabra por palabra, de la rama que tenía `ia_leer`.
-- El contrato de salida también: {ok, datos}. Ganancia lateral: cada una
-- pasa a ser una función con nombre, que se puede probar sola.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION op_ver_cola(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT jsonb_build_object(
           'en_espera', count(*),
           'turnos', COALESCE(jsonb_agg(jsonb_build_object(
             'turno_id', id, 'codigo', codigo, 'tipo', tipo,
             'minutos_esperando', minutos_esperando,
             'urgencia', prioridad > 0) ORDER BY prioridad DESC, numero_secuencial),
             '[]'::jsonb))
    INTO v
    FROM v_cola_actual WHERE sede_id = p_sede;
  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION op_resumen_dia(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'datos', COALESCE(dashboard(p_sede), 'null'::jsonb));
$$;

CREATE OR REPLACE FUNCTION op_informacion_clinica(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  v := jsonb_build_object(
    'clinica', config_txt('nombre_clinica', 'Chasqui Pet'),
    'sedes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'nombre', nombre, 'direccion', direccion, 'telefono', telefono))
                , '[]'::jsonb) FROM sede WHERE activa),
    'consultorios', (SELECT COALESCE(jsonb_agg(nombre ORDER BY orden), '[]'::jsonb)
                       FROM consultorio WHERE sede_id = p_sede AND activo),
    'tipos_de_servicio', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                            'codigo', codigo, 'nombre', nombre,
                            'prioridad_base', prioridad_base) ORDER BY orden), '[]'::jsonb)
                            FROM tipo_servicio WHERE activo),
    -- Solo la configuración pensada para que la vea gente, no las
    -- claves internas: `editable_ui` ya marca esa frontera.
    'parametros', (SELECT COALESCE(jsonb_object_agg(clave, valor), '{}'::jsonb)
                     FROM config WHERE editable_ui AND clave NOT LIKE 'ia_%'),
    'notas_del_negocio', NULLIF(config_txt('ia_sobre_el_negocio', ''), ''));
  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION op_buscar_medicamento(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'medicamento_id', m.medicamento_id,
           'nombre', m.nombre,
           'presentacion', m.presentacion,
           'disponible', m.disponible,
           'unidad', m.unidad_base,
           'bajo_minimo', m.bajo_minimo,
           'precio_venta', m.precio_venta,
           'lotes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'lote_id', l.lote_id, 'numero_lote', l.numero_lote,
                       'cantidad', l.cantidad_actual,
                       'vence', l.fecha_vencimiento,
                       'dias_para_vencer', l.dias_para_vencer,
                       'sugerido', l.es_sugerido)), '[]'::jsonb)
                       FROM lotes_fefo(m.medicamento_id, 5) l))), '[]'::jsonb)
    INTO v
    FROM buscar_medicamento(p_args->>'texto', 5) m;
  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION op_alertas_inventario(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'datos', COALESCE(alertas_inventario(), 'null'::jsonb));
$$;

CREATE OR REPLACE FUNCTION op_ver_caja(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'datos',
    COALESCE(resumen_caja_dia(p_sede, NULLIF(p_args->>'fecha', '')::date), 'null'::jsonb));
$$;

CREATE OR REPLACE FUNCTION op_cuentas_por_cobrar(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb) INTO v
    FROM cuentas_abiertas(p_sede, 20) c;
  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION op_ver_tarifas(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO v FROM tarifas_activas(40) t;
  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION op_buscar_paciente(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v
    FROM buscar_paciente(p_args->>'texto', 8) x;
  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION op_historia_paciente(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT jsonb_build_object(
           'paciente', paciente_json((p_args->>'paciente_id')::uuid),
           'consultas', COALESCE(jsonb_agg(to_jsonb(h)), '[]'::jsonb))
    INTO v
    FROM historia_paciente((p_args->>'paciente_id')::uuid,
                           COALESCE((p_args->>'limite')::int, 10)) h;
  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION op_buscar_dueno(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v
    FROM buscar_dueno(p_args->>'texto', 8) x;
  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION op_buscar_proveedor(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v jsonb;
BEGIN
  IF COALESCE(p_args->>'texto', '') = '' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v FROM proveedores_frecuentes(8) x;
  ELSE
    SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v
      FROM buscar_proveedor(p_args->>'texto', 8) x;
  END IF;
  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;

-- `enlace_portal` escribe un enlace de un solo uso, así que no es STABLE
-- aunque para el asistente sea una «lectura» (no necesita confirmación:
-- lo único que hace es darle al propio usuario su enlace).
CREATE OR REPLACE FUNCTION op_enlace_portal(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('ok', true, 'datos', COALESCE(crear_enlace_portal(p_actor), 'null'::jsonb));
$$;


-- ---------------------------------------------------------------------
-- 3. Las operaciones de escritura directa
--
-- Cuerpos sacados de las ramas de `ia_escribir`, sin cambiarles una
-- coma. Se ejecutan solo después de la confirmación humana: quien las
-- llama es `ia_escribir`, y a `ia_escribir` solo llega `ia_confirmar`.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION op_llamar_siguiente(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$ SELECT llamar_siguiente(p_actor); $$;

CREATE OR REPLACE FUNCTION op_crear_turno(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT crear_turno_manual(
           p_actor, p_sede,
           COALESCE(NULLIF(p_args->>'tipo', ''), 'general'),
           COALESCE((p_args->>'urgencia')::boolean, false),
           NULL, NULL, NULLIF(p_args->>'notas', ''));
$$;

CREATE OR REPLACE FUNCTION op_cambiar_estado_turno(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT CASE p_args->>'accion'
           WHEN 'presento'  THEN iniciar_atencion(p_actor, (p_args->>'turno_id')::uuid)
           WHEN 'ausente'   THEN marcar_ausente(p_actor, (p_args->>'turno_id')::uuid)
           WHEN 'finalizar' THEN finalizar_turno(p_actor, (p_args->>'turno_id')::uuid)
           WHEN 'reencolar' THEN reencolar_turno(p_actor, (p_args->>'turno_id')::uuid)
           ELSE jsonb_build_object('ok', false, 'mensaje', 'Esa acción sobre el turno no existe.')
         END;
$$;

CREATE OR REPLACE FUNCTION op_registrar_salida_medicamento(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT salida_medicamento(
           p_actor, (p_args->>'lote_id')::uuid, (p_args->>'cantidad')::numeric,
           NULLIF(p_args->>'motivo', ''));
$$;

CREATE OR REPLACE FUNCTION op_agregar_servicio_a_cuenta(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT agregar_linea_servicio(
           p_actor, (p_args->>'cuenta_id')::uuid,
           NULLIF(p_args->>'tarifa_id', '')::uuid,
           NULLIF(p_args->>'valor', '')::numeric,
           COALESCE((p_args->>'cantidad')::numeric, 1),
           NULLIF(p_args->>'descripcion', ''));
$$;

CREATE OR REPLACE FUNCTION op_cobrar_cuenta(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT registrar_pago(
           p_actor, (p_args->>'cuenta_id')::uuid, p_args->>'medio',
           NULLIF(p_args->>'valor', '')::numeric,
           NULLIF(p_args->>'referencia', ''));
$$;


-- ---------------------------------------------------------------------
-- 4. Los ejecutores de las seis herramientas con borrador propio
--
-- Envoltorios de una línea sobre las funciones que ya existían. No se
-- toca su lógica: solo se les da la firma uniforme para que el registro
-- las pueda invocar como a todas las demás.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION op_alta_paciente(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$ SELECT ia_alta_paciente_ejecutar(p_actor, p_args); $$;

CREATE OR REPLACE FUNCTION op_consulta_clinica(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$ SELECT ia_consulta_ejecutar(p_actor, p_args); $$;

CREATE OR REPLACE FUNCTION op_despacho_receta(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$ SELECT ia_despacho_ejecutar(p_actor, p_args); $$;

CREATE OR REPLACE FUNCTION op_paquete_servicios(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$ SELECT ia_paquete_ejecutar(p_actor, p_args); $$;

CREATE OR REPLACE FUNCTION op_descuento_asistido(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$ SELECT ia_descuento_ejecutar(p_actor, p_args); $$;

CREATE OR REPLACE FUNCTION op_aviso_dueno(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$ SELECT ia_aviso_dueno_ejecutar(p_actor, p_args); $$;


-- ---------------------------------------------------------------------
-- 5. El registro se llena
--
-- Idempotente: es un UPDATE por nombre. Una herramienta que no esté en
-- esta lista queda con `funcion` en NULL y la delata
-- `verificar_registro_operaciones()`.
-- ---------------------------------------------------------------------
UPDATE ia_herramienta h
   SET funcion = r.funcion, funcion_borrador = r.borrador, modulo = r.modulo
  FROM (VALUES
    -- lecturas
    ('ver_cola',                     'op_ver_cola',                     NULL, 'turnos'),
    ('resumen_dia',                  'op_resumen_dia',                  NULL, 'turnos'),
    ('informacion_clinica',          'op_informacion_clinica',          NULL, 'admin'),
    ('buscar_medicamento',           'op_buscar_medicamento',           NULL, 'inventario'),
    ('alertas_inventario',           'op_alertas_inventario',           NULL, 'inventario'),
    ('ver_caja',                     'op_ver_caja',                     NULL, 'cobro'),
    ('cuentas_por_cobrar',           'op_cuentas_por_cobrar',           NULL, 'cobro'),
    ('ver_tarifas',                  'op_ver_tarifas',                  NULL, 'cobro'),
    ('buscar_paciente',              'op_buscar_paciente',              NULL, 'clinico'),
    ('historia_paciente',            'op_historia_paciente',            NULL, 'clinico'),
    ('buscar_dueno',                 'op_buscar_dueno',                 NULL, 'clinico'),
    ('buscar_proveedor',             'op_buscar_proveedor',             NULL, 'compras'),
    ('enlace_portal',                'op_enlace_portal',                NULL, 'admin'),
    -- escrituras directas
    ('llamar_siguiente',             'op_llamar_siguiente',             NULL, 'turnos'),
    ('crear_turno',                  'op_crear_turno',                  NULL, 'turnos'),
    ('cambiar_estado_turno',         'op_cambiar_estado_turno',         NULL, 'turnos'),
    ('registrar_salida_medicamento', 'op_registrar_salida_medicamento', NULL, 'inventario'),
    ('agregar_servicio_a_cuenta',    'op_agregar_servicio_a_cuenta',    NULL, 'cobro'),
    ('cobrar_cuenta',                'op_cobrar_cuenta',                NULL, 'cobro'),
    -- escrituras con borrador propio
    ('preparar_alta_paciente',       'op_alta_paciente',       'ia_alta_paciente_borrador',     'clinico'),
    ('preparar_consulta_clinica',    'op_consulta_clinica',    'ia_consulta_borrador',          'clinico'),
    ('despachar_receta_multiple',    'op_despacho_receta',     'ia_despacho_borrador',          'inventario'),
    ('cargar_paquete_servicios',     'op_paquete_servicios',   'ia_cargar_paquete_borrador',    'cobro'),
    ('aplicar_descuento_asistido',   'op_descuento_asistido',  'ia_aplicar_descuento_borrador', 'cobro'),
    ('preparar_aviso_dueno',         'op_aviso_dueno',         'ia_aviso_dueno_borrador',       'avisos')
  ) AS r(nombre, funcion, borrador, modulo)
 WHERE h.nombre = r.nombre;


-- ---------------------------------------------------------------------
-- 6. verificar_registro_operaciones — lo que compensa haber perdido el
--    CASE.
--
-- Con el CASE, una herramienta mal enchufada se veía leyendo el código.
-- Ahora se ve corriendo esto, que es lo que hacen las pruebas de la
-- Fase A4: comprueba que cada herramienta activa tenga función, que la
-- función exista, que tenga EXACTAMENTE la firma esperada y que devuelva
-- jsonb. Devuelve {ok, hallazgos:[…]} y no lanza: sirve igual para un
-- diagnóstico manual que para una prueba.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION verificar_registro_operaciones()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH hallazgos AS (
    -- Sin función registrada.
    SELECT h.nombre, 'sin_funcion' AS problema, NULL::text AS detalle
      FROM ia_herramienta h
     WHERE h.activa AND h.funcion IS NULL

    UNION ALL
    -- La función registrada no existe con la firma uniforme.
    SELECT h.nombre, 'funcion_inexistente', h.funcion
      FROM ia_herramienta h
     WHERE h.activa AND h.funcion IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM pg_proc p
          WHERE p.proname = h.funcion
            AND oidvectortypes(p.proargtypes) = 'uuid, uuid, jsonb'
            AND p.prorettype = 'jsonb'::regtype)

    UNION ALL
    -- El preparador registrado no existe con su firma.
    SELECT h.nombre, 'borrador_inexistente', h.funcion_borrador
      FROM ia_herramienta h
     WHERE h.activa AND h.funcion_borrador IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM pg_proc p
          WHERE p.proname = h.funcion_borrador
            AND oidvectortypes(p.proargtypes) = 'uuid, bigint, uuid, jsonb'
            AND p.prorettype = 'jsonb'::regtype)

    UNION ALL
    -- Un preparador en una herramienta que no escribe no tiene sentido:
    -- prepararía una propuesta que nadie va a confirmar.
    SELECT h.nombre, 'borrador_en_lectura', h.funcion_borrador
      FROM ia_herramienta h
     WHERE h.activa AND NOT h.escribe AND h.funcion_borrador IS NOT NULL

    UNION ALL
    -- Sin módulo: no rompe nada hoy, pero es la disciplina del plan.
    SELECT h.nombre, 'sin_modulo', NULL
      FROM ia_herramienta h
     WHERE h.activa AND h.modulo IS NULL
  )
  SELECT jsonb_build_object(
           'ok', NOT EXISTS (SELECT 1 FROM hallazgos),
           'herramientas', (SELECT count(*) FROM ia_herramienta WHERE activa),
           'hallazgos', COALESCE((SELECT jsonb_agg(jsonb_build_object(
              'herramienta', nombre, 'problema', problema, 'detalle', detalle)
              ORDER BY nombre) FROM hallazgos), '[]'::jsonb));
$$;


-- ---------------------------------------------------------------------
-- 7. Los dos despachadores, ya sin ramas
--
-- `ia_llamar` conserva exactamente el orden de decisiones que tenía:
-- herramienta activa → permiso → preparador propio → lectura → propuesta.
-- Lo único que se fue es el CASE: ahora el destino sale de la fila.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_llamar(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  h         ia_herramienta%ROWTYPE;
  v_id      uuid;
  v_resumen text;
  v_args    jsonb := COALESCE(p_args, '{}'::jsonb);
  v         jsonb;
BEGIN
  SELECT * INTO h FROM ia_herramienta WHERE nombre = p_nombre AND activa;

  IF h.nombre IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', format('No existe una herramienta llamada %s.', p_nombre));
  END IF;

  -- Segunda reja. La primera fue no ponerla en el catálogo; la tercera es
  -- el exigir_permiso de la propia función de negocio. Tres, porque una
  -- sola se puede olvidar al agregar la herramienta número quince.
  IF h.permiso IS NOT NULL AND NOT tiene_permiso(p_usuario_id, h.permiso) THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'El usuario no tiene permiso para esto. Díselo con naturalidad y ofrécele '
               'otra cosa; no lo intentes por otro camino.');
  END IF;

  IF h.funcion IS NULL THEN
    -- Herramienta a medio registrar: se dice, no se adivina.
    RETURN jsonb_build_object('ok', false,
      'error', format('La herramienta %s no tiene operación registrada.', p_nombre));
  END IF;

  -- Herramientas que normalizan lenguaje de mostrador: preparan su
  -- propuesta y ya dejan la fila en `ia_accion_pendiente`.
  IF h.funcion_borrador IS NOT NULL THEN
    EXECUTE format('SELECT public.%I($1, $2, $3, $4)', h.funcion_borrador)
       INTO v USING p_usuario_id, p_chat_id, p_sede_id, v_args;
    RETURN v;
  END IF;

  IF NOT h.escribe THEN
    BEGIN
      EXECUTE format('SELECT public.%I($1, $2, $3)', h.funcion)
         INTO v USING p_usuario_id, p_sede_id, v_args;
      RETURN v;
    EXCEPTION WHEN others THEN
      -- Un argumento mal formado (un UUID inventado, una fecha rara) no
      -- puede tumbar la tarea: se le devuelve al modelo como resultado
      -- para que corrija y vuelva a intentar.
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  -- Escritura: no se ejecuta, se propone.
  v_resumen := ia_resumen_accion(p_usuario_id, p_sede_id, p_nombre, v_args);

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, p_nombre, v_args, v_resumen)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'requiere_confirmacion', true,
    'accion_id', v_id,
    'critica', h.critica,
    'resumen', v_resumen);
END;
$$;

-- La confirmación ejecuta la misma transacción del portal y el menú.
CREATE OR REPLACE FUNCTION ia_escribir(
  p_usuario_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_funcion text;
  v jsonb;
BEGIN
  SELECT funcion INTO v_funcion FROM ia_herramienta WHERE nombre = p_nombre AND activa;

  IF v_funcion IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', format('La herramienta %s no existe.', p_nombre));
  END IF;

  EXECUTE format('SELECT public.%I($1, $2, $3)', v_funcion)
     INTO v USING p_usuario_id, p_sede_id, COALESCE(p_args, '{}'::jsonb);

  RETURN v;
END;
$$;

-- `ia_leer` deja de ser un despachador con su propio CASE y pasa a ser
-- lo que siempre fue de puertas afuera: «dame la lectura de esta
-- herramienta». Se conserva la firma porque es contrato público, pero el
-- ruteo es uno solo. Así no quedan dos copias de la misma decisión.
CREATE OR REPLACE FUNCTION ia_leer(
  p_usuario_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_funcion text;
  v jsonb;
BEGIN
  SELECT funcion INTO v_funcion
    FROM ia_herramienta WHERE nombre = p_nombre AND activa AND NOT escribe;

  IF v_funcion IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', format('La herramienta %s no existe.', p_nombre));
  END IF;

  EXECUTE format('SELECT public.%I($1, $2, $3)', v_funcion)
     INTO v USING p_usuario_id, p_sede_id, COALESCE(p_args, '{}'::jsonb);

  RETURN v;
END;
$$;
