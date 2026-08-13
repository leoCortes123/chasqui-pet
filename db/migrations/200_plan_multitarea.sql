-- =====================================================================
-- Chasqui Pet — 200_plan_multitarea.sql
-- Ámbito: NÚCLEO (convención de cabecera, Fase A7a).
--
-- Fase B4 del plan de consolidación: un mensaje largo del médico
-- («registra a Rocky, ábrele consulta, despacha la receta y agéndale
-- control en 10 días») deja de ser imposible.
--
-- Qué pasaba antes. `ia_llamar` (140:426) deja UNA propuesta en
-- `ia_accion_pendiente` y devuelve `requiere_confirmacion`; el worker
-- (`chasqui_responder.js`) abandonaba el turno del modelo en ese punto y
-- mostraba una sola tarjeta. Las demás llamadas del mismo lote ni
-- llegaban a la base (esa poda es la Fase A3). Resultado: la persona
-- tenía que repetir la petición, pedazo por pedazo, y volver a dictar
-- los datos que el sistema ya había producido.
--
-- Qué se agrega. Las N propuestas de un turno se cuelgan de un PLAN:
--
--   ia_plan                      cabecera: de quién, en qué chat, hasta
--                                cuándo, en qué estado va.
--   ia_accion_pendiente.plan_id  cada paso es una fila más de la misma
--   ia_accion_pendiente.orden    tabla de siempre. No hay una tabla
--                                paralela de pasos: la propuesta de un
--                                paso ES una propuesta, con su resumen,
--                                su expiración y su confirmación.
--
-- Tres decisiones que sostienen todo lo demás:
--
-- 1. ESTADO `planeada`. Un paso se anota con los argumentos crudos y un
--    título; NO se prepara todavía. Prepararlo antes de tiempo sería
--    mentir: el paso 2 necesita el `paciente_id` que produce el paso 1,
--    y las cifras del paso 3 (existencias, saldo) cambian mientras la
--    persona confirma los anteriores. Cada paso se MATERIALIZA —se
--    resuelven sus referencias, se corre su borrador, se calcula su
--    resumen, arranca su ventana de 10 minutos— justo cuando le llega el
--    turno. Es lo que hace que la tarjeta de un paso crítico diga cifras
--    verdaderas y no las de hace cinco minutos.
--
-- 2. REFERENCIAS `@pasoN.campo`. El modelo no puede inventar el UUID de
--    algo que todavía no existe, así que escribe `"@paso1.paciente_id"`
--    y `ia_plan_resolver` lo sustituye por el valor real del resultado
--    del paso 1. Buscar la clave en cualquier nivel del resultado
--    (`jsonb_buscar_clave`) es a propósito: el modelo nombra el DATO que
--    quiere, no la ruta donde quedó guardado. Esa ruta es asunto nuestro
--    y cambia entre funciones (`paciente.paciente_id`, `cita.cita_id`).
--
-- 3. CONFIRMACIÓN MIXTA. La columna `critica` de `ia_herramienta` ya
--    dice qué toca plata o existencias. Los pasos no críticos corridos
--    —el bloque clínico— se confirman con UN botón; cada paso crítico
--    tiene el suyo, con su tarjeta y sus cifras exactas. C6.9 se cumple
--    igual: nada se ejecuta sin que una persona toque un botón, y lo que
--    toca dinero o inventario se confirma de a uno.
--
-- El riesgo que la fase acepta de entrada: con confirmación humana
-- intercalada NO hay transacción todo-o-nada entre pasos. Un plan a
-- medias es un estado normal, no un error. Por eso cada paso es válido
-- por sí solo (una `consulta` en borrador y una `cuenta` abierta ya eran
-- estados legítimos), el plan se puede retomar y la tarjeta dice
-- siempre qué se hizo y qué no.
--
-- Lo que NO cambia: `ia_llamar`, `ia_confirmar`, `ia_confirmar_cobrar`,
-- `ia_escribir` y `bot_ia_tarjeta_confirmacion` quedan intactos y siguen
-- siendo el camino de un solo paso. Un plan de un paso se DESARMA al
-- cerrarse (el paso se suelta y el plan se borra), así que el caso
-- común —una sola escritura— recorre exactamente el mismo código que
-- antes de esta fase, con la misma tarjeta y los mismos callbacks.
-- =====================================================================

SET client_min_messages = warning;


-- ---------------------------------------------------------------------
-- 1. Parámetros
--
-- La vida del plan es más larga que la de una propuesta suelta (10 min)
-- porque un plan de cuatro pasos con confirmaciones intercaladas dura
-- lo que dure la consulta. Lo que no se estira es la ventana de cada
-- paso: esa arranca al materializarlo, y sigue siendo de 10 minutos.
-- ---------------------------------------------------------------------
INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('ia_plan_minutos', '60', 'entero',
   'Minutos que vive un plan multi-tarea del asistente antes de expirar', true),
  ('ia_plan_max_pasos', '6', 'entero',
   'Máximo de pasos que el asistente puede anotar en un mismo plan', true)
ON CONFLICT (clave) DO NOTHING;


-- ---------------------------------------------------------------------
-- 2. La cabecera del plan
--
-- Deliberadamente flaca: quién, dónde, hasta cuándo y en qué va. Todo
-- lo demás —qué se va a hacer, con qué argumentos, qué resultó— vive en
-- los pasos, que son filas de `ia_accion_pendiente`.
--
--   armando     el modelo todavía está anotando pasos en este turno.
--   en_curso    la persona ya tiene la tarjeta; faltan pasos por hacer.
--   completado  no queda ningún paso sin resolver.
--   cancelado   la persona canceló lo que faltaba.
--   expirado    se venció sin que nadie lo retomara.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ia_plan (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id     bigint NOT NULL,
  usuario_id  uuid NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
  sede_id     uuid REFERENCES sede(id),
  estado      text NOT NULL DEFAULT 'armando'
                CHECK (estado IN ('armando', 'en_curso', 'completado',
                                  'cancelado', 'expirado')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  expira_at   timestamptz NOT NULL DEFAULT now() + interval '60 minutes',
  resuelta_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_ia_plan_chat
  ON ia_plan (chat_id, created_at DESC) WHERE estado IN ('armando', 'en_curso');

COMMENT ON TABLE ia_plan IS
  'Cabecera de un plan multi-tarea del asistente (Fase B4). Los pasos son filas de ia_accion_pendiente con plan_id.';


-- ---------------------------------------------------------------------
-- 3. Los pasos: la misma tabla de propuestas, con dos columnas más
--
-- `planeada` es el estado nuevo: anotada pero sin preparar. `omitida`
-- es el paso que la persona saltó a propósito —que no es lo mismo que
-- cancelado, y la diferencia se ve en la tarjeta final—.
-- ---------------------------------------------------------------------
ALTER TABLE ia_accion_pendiente
  ADD COLUMN IF NOT EXISTS plan_id uuid REFERENCES ia_plan(id) ON DELETE CASCADE;
ALTER TABLE ia_accion_pendiente
  ADD COLUMN IF NOT EXISTS orden int;

COMMENT ON COLUMN ia_accion_pendiente.plan_id IS
  'Plan multi-tarea al que pertenece este paso, o NULL para una propuesta suelta (Fase B4).';
COMMENT ON COLUMN ia_accion_pendiente.orden IS
  'Posición del paso dentro del plan, desde 1. Es lo que referencian los «@pasoN.campo».';

-- El CHECK se rehace entero porque no hay forma de extender uno. Los
-- cuatro estados de 078 se conservan tal cual; se suman dos.
ALTER TABLE ia_accion_pendiente DROP CONSTRAINT IF EXISTS ia_accion_pendiente_estado_check;
ALTER TABLE ia_accion_pendiente ADD CONSTRAINT ia_accion_pendiente_estado_check
  CHECK (estado IN ('planeada', 'pendiente', 'confirmada', 'cancelada',
                    'expirada', 'omitida'));

-- Dos pasos no pueden ocupar la misma posición: `@paso2` tiene que
-- señalar a uno solo.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ia_paso_plan_orden
  ON ia_accion_pendiente (plan_id, orden) WHERE plan_id IS NOT NULL;


-- ---------------------------------------------------------------------
-- 4. Título corto de cada herramienta
--
-- Un paso anotado todavía no tiene resumen de verdad —no se ha
-- preparado—, pero la tarjeta del plan tiene que decir algo legible.
-- Se guarda como dato en el catálogo, no como CASE en una función: es
-- la misma disciplina de la Fase A5, y así una herramienta nueva trae
-- su título en la misma migración que la registra.
-- ---------------------------------------------------------------------
ALTER TABLE ia_herramienta ADD COLUMN IF NOT EXISTS titulo text;

COMMENT ON COLUMN ia_herramienta.titulo IS
  'Etiqueta corta para la lista de un plan multi-tarea, con emoji. Fase B4.';

UPDATE ia_herramienta h SET titulo = r.titulo
  FROM (VALUES
    ('llamar_siguiente',             '📣 Llamar el siguiente turno'),
    ('crear_turno',                  '🎫 Crear un turno'),
    ('cambiar_estado_turno',         '🔄 Cambiar el estado de un turno'),
    ('registrar_salida_medicamento', '💊 Sacar medicamento del inventario'),
    ('agregar_servicio_a_cuenta',    '🧾 Agregar un servicio a la cuenta'),
    ('cobrar_cuenta',                '💰 Registrar un pago'),
    ('preparar_alta_paciente',       '🐾 Registrar la mascota'),
    ('preparar_consulta_clinica',    '🩺 Dejar el borrador de la consulta'),
    ('despachar_receta_multiple',    '💊 Despachar la receta'),
    ('cargar_paquete_servicios',     '🧾 Cargar el paquete de servicios'),
    ('aplicar_descuento_asistido',   '🏷️ Aplicar el descuento'),
    ('preparar_aviso_dueno',         '📨 Avisarle al dueño'),
    ('agendar_cita',                 '📅 Agendar la cita'),
    ('registrar_remision',           '🏥 Registrar la remisión')
  ) AS r(nombre, titulo)
 WHERE h.nombre = r.nombre;

CREATE OR REPLACE FUNCTION ia_paso_titulo(p_nombre text)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT NULLIF(titulo, '') FROM ia_herramienta WHERE nombre = p_nombre),
    'Acción: ' || esc(p_nombre));
$$;


-- ---------------------------------------------------------------------
-- 5. Las referencias entre pasos
--
-- `jsonb_buscar_clave` devuelve el primer valor escalar con esa clave,
-- mirando primero el nivel actual y bajando después. Se busca por NOMBRE
-- del dato y no por ruta porque las funciones de negocio devuelven lo
-- suyo donde les corresponde —`{paciente:{paciente_id}}`,
-- `{cita:{cita_id}}`, `{consulta:{consulta_id}}`— y obligar al modelo a
-- conocer esas rutas sería pedirle que adivine nuestra estructura.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION jsonb_buscar_clave(p_dato jsonb, p_clave text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_val  text;
  v_k    text;
  v_hijo jsonb;
BEGIN
  IF p_dato IS NULL THEN RETURN NULL; END IF;

  IF jsonb_typeof(p_dato) = 'object' THEN
    -- El nivel actual primero: si el objeto trae la clave, esa gana.
    IF p_dato ? p_clave AND jsonb_typeof(p_dato -> p_clave) IN ('string', 'number') THEN
      RETURN p_dato ->> p_clave;
    END IF;
    FOR v_k IN SELECT jsonb_object_keys(p_dato) LOOP
      v_val := jsonb_buscar_clave(p_dato -> v_k, p_clave);
      IF v_val IS NOT NULL THEN RETURN v_val; END IF;
    END LOOP;

  ELSIF jsonb_typeof(p_dato) = 'array' THEN
    FOR v_hijo IN SELECT * FROM jsonb_array_elements(p_dato) LOOP
      v_val := jsonb_buscar_clave(v_hijo, p_clave);
      IF v_val IS NOT NULL THEN RETURN v_val; END IF;
    END LOOP;
  END IF;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION jsonb_buscar_clave(jsonb, text) IS
  'Primer valor escalar con esa clave en cualquier nivel del jsonb. Resuelve las referencias @pasoN.campo (Fase B4).';

-- Sustituye recursivamente toda cadena «@pasoN.campo» por el valor que
-- dejó ese paso. Lanza si la referencia no se puede resolver: un plan
-- que sigue con un dato inventado es peor que un plan que se detiene y
-- lo dice.
CREATE OR REPLACE FUNCTION ia_plan_resolver(p_plan_id uuid, p_dato jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_m     text[];
  v_orden int;
  v_clave text;
  v_res   jsonb;
  v_val   text;
  v_out   jsonb;
  v_k     text;
BEGIN
  IF p_dato IS NULL THEN RETURN NULL; END IF;

  IF jsonb_typeof(p_dato) = 'string' THEN
    v_m := regexp_match(p_dato #>> '{}', '^@paso([0-9]+)\.([a-zA-Z_]+)$');
    IF v_m IS NULL THEN RETURN p_dato; END IF;

    v_orden := v_m[1]::int;
    v_clave := v_m[2];

    SELECT resultado INTO v_res
      FROM ia_accion_pendiente
     WHERE plan_id = p_plan_id AND orden = v_orden AND estado = 'confirmada';

    IF v_res IS NULL THEN
      RAISE EXCEPTION 'El paso % no se hizo, así que no hay de dónde sacar el %.',
        v_orden, v_clave USING ERRCODE = 'data_exception';
    END IF;

    v_val := jsonb_buscar_clave(v_res, v_clave);
    IF v_val IS NULL THEN
      RAISE EXCEPTION 'El paso % no produjo ningún %.', v_orden, v_clave
        USING ERRCODE = 'data_exception';
    END IF;

    RETURN to_jsonb(v_val);

  ELSIF jsonb_typeof(p_dato) = 'object' THEN
    v_out := '{}'::jsonb;
    FOR v_k IN SELECT jsonb_object_keys(p_dato) LOOP
      v_out := v_out || jsonb_build_object(v_k, ia_plan_resolver(p_plan_id, p_dato -> v_k));
    END LOOP;
    RETURN v_out;

  ELSIF jsonb_typeof(p_dato) = 'array' THEN
    RETURN COALESCE((SELECT jsonb_agg(ia_plan_resolver(p_plan_id, e))
                       FROM jsonb_array_elements(p_dato) e), '[]'::jsonb);
  END IF;

  RETURN p_dato;
END;
$$;


-- ---------------------------------------------------------------------
-- 6. Anotar un paso
--
-- Las tres rejas de siempre en el mismo orden que `ia_llamar`:
-- herramienta activa → permiso → función registrada. Lo que cambia es
-- el final: en vez de preparar la propuesta, se anota.
--
-- El resumen provisional se intenta con `ia_resumen_accion` porque
-- cuando los argumentos ya están completos —el paso no depende de
-- ninguno anterior— da un texto mucho mejor que el título. Si los
-- argumentos traen referencias sin resolver ni se intenta: pediría a la
-- base un UUID que dice «@paso1.paciente_id».
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_plan_agregar(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid,
  p_plan_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  h         ia_herramienta%ROWTYPE;
  v_plan    uuid := p_plan_id;
  v_args    jsonb := COALESCE(p_args, '{}'::jsonb);
  v_orden   int;
  v_max     int := config_int('ia_plan_max_pasos', 6);
  v_resumen text;
  v_paso    uuid;
  v_m       jsonb;
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

  IF h.funcion IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', format('La herramienta %s no tiene operación registrada.', p_nombre));
  END IF;

  -- El plan nace con el primer paso: un turno que solo consulta no deja
  -- una cabecera vacía dando vueltas.
  IF v_plan IS NULL THEN
    INSERT INTO ia_plan (chat_id, usuario_id, sede_id, expira_at)
    VALUES (p_chat_id, p_usuario_id, p_sede_id,
            now() + make_interval(mins => config_int('ia_plan_minutos', 60)))
    RETURNING id INTO v_plan;
  ELSE
    -- Un plan ajeno o ya cerrado no admite pasos nuevos.
    PERFORM 1 FROM ia_plan
      WHERE id = v_plan AND usuario_id = p_usuario_id AND estado = 'armando';
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false,
        'error', 'Ese plan ya no está abierto. No agregues más pasos.');
    END IF;
  END IF;

  -- El modelo repite llamadas idénticas con más frecuencia de la que
  -- uno quisiera. Dos pasos iguales harían la misma escritura dos veces.
  SELECT id, orden INTO v_paso, v_orden
    FROM ia_accion_pendiente
   WHERE plan_id = v_plan AND herramienta = p_nombre AND argumentos = v_args
   LIMIT 1;
  IF v_paso IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'en_plan', true, 'plan_id', v_plan,
      'paso', v_orden, 'repetida', true,
      'mensaje', format('Ese paso ya estaba anotado como paso %s. No lo repitas.', v_orden));
  END IF;

  SELECT COALESCE(max(orden), 0) + 1 INTO v_orden
    FROM ia_accion_pendiente WHERE plan_id = v_plan;

  IF v_orden > v_max THEN
    RETURN jsonb_build_object('ok', false,
      'error', format('El plan ya tiene %s pasos, que es el máximo. Dile a la persona que '
                      'confirme lo anotado y seguimos con el resto después.', v_max));
  END IF;

  IF v_args::text LIKE '%"@paso%' THEN
    v_resumen := NULL;                      -- hay referencias sin resolver
  ELSE
    BEGIN
      v_resumen := ia_resumen_accion(p_usuario_id, p_sede_id, p_nombre, v_args);
    EXCEPTION WHEN others THEN
      v_resumen := NULL;                    -- argumentos aún incompletos
    END;
  END IF;

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta,
                                   argumentos, resumen, estado, plan_id, orden)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, p_nombre, v_args,
          COALESCE(NULLIF(v_resumen, ''), ia_paso_titulo(p_nombre)),
          'planeada', v_plan, v_orden)
  RETURNING id INTO v_paso;

  -- El PRIMER paso se prepara de una. Dos razones, y las dos importan:
  --
  --   · no puede depender de nadie (no hay paso anterior), así que
  --     prepararlo ahora no adelanta nada que vaya a cambiar;
  --   · si su validación falla —«falta el nombre de la mascota»—, el
  --     modelo se entera EN ESTE TURNO y se lo pregunta a la persona. Ese
  --     ida y vuelta es el que había antes de la fase con `ia_llamar`, y
  --     perderlo habría sido un retroceso: la persona se enteraría del
  --     dato que falta solo al final, cuando ya no hay a quién preguntarle.
  --
  -- Del segundo paso en adelante no se prepara nada: sus cifras y sus
  -- referencias solo son ciertas cuando les llegue el turno.
  IF v_orden = 1 THEN
    v_m := ia_plan_materializar(v_paso);
    IF NOT COALESCE((v_m->>'ok')::boolean, false) THEN
      DELETE FROM ia_accion_pendiente WHERE id = v_paso;
      DELETE FROM ia_plan WHERE id = v_plan
        AND NOT EXISTS (SELECT 1 FROM ia_accion_pendiente WHERE plan_id = v_plan);
      RETURN jsonb_build_object('ok', false,
        'error', COALESCE(v_m->>'mensaje', 'No se pudo preparar esa acción.'));
    END IF;
    v_paso := (v_m->>'accion_id')::uuid;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'en_plan', true, 'plan_id', v_plan, 'paso', v_orden,
    'mensaje', format(
      'Anotado como paso %s del plan. Todavía no se ejecuta nada: la persona lo confirma '
      'al final. Si la petición incluye más acciones, propónlas ahora; para usar un dato '
      'que produce este paso, escribe "@paso%s.<campo>".', v_orden, v_orden));
END;
$$;


-- ---------------------------------------------------------------------
-- 7. La puerta que usa el worker
--
-- Misma forma que `ia_llamar` y una decisión más: las lecturas siguen
-- por donde siempre (se ejecutan y devuelven el dato), las escrituras se
-- anotan en el plan en vez de proponerse de a una.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_llamar_plan(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid,
  p_nombre text, p_args jsonb, p_plan_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_escribe boolean;
BEGIN
  SELECT escribe INTO v_escribe FROM ia_herramienta WHERE nombre = p_nombre AND activa;

  IF v_escribe IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', format('No existe una herramienta llamada %s.', p_nombre));
  END IF;

  IF NOT v_escribe THEN
    RETURN ia_llamar(p_usuario_id, p_chat_id, p_sede_id, p_nombre, p_args);
  END IF;

  RETURN ia_plan_agregar(p_usuario_id, p_chat_id, p_sede_id, p_plan_id, p_nombre, p_args);
END;
$$;


-- ---------------------------------------------------------------------
-- 8. Materializar un paso
--
-- Aquí es donde un paso anotado se vuelve una propuesta de verdad:
-- referencias resueltas, borrador corrido, resumen calculado y ventana
-- de 10 minutos arrancando.
--
-- El caso del borrador merece explicación. Las seis herramientas que
-- normalizan lenguaje de mostrador (alta, consulta, despacho, paquete,
-- descuento, aviso; también agenda y remisión) insertan ELLAS su propia
-- fila en `ia_accion_pendiente` con los argumentos ya normalizados. No
-- se les cambia eso —es su contrato desde 078—: se borra la fila anotada
-- y la recién nacida ocupa su lugar en el plan, con el mismo `orden`.
-- Así las referencias «@pasoN» siguen apuntando a lo mismo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_plan_materializar(p_paso_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  a         ia_accion_pendiente%ROWTYPE;
  h         ia_herramienta%ROWTYPE;
  v_args    jsonb;
  v_r       jsonb;
  v_nueva   uuid;
  v_resumen text;
BEGIN
  SELECT * INTO a FROM ia_accion_pendiente WHERE id = p_paso_id FOR UPDATE;
  IF a.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese paso ya no existe.');
  END IF;

  -- Ya estaba preparado: no se vuelve a preparar. La ventana de sus 10
  -- minutos no se reinicia a propósito —si venció, `ia_confirmar` lo
  -- dirá, que es justo lo que la expiración pretende.
  IF a.estado = 'pendiente' THEN
    RETURN jsonb_build_object('ok', true, 'accion_id', a.id);
  END IF;

  IF a.estado <> 'planeada' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese paso ya se resolvió.');
  END IF;

  SELECT * INTO h FROM ia_herramienta WHERE nombre = a.herramienta AND activa;
  IF h.nombre IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'mensaje', format('La herramienta %s ya no está disponible.', a.herramienta));
  END IF;

  BEGIN
    v_args := ia_plan_resolver(a.plan_id, a.argumentos);
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'referencia_no_resuelta',
                              'mensaje', SQLERRM);
  END;

  IF h.funcion_borrador IS NOT NULL THEN
    BEGIN
      EXECUTE format('SELECT public.%I($1, $2, $3, $4)', h.funcion_borrador)
         INTO v_r USING a.usuario_id, a.chat_id, a.sede_id, v_args;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'mensaje', SQLERRM);
    END;

    IF NOT COALESCE((v_r->>'ok')::boolean, false)
       OR NULLIF(v_r->>'accion_id', '') IS NULL THEN
      RETURN jsonb_build_object('ok', false,
        'mensaje', COALESCE(v_r->>'error', v_r->>'mensaje',
                            'No se pudo preparar ese paso.'));
    END IF;

    v_nueva := (v_r->>'accion_id')::uuid;

    -- Primero se suelta el lugar y después se ocupa: el índice único
    -- (plan_id, orden) no admite dos filas en la misma posición.
    DELETE FROM ia_accion_pendiente WHERE id = p_paso_id;
    UPDATE ia_accion_pendiente
       SET plan_id = a.plan_id, orden = a.orden
     WHERE id = v_nueva;

    RETURN jsonb_build_object('ok', true, 'accion_id', v_nueva);
  END IF;

  -- Escritura directa: el resumen se calcula ahora, con los datos de
  -- este instante y las referencias ya resueltas.
  BEGIN
    v_resumen := ia_resumen_accion(a.usuario_id, a.sede_id, a.herramienta, v_args);
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', SQLERRM);
  END;

  UPDATE ia_accion_pendiente
     SET argumentos = v_args,
         resumen    = COALESCE(NULLIF(v_resumen, ''), a.resumen),
         estado     = 'pendiente',
         expira_at  = now() + interval '10 minutes'
   WHERE id = p_paso_id;

  RETURN jsonb_build_object('ok', true, 'accion_id', p_paso_id);
END;
$$;


-- ---------------------------------------------------------------------
-- 9. Dónde va el plan
-- ---------------------------------------------------------------------

-- El primer paso sin resolver, que es siempre el que toca ahora.
CREATE OR REPLACE FUNCTION ia_plan_paso_actual(p_plan_id uuid)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM ia_accion_pendiente
   WHERE plan_id = p_plan_id AND estado IN ('planeada', 'pendiente')
   ORDER BY orden LIMIT 1;
$$;

-- Cierra la cabecera cuando ya no queda nada por hacer. Se llama después
-- de cada avance: es el único lugar donde un plan pasa a 'completado'.
CREATE OR REPLACE FUNCTION ia_plan_actualizar_estado(p_plan_id uuid)
RETURNS void
LANGUAGE sql AS $$
  UPDATE ia_plan
     SET estado = 'completado', resuelta_at = now()
   WHERE id = p_plan_id
     AND estado IN ('armando', 'en_curso')
     AND ia_plan_paso_actual(p_plan_id) IS NULL;
$$;

-- La lista de pasos tal como se ve en la tarjeta. Del resumen se toma la
-- primera línea: los resúmenes de las propuestas traen varias, y aquí
-- hacen falta renglones, no fichas.
--
-- Un paso que no salió arrastra SU motivo. Es lo que hace utilizable el
-- «plan a medias» que la fase acepta de entrada: la persona ve en la
-- misma tarjeta qué se hizo, qué no y por qué, sin ir a buscarlo.
CREATE OR REPLACE FUNCTION ia_plan_lista(p_plan_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT string_agg(
           CASE
             WHEN p.estado = 'confirmada' AND COALESCE((p.resultado->>'ok')::boolean, false)
               THEN '✅ '
             WHEN p.estado = 'confirmada' THEN '⚠️ '
             WHEN p.estado = 'omitida'    THEN '⏭️ '
             WHEN p.estado IN ('cancelada', 'expirada') THEN '✖️ '
             WHEN p.id = ia_plan_paso_actual(p_plan_id) THEN '👉 '
             ELSE '· '
           END || p.orden::text || '. ' || split_part(p.resumen, E'\n', 1)
           || CASE
                WHEN p.estado IN ('cancelada', 'expirada', 'confirmada')
                     AND NOT COALESCE((p.resultado->>'ok')::boolean, false)
                     AND NULLIF(p.resultado->>'mensaje', '') IS NOT NULL
                  THEN E'\n' || '     ↳ <i>' || esc(p.resultado->>'mensaje') || '</i>'
                ELSE '' END,
           E'\n' ORDER BY p.orden)
    FROM ia_accion_pendiente p
   WHERE p.plan_id = p_plan_id;
$$;


-- ---------------------------------------------------------------------
-- 10. La tarjeta del plan
--
-- Dos formas, según qué toque ahora:
--
--   · el paso actual NO es crítico → tarjeta de plan, con la lista
--     completa y UN botón que confirma toda la corrida de pasos no
--     críticos que viene (se detiene antes del primer crítico).
--   · el paso actual SÍ es crítico → se materializa y se muestra SU
--     tarjeta, con las cifras exactas, encima de la lista del plan. Su
--     botón confirma ese paso y nada más.
--
-- Es la «confirmación mixta»: lo clínico de una, lo que toca plata o
-- existencias de a uno.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_ia_tarjeta_plan(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  pl        ia_plan%ROWTYPE;
  a         ia_accion_pendiente%ROWTYPE;
  v_paso    uuid;
  v_crit    boolean;
  v_m       jsonb;
  v_texto   text;
  v_botones jsonb;
  v_hasta   int;
  v_desde   int;
  v_total   int;
  v_hechos  int;
BEGIN
  SELECT * INTO pl FROM ia_plan WHERE id = p_plan_id;
  IF pl.id IS NULL THEN
    RETURN jsonb_build_object('texto', 'Ese plan ya no está disponible.',
                              'botones', jsonb_build_array(jsonb_build_array(
                                jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))));
  END IF;

  -- Vencido sin que nadie lo retomara: se cierra y se dice, no se ejecuta.
  IF pl.estado IN ('armando', 'en_curso') AND pl.expira_at < now() THEN
    UPDATE ia_plan SET estado = 'expirado', resuelta_at = now() WHERE id = p_plan_id;
    UPDATE ia_accion_pendiente SET estado = 'expirada', resuelta_at = now()
     WHERE plan_id = p_plan_id AND estado IN ('planeada', 'pendiente');
    pl.estado := 'expirado';
  END IF;

  v_paso := ia_plan_paso_actual(p_plan_id);

  SELECT count(*)::int,
         count(*) FILTER (WHERE estado = 'confirmada'
                            AND COALESCE((resultado->>'ok')::boolean, false))::int
    INTO v_total, v_hechos
    FROM ia_accion_pendiente WHERE plan_id = p_plan_id;

  -- --- Nada más que hacer: el cierre del plan --------------------------
  IF v_paso IS NULL THEN
    PERFORM ia_plan_actualizar_estado(p_plan_id);
    RETURN jsonb_build_object(
      'texto', CASE pl.estado
                 WHEN 'expirado'  THEN '⌛ <b>El plan se venció</b>'
                 WHEN 'cancelado' THEN '✖️ <b>Plan cancelado</b>'
                 ELSE format('🗂 <b>Plan terminado</b> · %s de %s pasos', v_hechos, v_total)
               END || E'\n\n' || COALESCE(ia_plan_lista(p_plan_id), ''),
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '💬 Seguir hablando', 'd', 'ia:abrir'),
        jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))));
  END IF;

  SELECT * INTO a FROM ia_accion_pendiente WHERE id = v_paso;
  SELECT COALESCE(critica, false) INTO v_crit
    FROM ia_herramienta WHERE nombre = a.herramienta;

  -- --- Paso crítico: su propia tarjeta, con cifras -----------------------
  IF v_crit THEN
    v_m := ia_plan_materializar(v_paso);
    IF NOT COALESCE((v_m->>'ok')::boolean, false) THEN
      -- No se pudo preparar (una referencia rota, un lote que ya no está):
      -- el paso se cancela y el plan sigue en el siguiente.
      UPDATE ia_accion_pendiente
         SET estado = 'cancelada', resuelta_at = now(),
             resultado = jsonb_build_object('ok', false, 'mensaje', v_m->>'mensaje')
       WHERE id = v_paso;
      RETURN bot_ia_tarjeta_plan(p_plan_id);
    END IF;

    SELECT * INTO a FROM ia_accion_pendiente WHERE id = (v_m->>'accion_id')::uuid;

    v_botones := jsonb_build_array(jsonb_build_array(
                   jsonb_build_object('t', '✅ Sí, hazlo', 'd', 'ia:pok:' || a.id)));

    -- El mismo atajo de la pre-factura de la Fase 4 (082:880), ahora
    -- dentro del plan.
    IF a.herramienta IN ('cargar_paquete_servicios', 'aplicar_descuento_asistido')
       AND tiene_permiso(a.usuario_id, 'cobro.pago') THEN
      v_botones := v_botones || jsonb_build_array(jsonb_build_array(
                     jsonb_build_object('t', '💳 Cobrar y cerrar', 'd', 'ia:pcob:' || a.id)));
    END IF;

    v_botones := v_botones || jsonb_build_array(jsonb_build_array(
                   jsonb_build_object('t', '⏭️ Saltar este paso', 'd', 'ia:psalt:' || a.id),
                   jsonb_build_object('t', '✖️ Cancelar el plan', 'd', 'ia:pno:' || p_plan_id)));

    RETURN jsonb_build_object(
      'texto', format('🗂 <b>Plan · paso %s de %s</b>', a.orden, v_total) || E'\n' ||
               COALESCE(ia_plan_lista(p_plan_id), '') || E'\n\n' ||
               a.resumen || E'\n\n' || '¿Lo hago?',
      'botones', v_botones);
  END IF;

  -- --- Corrida de pasos no críticos: un solo botón -----------------------
  v_desde := a.orden;
  SELECT COALESCE(max(p.orden), v_desde) INTO v_hasta
    FROM ia_accion_pendiente p
    JOIN ia_herramienta h ON h.nombre = p.herramienta
   WHERE p.plan_id = p_plan_id
     AND p.estado IN ('planeada', 'pendiente')
     AND NOT COALESCE(h.critica, false)
     AND p.orden < COALESCE((SELECT min(p2.orden)
                               FROM ia_accion_pendiente p2
                               JOIN ia_herramienta h2 ON h2.nombre = p2.herramienta
                              WHERE p2.plan_id = p_plan_id
                                AND p2.estado IN ('planeada', 'pendiente')
                                AND COALESCE(h2.critica, false)
                                AND p2.orden > v_desde), 2147483647);

  RETURN jsonb_build_object(
    'texto', format('🗂 <b>Plan de %s pasos</b>', v_total) || E'\n' ||
             COALESCE(ia_plan_lista(p_plan_id), '') || E'\n\n' ||
             CASE WHEN v_hasta > v_desde
                  THEN format('Confirmas los pasos %s a %s de una vez. ', v_desde, v_hasta)
                  ELSE format('Confirmas el paso %s. ', v_desde) END ||
             'Lo que toca inventario o dinero te lo pregunto aparte, con las cifras.',
    'botones', jsonb_build_array(
      jsonb_build_array(jsonb_build_object(
        't', CASE WHEN v_hasta > v_desde
                  THEN format('✅ Hacer los pasos %s a %s', v_desde, v_hasta)
                  ELSE format('✅ Hacer el paso %s', v_desde) END,
        'd', 'ia:pblo:' || p_plan_id)),
      jsonb_build_array(jsonb_build_object(
        't', '✖️ Cancelar el plan', 'd', 'ia:pno:' || p_plan_id))));
END;
$$;


-- ---------------------------------------------------------------------
-- 11. Cerrar el armado
--
-- Lo llama el worker cuando el modelo terminó su turno.
--
--   0 pasos → no hubo escrituras; se borra la cabecera y el worker
--             manda la respuesta de texto de siempre.
--   1 paso  → NO hay plan que valga: el paso se materializa, se suelta
--             de la cabecera y se muestra la tarjeta de confirmación de
--             siempre. El caso común no cambia en nada.
--   N pasos → plan de verdad.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_plan_cerrar(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  pl      ia_plan%ROWTYPE;
  v_n     int;
  v_paso  uuid;
  v_m     jsonb;
BEGIN
  SELECT * INTO pl FROM ia_plan WHERE id = p_plan_id FOR UPDATE;
  IF pl.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_plan');
  END IF;

  SELECT count(*)::int INTO v_n FROM ia_accion_pendiente WHERE plan_id = p_plan_id;

  IF v_n = 0 THEN
    DELETE FROM ia_plan WHERE id = p_plan_id;
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_pasos');
  END IF;

  IF v_n = 1 THEN
    SELECT id INTO v_paso FROM ia_accion_pendiente WHERE plan_id = p_plan_id;
    v_m := ia_plan_materializar(v_paso);

    IF NOT COALESCE((v_m->>'ok')::boolean, false) THEN
      DELETE FROM ia_accion_pendiente WHERE plan_id = p_plan_id;
      DELETE FROM ia_plan WHERE id = p_plan_id;
      RETURN jsonb_build_object('ok', false, 'motivo', 'no_preparado',
                                'mensaje', v_m->>'mensaje');
    END IF;

    -- Se suelta de la cabecera: de aquí en adelante es una propuesta
    -- suelta y recorre el camino de 078 sin enterarse de que hubo plan.
    UPDATE ia_accion_pendiente SET plan_id = NULL, orden = NULL
     WHERE id = (v_m->>'accion_id')::uuid;
    DELETE FROM ia_plan WHERE id = p_plan_id;

    RETURN jsonb_build_object('ok', true, 'pasos', 1,
      'accion_id', v_m->>'accion_id',
      'tarjeta', bot_ia_tarjeta_confirmacion((v_m->>'accion_id')::uuid));
  END IF;

  UPDATE ia_plan SET estado = 'en_curso' WHERE id = p_plan_id AND estado = 'armando';

  PERFORM auditar('ia_plan', p_plan_id::text, 'proponer', pl.usuario_id, 'telegram', NULL,
                  jsonb_build_object('pasos', v_n,
                    'herramientas', (SELECT jsonb_agg(herramienta ORDER BY orden)
                                       FROM ia_accion_pendiente WHERE plan_id = p_plan_id)));

  RETURN jsonb_build_object('ok', true, 'pasos', v_n, 'plan_id', p_plan_id,
                            'tarjeta', bot_ia_tarjeta_plan(p_plan_id));
END;
$$;


-- ---------------------------------------------------------------------
-- 12. Avanzar el plan
--
-- `ia_plan_confirmar_bloque` corre los pasos no críticos que vienen,
-- uno tras otro, resolviendo las dependencias sobre la marcha. Se
-- detiene ante el primer paso crítico (ese tiene su propio botón) y
-- también ante el primer fallo: si el paso 1 no creó la mascota, abrirle
-- consulta no tiene sentido.
--
-- Cada paso se ejecuta por `ia_confirmar`, la misma puerta del camino
-- de un solo paso: mismos chequeos de dueño y expiración, misma
-- auditoría por acción. Aquí no se reimplementa nada de eso.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_plan_confirmar_bloque(p_plan_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  pl       ia_plan%ROWTYPE;
  v_paso   uuid;
  v_herr   text;
  v_crit   boolean;
  v_m      jsonb;
  v_r      jsonb;
  v_hechos int := 0;
  v_falla  text;
  i        int;
BEGIN
  SELECT * INTO pl FROM ia_plan WHERE id = p_plan_id FOR UPDATE;
  IF pl.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese plan ya no está disponible.');
  END IF;
  IF pl.usuario_id <> p_usuario_id THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese plan no es tuyo.');
  END IF;
  IF pl.estado NOT IN ('armando', 'en_curso') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese plan ya se cerró.');
  END IF;
  IF pl.expira_at < now() THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
      'El plan se venció y los datos pudieron cambiar. Pídemelo otra vez.');
  END IF;

  -- El tope es el mismo del catálogo: más vueltas que pasos posibles no
  -- hacen falta, y un bucle sin freno en una función de negocio no.
  FOR i IN 1..config_int('ia_plan_max_pasos', 6) LOOP
    v_paso := ia_plan_paso_actual(p_plan_id);
    EXIT WHEN v_paso IS NULL;

    SELECT herramienta INTO v_herr FROM ia_accion_pendiente WHERE id = v_paso;
    SELECT COALESCE(critica, false) INTO v_crit
      FROM ia_herramienta WHERE nombre = v_herr;
    EXIT WHEN COALESCE(v_crit, false);      -- los críticos, de a uno

    v_m := ia_plan_materializar(v_paso);
    IF NOT COALESCE((v_m->>'ok')::boolean, false) THEN
      UPDATE ia_accion_pendiente
         SET estado = 'cancelada', resuelta_at = now(),
             resultado = jsonb_build_object('ok', false, 'mensaje', v_m->>'mensaje')
       WHERE id = v_paso;
      v_falla := v_m->>'mensaje';
      EXIT;
    END IF;

    v_r := ia_confirmar((v_m->>'accion_id')::uuid, p_usuario_id);

    IF COALESCE((v_r->>'ok')::boolean, false) THEN
      v_hechos := v_hechos + 1;
    ELSE
      v_falla := v_r->>'mensaje';
      EXIT;                                  -- lo que sigue dependía de esto
    END IF;
  END LOOP;

  PERFORM ia_plan_actualizar_estado(p_plan_id);

  PERFORM auditar('ia_plan', p_plan_id::text, 'confirmar_bloque', p_usuario_id, 'telegram',
                  NULL, jsonb_build_object('pasos_hechos', v_hechos, 'falla', v_falla));

  RETURN jsonb_build_object('ok', v_falla IS NULL, 'pasos_hechos', v_hechos,
                            'mensaje', v_falla);
END;
$$;

-- Un paso crítico se confirma solo. `p_cobrar` es el atajo «💳 Cobrar y
-- cerrar» de la pre-factura, que ya existía suelto (082:572).
CREATE OR REPLACE FUNCTION ia_plan_confirmar_paso(
  p_paso_id uuid, p_usuario_id uuid, p_cobrar boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_plan uuid;
  v_r    jsonb;
BEGIN
  SELECT plan_id INTO v_plan FROM ia_accion_pendiente WHERE id = p_paso_id;
  IF v_plan IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese paso ya no pertenece a un plan.');
  END IF;

  v_r := CASE WHEN p_cobrar THEN ia_confirmar_cobrar(p_paso_id, p_usuario_id)
              ELSE ia_confirmar(p_paso_id, p_usuario_id) END;

  PERFORM ia_plan_actualizar_estado(v_plan);

  RETURN v_r || jsonb_build_object('plan_id', v_plan);
END;
$$;

-- Saltar no es cancelar: el plan sigue con lo que viene. Es el caso real
-- de «la receta se la doy después, pero el control sí agéndalo».
CREATE OR REPLACE FUNCTION ia_plan_saltar(p_paso_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_plan uuid;
BEGIN
  UPDATE ia_accion_pendiente
     SET estado = 'omitida', resuelta_at = now()
   WHERE id = p_paso_id AND usuario_id = p_usuario_id
     AND estado IN ('planeada', 'pendiente')
   RETURNING plan_id INTO v_plan;

  IF v_plan IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese paso ya no se puede saltar.');
  END IF;

  PERFORM ia_plan_actualizar_estado(v_plan);
  PERFORM auditar('ia_accion_pendiente', p_paso_id::text, 'omitir', p_usuario_id, 'telegram');

  RETURN jsonb_build_object('ok', true, 'plan_id', v_plan);
END;
$$;

-- Cancelar lo que falta. Lo ya ejecutado no se toca: no hay deshacer, y
-- pretenderlo sería peor (§ append-only). La tarjeta final lo dice.
CREATE OR REPLACE FUNCTION ia_plan_cancelar(p_plan_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  PERFORM 1 FROM ia_plan WHERE id = p_plan_id AND usuario_id = p_usuario_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese plan no es tuyo.');
  END IF;

  UPDATE ia_accion_pendiente
     SET estado = 'cancelada', resuelta_at = now()
   WHERE plan_id = p_plan_id AND estado IN ('planeada', 'pendiente');
  GET DIAGNOSTICS v_n = ROW_COUNT;

  UPDATE ia_plan SET estado = 'cancelado', resuelta_at = now()
   WHERE id = p_plan_id AND estado IN ('armando', 'en_curso');

  PERFORM auditar('ia_plan', p_plan_id::text, 'cancelar', p_usuario_id, 'telegram', NULL,
                  jsonb_build_object('pasos_cancelados', v_n));

  RETURN jsonb_build_object('ok', true, 'pasos_cancelados', v_n);
END;
$$;


-- ---------------------------------------------------------------------
-- 13. El lado del bot
--
-- Reemplazo ADITIVO de `bot_ia_callback` (082:912): el cuerpo de allá va
-- entero y palabra por palabra, y se le suman las cinco ramas del plan.
-- Se repite completo porque no hay otra forma de extender una función en
-- Postgres, y quien compare las dos versiones tiene que poder ver que no
-- se perdió nada.
--
-- Las ramas nuevas van ANTES de las de siempre porque `ia:pok:` también
-- empieza por `ia:` y las viejas comparan `v_partes[2]` contra 'ok',
-- 'no' y 'cobrar', que son valores distintos: no hay solapamiento, pero
-- el orden lo deja evidente.
-- ---------------------------------------------------------------------
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
  v_tar    jsonb;
  v_plan   uuid;
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

  -- === Plan multi-tarea (Fase B4) ======================================
  --
  -- Las cuatro ramas terminan igual: se avanza el plan y se vuelve a
  -- pintar su tarjeta, que ya sabe qué toca ahora —otro bloque, un paso
  -- crítico o el cierre—. Es lo que hace que el plan sea reanudable sin
  -- que la persona reescriba nada.

  -- Confirmar la corrida de pasos no críticos.
  IF v_partes[2] = 'pblo' AND v_partes[3] IS NOT NULL THEN
    v_r := ia_plan_confirmar_bloque(v_partes[3]::uuid, p_usuario_id);

    PERFORM ia_registrar(p_chat_id, p_usuario_id, 'user',
      to_jsonb('[El usuario confirmó un bloque del plan y el sistema respondió: ' ||
               COALESCE(v_r::text, 'sin respuesta') || ']'));

    v_tar := bot_ia_tarjeta_plan(v_partes[3]::uuid);
    RETURN jsonb_build_object(
      'alerta', CASE WHEN COALESCE((v_r->>'ok')::boolean, false)
                     THEN 'Listo' ELSE 'Se detuvo el plan' END,
      'acciones', jsonb_build_array(
        accion_editar(p_chat_id, p_mensaje_id, v_tar->>'texto', v_tar->'botones')));
  END IF;

  -- Confirmar un paso crítico, con o sin el atajo de cobrar y cerrar.
  IF v_partes[2] IN ('pok', 'pcob') AND v_partes[3] IS NOT NULL THEN
    v_r := ia_plan_confirmar_paso(v_partes[3]::uuid, p_usuario_id, v_partes[2] = 'pcob');
    v_plan := NULLIF(v_r->>'plan_id', '')::uuid;

    PERFORM ia_registrar(p_chat_id, p_usuario_id, 'user',
      to_jsonb('[El usuario confirmó un paso del plan y el sistema respondió: ' ||
               COALESCE(v_r::text, 'sin respuesta') || ']'));

    IF v_plan IS NULL THEN
      RETURN jsonb_build_object('alerta', 'No se pudo', 'acciones', jsonb_build_array(
        accion_editar(p_chat_id, p_mensaje_id,
          '⚠️ ' || COALESCE(esc(v_r->>'mensaje'), 'Ese paso ya no está disponible.'),
          jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
    END IF;

    v_tar := bot_ia_tarjeta_plan(v_plan);
    RETURN jsonb_build_object(
      'alerta', CASE WHEN COALESCE((v_r->>'ok')::boolean, false) THEN 'Hecho' ELSE 'No se pudo' END,
      'acciones', jsonb_build_array(
        accion_editar(p_chat_id, p_mensaje_id, v_tar->>'texto', v_tar->'botones')));
  END IF;

  -- Saltar un paso: el plan sigue con el siguiente.
  IF v_partes[2] = 'psalt' AND v_partes[3] IS NOT NULL THEN
    v_r := ia_plan_saltar(v_partes[3]::uuid, p_usuario_id);
    v_plan := NULLIF(v_r->>'plan_id', '')::uuid;

    IF v_plan IS NULL THEN
      RETURN jsonb_build_object('alerta', 'No se pudo', 'acciones', jsonb_build_array(
        accion_editar(p_chat_id, p_mensaje_id,
          '⚠️ ' || COALESCE(esc(v_r->>'mensaje'), 'Ese paso ya no está disponible.'),
          jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
    END IF;

    v_tar := bot_ia_tarjeta_plan(v_plan);
    RETURN jsonb_build_object('alerta', 'Saltado', 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_tar->>'texto', v_tar->'botones')));
  END IF;

  -- Cancelar lo que falta del plan.
  IF v_partes[2] = 'pno' AND v_partes[3] IS NOT NULL THEN
    v_r := ia_plan_cancelar(v_partes[3]::uuid, p_usuario_id);

    PERFORM ia_registrar(p_chat_id, p_usuario_id, 'user',
      to_jsonb('[El usuario canceló lo que faltaba del plan.]'));

    v_tar := bot_ia_tarjeta_plan(v_partes[3]::uuid);
    RETURN jsonb_build_object('alerta', 'Cancelado', 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_tar->>'texto', v_tar->'botones')));
  END IF;
  -- === Fin del plan multi-tarea ========================================

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
      to_jsonb('[El usuario confirmó y cobró la cuenta; el sistema respondió: ' ||
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


-- ---------------------------------------------------------------------
-- 14. La purga se entera de los planes
--
-- Reemplazo ADITIVO de `ia_purgar_pendientes` (130:54): los dos pasos de
-- allá quedan igual y se le suman los planes. Sin esto, un paso
-- `planeada` de un plan que nadie retomó no lo barría nadie: su
-- `expira_at` es el de la propuesta, pero el que manda es el del plan.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_purgar_pendientes()
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_expiradas int;
  v_purgadas  int;
  v_planes    int;
BEGIN
  -- Planes vencidos primero: al cerrarlos, sus pasos quedan listos para
  -- que el paso siguiente los marque expirados.
  UPDATE ia_plan SET estado = 'expirado', resuelta_at = now()
   WHERE estado IN ('armando', 'en_curso') AND expira_at < now();
  GET DIAGNOSTICS v_planes = ROW_COUNT;

  UPDATE ia_accion_pendiente
     SET estado = 'expirada', resuelta_at = now()
   WHERE estado IN ('pendiente', 'planeada')
     AND (expira_at < now()
          OR plan_id IN (SELECT id FROM ia_plan
                          WHERE estado IN ('expirado', 'cancelado')));
  GET DIAGNOSTICS v_expiradas = ROW_COUNT;

  DELETE FROM ia_accion_pendiente
   WHERE estado NOT IN ('pendiente', 'planeada')
     AND COALESCE(resuelta_at, created_at)
         < now() - make_interval(days => config_int('retencion_ia_acciones_dias', 30));
  GET DIAGNOSTICS v_purgadas = ROW_COUNT;

  -- Las cabeceras se van cuando ya no les queda ningún paso: los pasos
  -- son lo que se consulta, la cabecera sola no le sirve a nadie.
  DELETE FROM ia_plan p
   WHERE p.estado NOT IN ('armando', 'en_curso')
     AND NOT EXISTS (SELECT 1 FROM ia_accion_pendiente a WHERE a.plan_id = p.id)
     AND COALESCE(p.resuelta_at, p.created_at)
         < now() - make_interval(days => config_int('retencion_ia_acciones_dias', 30));

  RETURN jsonb_build_object('expiradas', v_expiradas, 'purgadas', v_purgadas,
                            'planes_expirados', v_planes);
END;
$$;


-- ---------------------------------------------------------------------
-- 15. Permisos
--
-- El plan no estrena permisos de negocio: cada paso sigue exigiendo el
-- suyo, tres veces, exactamente donde lo exigía antes (catálogo,
-- `ia_plan_agregar` y el `exigir_permiso` de la función de negocio).
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON ia_plan TO chasquipet_app;
GRANT SELECT ON ia_plan TO chasquipet_lectura;

GRANT EXECUTE ON FUNCTION ia_paso_titulo(text)                                  TO chasquipet_app;
GRANT EXECUTE ON FUNCTION jsonb_buscar_clave(jsonb, text)                       TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_resolver(uuid, jsonb)                         TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_agregar(uuid, bigint, uuid, uuid, text, jsonb) TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_llamar_plan(uuid, bigint, uuid, text, jsonb, uuid) TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_materializar(uuid)                            TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_paso_actual(uuid)                             TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_actualizar_estado(uuid)                       TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_lista(uuid)                                   TO chasquipet_app;
GRANT EXECUTE ON FUNCTION bot_ia_tarjeta_plan(uuid)                             TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_cerrar(uuid)                                  TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_confirmar_bloque(uuid, uuid)                  TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_confirmar_paso(uuid, uuid, boolean)           TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_saltar(uuid, uuid)                            TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_plan_cancelar(uuid, uuid)                          TO chasquipet_app;
