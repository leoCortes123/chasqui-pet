-- =====================================================================
-- Chasqui Pet — 079_chasqui_ia_consulta.sql
-- Fase 2: borrador de consulta clínica asistido por «Habla con Chasqui».
--
-- La consulta se captura con el animal en la mesa y una mano ocupada.
-- Dictarle al asistente («esta es Luna, vómito, 4.2 kg, gastroenteritis,
-- plan…») es más rápido que andar tocando botones, pero la regla clínica
-- es la misma de 056: mientras sea borrador no es historia clínica, y
-- sólo la firma del veterinario la cierra (`firmar_consulta`, 050:1207).
--
-- Por eso la herramienta tiene dos momentos:
--
--   1. `ia_consulta_borrador` — estructura lo dictado (valida el examen
--      físico y la fecha), arma la tarjeta con lo que va a quedar y deja
--      la propuesta en `ia_accion_pendiente`. No toca la tabla `consulta`.
--   2. `ia_consulta_ejecutar` — la dispara la persona con el botón. Abre
--      o reutiliza el borrador del paciente (050 `abrir_consulta`), aplica
--      los campos con `guardar_consulta_completa` —la misma validación
--      que usa el portal— y audita. La tarjeta resultante lleva el enlace
--      del portal (077 `portal_url`) para revisar y firmar, además del
--      camino de siempre por el chat (`cli:consulta`).
--
-- La inmutabilidad y la firma obligatoria no se reinventan aquí: viven en
-- `consulta.estado` ('borrador'→'firmada'→'anulada') y en el trigger
-- `consulta_no_editar_firmada` (050:247-278). El asistente puede dejar un
-- borrador, nunca cerrarlo.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1. La herramienta en el catálogo
-- ---------------------------------------------------------------------
INSERT INTO ia_herramienta (nombre, permiso, escribe, critica, orden, descripcion, esquema) VALUES
('preparar_consulta_clinica', 'consulta.crear', true, false, 270,
 'Prepara un borrador de consulta (historia clínica) para un paciente. Úsala cuando '
 'pidan abrir una consulta o que quede escrita la que están atendiendo, a partir de lo '
 'que se dicta en el mostrador: motivo, anamnesis, examen físico (peso, temperatura, '
 'FC, FR, TLLC, mucosas, hidratación, condición corporal, hallazgos), diagnóstico(s), '
 'plan de tratamiento, recomendaciones, remisión y próxima revisión. Necesita el '
 'paciente_id, que sale de buscar_paciente. El borrador se revisa y se firma después; '
 'esta herramienta nunca lo cierra ni lo firma.',
 '{"type":"object","properties":{
    "paciente_id":{"type":"string","description":"UUID del paciente, que sale de buscar_paciente"},
    "motivo_consulta":{"type":"string","description":"Por qué lo traen"},
    "anamnesis":{"type":"string","description":"Qué cuenta el dueño. Opcional"},
    "peso_kg":{"type":"number","description":"Peso en kg (0.05 a 200)"},
    "temperatura_c":{"type":"number","description":"Temperatura en °C (20 a 45)"},
    "fc":{"type":"number","description":"Frecuencia cardiaca (10 a 400)"},
    "fr":{"type":"number","description":"Frecuencia respiratoria (1 a 200)"},
    "tllc_seg":{"type":"number","description":"TLLC en segundos (0.1 a 15)"},
    "mucosas":{"type":"string","enum":["rosadas","palidas","ictericas","cianoticas","congestivas"]},
    "hidratacion":{"type":"string","enum":["normal","leve","moderada","severa"]},
    "cc":{"type":"string","enum":["caquectico","delgado","ideal","sobrepeso","obeso"]},
    "hallazgos":{"type":"string","description":"Hallazgos del examen físico, en texto"},
    "diagnostico_presuntivo":{"type":"string"},
    "diagnostico_definitivo":{"type":"string"},
    "plan_tratamiento":{"type":"string"},
    "recomendaciones":{"type":"string"},
    "remision_externa":{"type":"string"},
    "proxima_revision":{"type":"string","description":"Próxima revisión en formato AAAA-MM-DD, si se sabe"}},
  "required":["paciente_id"]}'::jsonb)
ON CONFLICT (nombre) DO UPDATE
  SET permiso = EXCLUDED.permiso, escribe = EXCLUDED.escribe, critica = EXCLUDED.critica,
      descripcion = EXCLUDED.descripcion, esquema = EXCLUDED.esquema, orden = EXCLUDED.orden;


-- ---------------------------------------------------------------------
-- 2. Validación previa del examen físico
--
-- La tarjeta de confirmación no debe proponer algo que el guardado real
-- rechazaría (050 guardar_examen:1086). El examen llega como un jsonb de
-- claves conocidas; se rechazan las desconocidas y los valores fuera de
-- los mismos rangos de cordura que usa `guardar_examen`. La que sigue
-- siendo autoridad es `guardar_examen`: esto sólo adelanta el rechazo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_validar_examen_jsonb(p_examen jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_clave text;
  v_valor text;
  v_num   numeric;
BEGIN
  IF p_examen IS NULL OR jsonb_typeof(p_examen) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'El examen físico no es un objeto válido.');
  END IF;

  FOR v_clave, v_valor IN SELECT * FROM jsonb_each_text(p_examen) LOOP
    IF v_clave NOT IN ('peso_kg','temperatura_c','fc','fr','tllc_seg',
                       'mucosas','hidratacion','cc','hallazgos') THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('«%s» no es un campo de examen físico válido.', v_clave));
    END IF;

    IF v_clave IN ('mucosas','hidratacion','cc') THEN
      IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(opciones_examen(v_clave)) o
                      WHERE o->>'v' = v_valor) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          format('«%s» no es una opción válida de %s.', v_valor, v_clave));
      END IF;
    ELSIF v_clave = 'hallazgos' THEN
      CONTINUE;  -- texto libre
    ELSE
      BEGIN
        v_num := replace(v_valor, ',', '.')::numeric;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error',
          format('«%s» no es un número para %s.', v_valor, v_clave));
      END;

      IF (v_clave = 'peso_kg'       AND (v_num < 0.05  OR v_num > 200))
      OR (v_clave = 'temperatura_c' AND (v_num < 20    OR v_num > 45))
      OR (v_clave = 'fc'            AND (v_num < 10    OR v_num > 400))
      OR (v_clave = 'fr'            AND (v_num < 1     OR v_num > 200))
      OR (v_clave = 'tllc_seg'      AND (v_num < 0.1   OR v_num > 15)) THEN
        RETURN jsonb_build_object('ok', false, 'error',
          format('%s fuera de rango (%s).', v_clave, v_valor));
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true);
END;
$$;


-- ---------------------------------------------------------------------
-- 3. El borrador: estructura lo dictado y deja la propuesta
--
-- Lo que el modelo manda es lengua de mostrador. Aquí se aterriza a los
-- campos de la consulta (050:178-214), se valida el examen y la fecha y
-- se arma la tarjeta. La confirmación no vuelve a pasar por aquí.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_consulta_borrador(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_paciente_id uuid := NULLIF(p_args->>'paciente_id', '')::uuid;
  v_pac        jsonb;
  v_motivo     text;
  v_anamnesis  text;
  v_diag_pres  text;
  v_diag_def   text;
  v_plan       text;
  v_recom      text;
  v_remision   text;
  v_prox_txt   text;
  v_proxima    date;
  v_examen     jsonb;
  v_k          text;
  v_v          text;
  v_r          jsonb;
  v_ac         uuid;
  v_resumen    text;
  v_argumentos jsonb;
  v_faltan     text[] := ARRAY[]::text[];
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'consulta.crear');

  IF v_paciente_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta el paciente. Búscalo antes con buscar_paciente y pasa su paciente_id.');
  END IF;

  SELECT paciente_json(v_paciente_id) INTO v_pac;
  IF v_pac IS NULL OR v_pac->>'estado' <> 'activo' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Ese paciente ya no existe o no está activo.');
  END IF;

  v_motivo    := NULLIF(trim(COALESCE(p_args->>'motivo_consulta', '')), '');
  v_anamnesis := NULLIF(trim(COALESCE(p_args->>'anamnesis', '')), '');
  v_diag_pres := NULLIF(trim(COALESCE(p_args->>'diagnostico_presuntivo', '')), '');
  v_diag_def  := NULLIF(trim(COALESCE(p_args->>'diagnostico_definitivo', '')), '');
  v_plan      := NULLIF(trim(COALESCE(p_args->>'plan_tratamiento', '')), '');
  v_recom     := NULLIF(trim(COALESCE(p_args->>'recomendaciones', '')), '');
  v_remision  := NULLIF(trim(COALESCE(p_args->>'remision_externa', '')), '');

  -- Examen físico: el modelo puede mandarlo como objeto (`examen_fisico`)
  -- o como medidas sueltas (`peso_kg`, `temperatura_c`…). Se juntan, y
  -- las sueltas mandan si las repite dentro del objeto.
  v_examen := COALESCE(p_args->'examen_fisico', '{}'::jsonb);
  IF jsonb_typeof(v_examen) <> 'object' THEN v_examen := '{}'::jsonb; END IF;

  FOR v_k, v_v IN
    SELECT * FROM jsonb_each_text(jsonb_build_object(
      'peso_kg', p_args->>'peso_kg', 'temperatura_c', p_args->>'temperatura_c',
      'fc', p_args->>'fc', 'fr', p_args->>'fr', 'tllc_seg', p_args->>'tllc_seg',
      'mucosas', p_args->>'mucosas', 'hidratacion', p_args->>'hidratacion',
      'cc', p_args->>'cc', 'hallazgos', p_args->>'hallazgos'))
  LOOP
    IF v_v IS NOT NULL THEN
      v_examen := v_examen || jsonb_build_object(v_k, v_v);
    END IF;
  END LOOP;

  IF v_examen <> '{}'::jsonb THEN
    v_r := ia_validar_examen_jsonb(v_examen);
    IF NOT (v_r->>'ok')::boolean THEN RETURN v_r; END IF;
  END IF;

  -- Próxima revisión: una fecha que no se entiende no llega a la base
  -- (050 guardar_consulta:1069 la rechazaría al confirmar).
  v_prox_txt := NULLIF(trim(COALESCE(p_args->>'proxima_revision', '')), '');
  IF v_prox_txt IS NOT NULL THEN
    v_proxima := parse_fecha(v_prox_txt);
    IF v_proxima IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('«%s» no es una fecha válida para la próxima revisión.', v_prox_txt));
    END IF;
  END IF;

  -- Confirmar en blanco no tiene sentido: un borrador necesita al menos
  -- un dato, por pequeño que sea.
  IF v_motivo IS NULL AND v_anamnesis IS NULL AND v_diag_pres IS NULL
     AND v_diag_def IS NULL AND v_plan IS NULL AND v_recom IS NULL
     AND v_remision IS NULL AND v_proxima IS NULL AND v_examen = '{}'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'No llegó nada de la consulta. Pide al usuario que dicte al menos el motivo.');
  END IF;

  v_argumentos := jsonb_build_object(
    'paciente_id', v_paciente_id,
    'motivo_consulta', v_motivo,
    'anamnesis', v_anamnesis,
    'diagnostico_presuntivo', v_diag_pres,
    'diagnostico_definitivo', v_diag_def,
    'plan_tratamiento', v_plan,
    'recomendaciones', v_recom,
    'remision_externa', v_remision,
    'proxima_revision', v_proxima,
    'examen_fisico', v_examen);

  -- La tarjeta muestra lo que va a quedar y deja claro lo que todavía hay
  -- que firmar: motivo, diagnóstico y tratamiento (050 firmar_consulta).
  IF v_motivo IS NULL THEN v_faltan := v_faltan || 'el motivo'::text; END IF;
  IF COALESCE(v_diag_def, v_diag_pres) IS NULL THEN
    v_faltan := v_faltan || 'el diagnóstico'::text;
  END IF;
  IF v_plan IS NULL THEN v_faltan := v_faltan || 'el tratamiento'::text; END IF;

  v_resumen := '🩺 <b>Borrador de consulta</b>' || E'\n' ||
               esc(v_pac->>'emoji') || ' <b>' || esc(v_pac->>'nombre') || '</b>' ||
               ' · ' || esc(v_pac->>'especie_nombre') ||
               CASE WHEN v_pac->>'raza' IS NOT NULL
                    THEN ' · ' || esc(v_pac->>'raza') ELSE '' END ||
               E'\n' || '👤 ' || esc(COALESCE(v_pac->>'dueno', 'Sin dueño'));

  v_resumen := v_resumen || concat_ws(E'\n',
    CASE WHEN v_motivo IS NOT NULL    THEN '📝 ' || esc(v_motivo) END,
    CASE WHEN v_anamnesis IS NOT NULL THEN '🗣️ ' || esc(v_anamnesis) END,
    CASE WHEN v_examen <> '{}'::jsonb THEN '🩺 ' || esc(examen_texto(v_examen)) END,
    CASE WHEN COALESCE(v_diag_def, v_diag_pres) IS NOT NULL
         THEN '🔬 ' || esc(COALESCE(v_diag_def, v_diag_pres)) END,
    CASE WHEN v_plan IS NOT NULL      THEN '💊 ' || esc(v_plan) END,
    CASE WHEN v_recom IS NOT NULL     THEN '🏠 ' || esc(v_recom) END,
    CASE WHEN v_remision IS NOT NULL  THEN '🏥 ' || esc(v_remision) END,
    CASE WHEN v_proxima IS NOT NULL
         THEN '📅 Próxima revisión: ' || to_char(v_proxima, 'DD/MM/YYYY') END);

  IF array_length(v_faltan, 1) IS NULL THEN
    v_resumen := v_resumen || E'\n' || E'\n' ||
      '⚠️ Es un <b>borrador</b>: no es registro clínico hasta que lo firmes.';
  ELSE
    v_resumen := v_resumen || E'\n' || E'\n' ||
      '⚠️ Para firmar falta ' || esc(frase_lista(v_faltan)) || '.';
  END IF;

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, 'preparar_consulta_clinica', v_argumentos, v_resumen)
  RETURNING id INTO v_ac;

  RETURN jsonb_build_object('ok', true, 'requiere_confirmacion', true,
    'accion_id', v_ac, 'critica', false, 'resumen', v_resumen);
END;
$$;


-- ---------------------------------------------------------------------
-- 4. La ejecución: confirmó la persona, se escribe el borrador
--
-- Reutiliza el borrador que este veterinario tiene en curso para este
-- paciente (misma ventana que `consulta_en_curso`, 050:1346) para que
-- dictar dos veces no deje dos historias a medio escribir. Si no hay uno,
-- abre la consulta por `abrir_consulta` —pasándole el turno sólo cuando
-- ese turno en atención es de ESTE paciente, para no colgar una consulta
-- dictada para otra mascota del turno que está en la mesa— y aplica los
-- campos con `guardar_consulta_completa`, la misma validación del portal.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_consulta_ejecutar(p_usuario_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_paciente uuid := NULLIF(p_args->>'paciente_id', '')::uuid;
  v_consulta uuid;
  v_turno    uuid;
  v_r        jsonb;
  v_antes    jsonb;
  v_datos    jsonb;
  v_examen   jsonb;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'consulta.crear');

  IF v_paciente IS NULL
     OR NOT EXISTS (SELECT 1 FROM paciente WHERE id = v_paciente AND estado = 'activo') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
      'Ese paciente ya no existe o no está activo.');
  END IF;

  SELECT id INTO v_consulta FROM consulta
   WHERE paciente_id = v_paciente AND veterinario_id = p_usuario_id
     AND estado = 'borrador' AND created_at > now() - interval '12 hours'
   ORDER BY updated_at DESC LIMIT 1;

  IF v_consulta IS NULL THEN
    SELECT t.id INTO v_turno FROM turno t
     WHERE t.veterinario_id = p_usuario_id AND t.fecha = hoy_bogota()
       AND t.estado = 'en_atencion' AND t.paciente_id = v_paciente
       AND NOT EXISTS (SELECT 1 FROM consulta c WHERE c.turno_id = t.id)
     ORDER BY t.en_atencion_at DESC LIMIT 1;

    v_r := abrir_consulta(p_usuario_id, v_paciente, v_turno, 'telegram');
    IF NOT (v_r->>'ok')::boolean THEN RETURN v_r; END IF;
    v_consulta := (v_r->'consulta'->>'consulta_id')::uuid;
  END IF;

  v_antes := consulta_json(v_consulta);

  -- El formato del formulario del portal (050 guardar_consulta_completa):
  -- las medidas del examen van con prefijo «examen.». Sólo llegan los
  -- campos que el borrador normalizó; lo que no venga no se pisa.
  SELECT jsonb_object_agg('examen.' || k, v) INTO v_examen
    FROM jsonb_each(COALESCE(p_args->'examen_fisico', '{}'::jsonb)) AS e(k, v);

  v_datos := jsonb_strip_nulls(jsonb_build_object(
    'motivo_consulta', NULLIF(trim(COALESCE(p_args->>'motivo_consulta', '')), ''),
    'anamnesis', NULLIF(trim(COALESCE(p_args->>'anamnesis', '')), ''),
    'diagnostico_presuntivo', NULLIF(trim(COALESCE(p_args->>'diagnostico_presuntivo', '')), ''),
    'diagnostico_definitivo', NULLIF(trim(COALESCE(p_args->>'diagnostico_definitivo', '')), ''),
    'plan_tratamiento', NULLIF(trim(COALESCE(p_args->>'plan_tratamiento', '')), ''),
    'recomendaciones', NULLIF(trim(COALESCE(p_args->>'recomendaciones', '')), ''),
    'remision_externa', NULLIF(trim(COALESCE(p_args->>'remision_externa', '')), ''),
    'proxima_revision', NULLIF(p_args->>'proxima_revision', '')))
    || COALESCE(v_examen, '{}'::jsonb);

  v_r := guardar_consulta_completa(p_usuario_id, v_consulta, v_datos, 'telegram');
  IF NOT (v_r->>'ok')::boolean THEN RETURN v_r; END IF;

  PERFORM auditar('consulta', v_consulta::text, 'ia_borrador', p_usuario_id, 'telegram',
                  v_antes, consulta_json(v_consulta));

  RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(v_consulta));
END;
$$;


-- ---------------------------------------------------------------------
-- 5. Enganches con el asistente
-- ---------------------------------------------------------------------

-- El borrador tiene su propio engranaje —como el alta de la Fase 1— así
-- que escapa del camino genérico de escritura de `ia_llamar`.
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

  -- Segunda reja. La primera fue no ponerla en el catálogo; la tercera es
  -- el exigir_permiso de la propia función de negocio. Tres, porque una
  -- sola se puede olvidar al agregar la herramienta número quince.
  IF h.permiso IS NOT NULL AND NOT tiene_permiso(p_usuario_id, h.permiso) THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'El usuario no tiene permiso para esto. Díselo con naturalidad y ofrécele '
               'otra cosa; no lo intentes por otro camino.');
  END IF;

  -- Las herramientas cuyas propuestas se normalizan en la base (el alta
  -- de la Fase 1 y el borrador de consulta de esta) se preparan aquí y
  -- ya dejan su propuesta en `ia_accion_pendiente`.
  IF p_nombre IN ('preparar_alta_paciente', 'preparar_consulta_clinica') THEN
    IF p_nombre = 'preparar_alta_paciente' THEN
      RETURN ia_alta_paciente_borrador(p_usuario_id, p_chat_id, p_sede_id,
                                       COALESCE(p_args, '{}'::jsonb));
    END IF;
    RETURN ia_consulta_borrador(p_usuario_id, p_chat_id, p_sede_id,
                                COALESCE(p_args, '{}'::jsonb));
  END IF;

  IF NOT h.escribe THEN
    BEGIN
      RETURN ia_leer(p_usuario_id, p_sede_id, p_nombre, COALESCE(p_args, '{}'::jsonb));
    EXCEPTION WHEN others THEN
      -- Un argumento mal formado (un UUID inventado, una fecha rara) no
      -- puede tumbar la tarea: se le devuelve al modelo como resultado
      -- para que corrija y vuelva a intentar.
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  -- Escritura: no se ejecuta, se propone.
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

-- La confirmación ejecuta la misma transacción del portal y el menú.
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

    ELSE
      RETURN jsonb_build_object('ok', false,
        'mensaje', format('La herramienta %s no existe.', p_nombre));
  END CASE;

  RETURN v;
END;
$$;

-- Resultado que ve la persona tras confirmar: el borrador quedó listo y
-- el enlace del portal para revisarlo y firmarlo (077 `portal_url`).
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
      ELSE NULL
    END);
$$;

-- Bienvenida: se suma un ejemplo para quien captura consultas.
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

-- Tras confirmar un borrador de consulta, se ofrece seguir esa consulta en
-- el chat (revisar resumen y firmar, 056 `cli:consulta`) además del portal.
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

  RETURN NULL;
END;
$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON ia_mensaje, ia_accion_pendiente TO chasquipet_app;
