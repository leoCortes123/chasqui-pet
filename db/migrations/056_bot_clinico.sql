-- =====================================================================
-- Chasqui Pet — 056_bot_clinico.sql
-- Pacientes y captura de consulta desde el chat (§8.2).
--
-- La consulta se toma con el animal en la mesa y una mano ocupada. De ahí
-- las cuatro reglas de este archivo:
--
--   1. Botón para todo lo enumerable —especie, sexo, mucosas, hidratación,
--      condición corporal—; texto libre sólo donde es inevitable.
--   2. Cada respuesta se guarda de inmediato como borrador. Si el chat se
--      cae en el paso 4, los tres primeros ya están en la base.
--   3. Lo narrativo es saltable. La consulta mínima viable es motivo +
--      diagnóstico + tratamiento; el resto es opcional y se ve que lo es.
--   4. La consulta se firma con un botón explícito. Hasta entonces no es
--      registro clínico válido y el resumen lo dice.
--
-- El estado vive en conversacion_estado (§2.2.1). El borrador vive en la
-- tabla `consulta`: son dos cosas distintas a propósito, porque perder el
-- hilo de la conversación no puede perder lo ya escrito.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Botones propios en el menú principal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_cli_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_fila jsonb := '[]'::jsonb;
BEGIN
  IF tiene_permiso(p_usuario_id, 'consulta.crear') THEN
    v_fila := v_fila || jsonb_build_object(
                't', CASE WHEN consulta_en_curso(p_usuario_id) IS NOT NULL
                          THEN '🩺 Seguir consulta' ELSE '🩺 Consulta' END,
                'd', 'cli:consulta');
  END IF;
  IF tiene_permiso(p_usuario_id, 'pacientes.ver') THEN
    v_fila := v_fila || jsonb_build_object('t', '🐾 Pacientes', 'd', 'cli:buscar');
  END IF;

  IF jsonb_array_length(v_fila) = 0 THEN RETURN '[]'::jsonb; END IF;
  RETURN jsonb_build_array(v_fila);
END;
$$;

-- ---------------------------------------------------------------------
-- Piezas de interfaz: pacientes
-- ---------------------------------------------------------------------

-- Botones de un catálogo de opciones (especie, sexo, mucosas…), tres por
-- fila como máximo (§12).
CREATE OR REPLACE FUNCTION bot_cli_botones_opciones(p_campo text, p_prefijo text)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_filas jsonb := '[]'::jsonb;
  v_fila  jsonb := '[]'::jsonb;
  o jsonb;
BEGIN
  FOR o IN SELECT * FROM jsonb_array_elements(opciones_examen(p_campo)) LOOP
    v_fila := v_fila || jsonb_build_object('t', o->>'t', 'd', p_prefijo || (o->>'v'));
    IF jsonb_array_length(v_fila) = 3 THEN
      v_filas := v_filas || jsonb_build_array(v_fila);
      v_fila := '[]'::jsonb;
    END IF;
  END LOOP;

  IF jsonb_array_length(v_fila) > 0 THEN
    v_filas := v_filas || jsonb_build_array(v_fila);
  END IF;
  RETURN v_filas;
END;
$$;

-- Punto de partida de la consulta: ¿de quién es esta consulta? Si el
-- veterinario tiene un turno en atención con paciente ya vinculado, esta
-- pantalla no llega a verse.
CREATE OR REPLACE FUNCTION bot_cli_pedir_paciente(p_usuario_id uuid, p_titulo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb := '[]'::jsonb;
BEGIN
  -- Los últimos pacientes que este veterinario atendió: el control de la
  -- tarde suele ser el paciente de la mañana.
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', emoji_especie(especie) || ' ' || nombre,
           'd', 'cli:pac:' || paciente_id))), '[]'::jsonb)
    INTO v_bot
    FROM (SELECT DISTINCT ON (p.id) p.id AS paciente_id, p.nombre, p.especie, c.updated_at
            FROM consulta c JOIN paciente p ON p.id = c.paciente_id
           WHERE c.veterinario_id = p_usuario_id
             AND c.created_at > now() - interval '7 days'
             AND p.estado = 'activo'
           ORDER BY p.id, c.updated_at DESC) r
   WHERE r.updated_at > now() - interval '7 days';

  RETURN jsonb_build_object('texto',
    COALESCE(p_titulo, '🩺 <b>Consulta</b>') || E'\n' ||
    'Escribe el nombre de la mascota, del dueño o el teléfono.',
    'botones', v_bot
      || jsonb_build_array(jsonb_build_array(
           jsonb_build_object('t', '➕ Paciente nuevo', 'd', 'cli:nuevo')))
      || jsonb_build_array(jsonb_build_array(
           jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_cli_resultados_paciente(p_texto text, p_accion text DEFAULT 'pac')
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb; v_n int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', emoji_especie(especie) || ' ' || nombre ||
                COALESCE(' · ' || dueno, ' · sin dueño'),
           'd', 'cli:' || p_accion || ':' || paciente_id)) ORDER BY puntaje DESC), '[]'::jsonb),
         count(*)
    INTO v_bot, v_n
    FROM buscar_paciente(p_texto, 5);

  IF v_n = 0 THEN
    RETURN jsonb_build_object('texto',
      '🔍 No hay ningún paciente parecido a «' || esc(p_texto) || '».' || E'\n' ||
      'Prueba con otro nombre o regístralo.',
      'botones', jsonb_build_array(
        jsonb_build_array(jsonb_build_object('t', '➕ Paciente nuevo', 'd', 'cli:nuevo')),
        jsonb_build_array(jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
  END IF;

  RETURN jsonb_build_object('texto',
    '🔍 <b>' || esc(p_texto) || '</b>' || E'\n' || '¿Cuál es?',
    'botones', v_bot
      || jsonb_build_array(jsonb_build_array(
           jsonb_build_object('t', '➕ Paciente nuevo', 'd', 'cli:nuevo')))
      || jsonb_build_array(jsonb_build_array(
           jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
END;
$$;

-- Ficha del paciente: lo que hay que saber antes de tocar al animal.
-- Alergias arriba y en negrita, siempre.
CREATE OR REPLACE FUNCTION bot_cli_ficha(p_paciente_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  p jsonb := paciente_json(p_paciente_id);
  v_texto text;
  v_bot jsonb := '[]'::jsonb;
  v_fila jsonb := '[]'::jsonb;
BEGIN
  IF p IS NULL THEN
    RETURN jsonb_build_object('texto', 'Ese paciente ya no existe.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
  END IF;

  v_texto := format('%s <b>%s</b>%s%s%s',
               p->>'emoji', esc(p->>'nombre'), E'\n',
               concat_ws(' · ',
                 esc(p->>'especie_nombre'),
                 NULLIF(esc(COALESCE(p->>'raza','')), ''),
                 CASE p->>'sexo' WHEN 'macho' THEN 'Macho'
                                 WHEN 'hembra' THEN 'Hembra' ELSE NULL END,
                 NULLIF(esc(COALESCE(p->>'edad','')), ''),
                 CASE WHEN p->>'peso_kg' IS NOT NULL
                      THEN fmt_cant((p->>'peso_kg')::numeric) || ' kg' END),
               E'\n');

  IF p->>'alergias' IS NOT NULL THEN
    v_texto := v_texto || '⚠️ <b>Alergias:</b> ' || esc(p->>'alergias') || E'\n';
  END IF;

  IF p->>'estado' = 'fallecido' THEN
    v_texto := v_texto || '🕯️ Paciente fallecido.' || E'\n';
  END IF;

  v_texto := v_texto || '👤 ' || esc(COALESCE(p->>'dueno', 'Sin dueño registrado'));
  IF p->>'telefono' IS NOT NULL THEN
    v_texto := v_texto || ' · ' || esc(p->>'telefono');
  END IF;

  v_texto := v_texto || E'\n' || format('📋 %s consulta(s) registrada(s)%s',
               p->>'consultas',
               CASE WHEN p->>'ultima_consulta' IS NOT NULL
                    THEN ', la última el ' || to_char((p->>'ultima_consulta')::date, 'DD/MM/YYYY')
                    ELSE '' END);

  IF tiene_permiso(p_usuario_id, 'consulta.crear') AND p->>'estado' = 'activo' THEN
    v_fila := v_fila || jsonb_build_object('t', '🩺 Abrir consulta', 'd', 'cli:abrir:' || p_paciente_id);
  END IF;
  IF (p->>'consultas')::int > 0 THEN
    v_fila := v_fila || jsonb_build_object('t', '📋 Historia', 'd', 'cli:hist:' || p_paciente_id);
  END IF;
  IF jsonb_array_length(v_fila) > 0 THEN v_bot := v_bot || jsonb_build_array(v_fila); END IF;

  RETURN jsonb_build_object('texto', v_texto,
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '🔍 Otro paciente', 'd', 'cli:buscar'),
      jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
END;
$$;

-- Historia clínica en el chat: las últimas cinco, en texto corto. La
-- completa se lee en el portal (§11.2).
CREATE OR REPLACE FUNCTION bot_cli_historia(p_paciente_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  p jsonb := paciente_json(p_paciente_id);
  v_lineas text;
BEGIN
  SELECT string_agg(
           format('<b>%s</b> · %s%s%s%s',
                  to_char(fecha, 'DD/MM/YYYY'),
                  esc(COALESCE(veterinario, '—')), E'\n',
                  '  ' || esc(COALESCE(diagnostico, motivo, 'Sin diagnóstico registrado')),
                  COALESCE(E'\n' || '  💊 ' || esc(medicamentos), '')),
           E'\n' ORDER BY fecha DESC)
    INTO v_lineas
    FROM historia_paciente(p_paciente_id, 5);

  RETURN jsonb_build_object('texto',
    format('📋 <b>Historia de %s</b>%s%s', esc(p->>'nombre'), E'\n',
           COALESCE(v_lineas, 'Todavía no tiene consultas firmadas.')),
    'botones', jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '⬅️ Ficha', 'd', 'cli:pac:' || p_paciente_id),
      jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
END;
$$;

-- ---------------------------------------------------------------------
-- Alta de paciente nuevo, en el mínimo de preguntas posible
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_cli_alta_vista(p_paso text, p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_cancelar jsonb := jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '🚫 Cancelar', 'd', 'cli:cancelar')));
BEGIN
  CASE p_paso
    WHEN 'dueno_nombre' THEN
      RETURN jsonb_build_object('texto',
        '➕ <b>Paciente nuevo</b>' || E'\n' ||
        '👤 ¿Cómo se llama el dueño?',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '🐾 Sin dueño (callejero)', 'd', 'cli:sindueno')))
          || v_cancelar);

    WHEN 'dueno_telefono' THEN
      RETURN jsonb_build_object('texto',
        format('👤 <b>%s</b>%s📞 ¿Teléfono? Sirve para avisarle y para no duplicarlo después.',
               esc(p_datos->>'dueno_nombre'), E'\n'),
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⏭️ No lo tiene', 'd', 'cli:saltar:dueno_telefono')))
          || v_cancelar);

    WHEN 'mascota_nombre' THEN
      RETURN jsonb_build_object('texto',
        '🐾 ¿Cómo se llama la mascota?', 'botones', v_cancelar);

    WHEN 'especie' THEN
      RETURN jsonb_build_object('texto',
        format('🐾 <b>%s</b>%s¿Qué es?', esc(p_datos->>'mascota_nombre'), E'\n'),
        'botones', bot_cli_botones_opciones('especie', 'cli:esp:') || v_cancelar);

    WHEN 'sexo' THEN
      RETURN jsonb_build_object('texto', '¿Macho o hembra?',
        'botones', bot_cli_botones_opciones('sexo', 'cli:sexo:') || v_cancelar);

    ELSE
      RETURN jsonb_build_object('texto', 'Ese paso ya no existe.', 'botones', v_cancelar);
  END CASE;
END;
$$;

-- Deduplicación antes de crear (§8.1). Se muestran los candidatos y hay
-- que decidir: usar uno o crear de todos modos.
CREATE OR REPLACE FUNCTION bot_cli_duplicados(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_bot jsonb; v_n int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
           't', emoji_especie(especie) || ' ' || nombre || ' · ' || COALESCE(dueno, '—'),
           'd', 'cli:pac:' || paciente_id))), '[]'::jsonb), count(*)
    INTO v_bot, v_n
    FROM posibles_duplicados(p_datos->>'mascota_nombre',
                             p_datos->>'dueno_nombre',
                             p_datos->>'dueno_telefono');

  IF v_n = 0 THEN RETURN NULL; END IF;

  RETURN jsonb_build_object('texto',
    '⚠️ <b>Puede que ya esté registrado</b>' || E'\n' ||
    'Si es alguno de estos, tócalo y usamos su historia.',
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '➕ No, es otro. Crearlo', 'd', 'cli:crear'),
      jsonb_build_object('t', '🚫 Cancelar', 'd', 'cli:cancelar'))));
END;
$$;

-- ---------------------------------------------------------------------
-- Captura de la consulta
-- ---------------------------------------------------------------------

-- El orden de los pasos en un solo sitio: lo usan el avance normal, el
-- botón de saltar y el de corregir.
CREATE OR REPLACE FUNCTION bot_cli_siguiente_paso(p_paso text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_paso
           WHEN 'motivo'          THEN 'anamnesis'
           WHEN 'anamnesis'       THEN 'examen'
           WHEN 'examen'          THEN 'diagnostico'
           WHEN 'diagnostico'     THEN 'tratamiento'
           WHEN 'tratamiento'     THEN 'recomendaciones'
           WHEN 'recomendaciones' THEN 'resumen'
           ELSE 'resumen'
         END;
$$;

-- Menú del examen físico. Cada medida ya tomada se ve en el botón, para
-- que corregir sea tan barato como escribir.
CREATE OR REPLACE FUNCTION bot_cli_examen(p_consulta_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e jsonb;
  p jsonb;
  v_texto text;
BEGIN
  SELECT examen_fisico, paciente_json(paciente_id) INTO e, p
    FROM consulta WHERE id = p_consulta_id;

  v_texto := format('🩺 <b>Examen físico</b> · %s%s%s', esc(p->>'nombre'), E'\n',
               COALESCE(examen_texto(e), 'Todavía sin medidas. Es opcional: toca «Seguir» si no aplica.'));

  RETURN jsonb_build_object('texto', v_texto, 'botones', jsonb_build_array(
    jsonb_build_array(
      jsonb_build_object('t', CASE WHEN e ? 'peso_kg'
                                   THEN '⚖️ ' || (e->>'peso_kg') || ' kg' ELSE '⚖️ Peso' END,
                         'd', 'cli:exc:peso_kg'),
      jsonb_build_object('t', CASE WHEN e ? 'temperatura_c'
                                   THEN '🌡️ ' || (e->>'temperatura_c') || '°' ELSE '🌡️ Temp.' END,
                         'd', 'cli:exc:temperatura_c')),
    jsonb_build_array(
      jsonb_build_object('t', CASE WHEN e ? 'fc' THEN 'FC ' || (e->>'fc') ELSE 'FC' END,
                         'd', 'cli:exc:fc'),
      jsonb_build_object('t', CASE WHEN e ? 'fr' THEN 'FR ' || (e->>'fr') ELSE 'FR' END,
                         'd', 'cli:exc:fr'),
      jsonb_build_object('t', CASE WHEN e ? 'tllc_seg' THEN 'TLLC ' || (e->>'tllc_seg') ELSE 'TLLC' END,
                         'd', 'cli:exc:tllc_seg')),
    jsonb_build_array(
      jsonb_build_object('t', CASE WHEN e ? 'mucosas'
                                   THEN '👄 ' || etiqueta_opcion('mucosas', e->>'mucosas')
                                   ELSE '👄 Mucosas' END,
                         'd', 'cli:exl:mucosas'),
      jsonb_build_object('t', CASE WHEN e ? 'hidratacion'
                                   THEN '💧 ' || etiqueta_opcion('hidratacion', e->>'hidratacion')
                                   ELSE '💧 Hidratación' END,
                         'd', 'cli:exl:hidratacion'),
      jsonb_build_object('t', CASE WHEN e ? 'cc'
                                   THEN '📏 ' || etiqueta_opcion('cc', e->>'cc')
                                   ELSE '📏 Cond. corporal' END,
                         'd', 'cli:exl:cc')),
    jsonb_build_array(
      jsonb_build_object('t', '➡️ Seguir', 'd', 'cli:paso:diagnostico'),
      jsonb_build_object('t', '💾 Salir y seguir después', 'd', 'cli:pausa'))));
END;
$$;

-- Pantalla de un paso narrativo. Lo que ya está escrito se muestra
-- arriba: el veterinario que vuelve a un borrador de hace una hora no
-- tiene por qué recordar qué puso.
CREATE OR REPLACE FUNCTION bot_cli_vista_paso(p_consulta_id uuid, p_paso text)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  c consulta;
  p jsonb;
  v_texto text;
  v_actual text;
  v_bot jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO c FROM consulta WHERE id = p_consulta_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('texto', 'Esa consulta ya no existe.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
  END IF;

  IF p_paso = 'examen'  THEN RETURN bot_cli_examen(p_consulta_id); END IF;
  IF p_paso = 'resumen' THEN RETURN bot_cli_resumen(p_consulta_id); END IF;

  p := paciente_json(c.paciente_id);

  v_texto := CASE p_paso
    WHEN 'motivo'          THEN '📝 ¿Por qué lo traen? (motivo de la consulta)'
    WHEN 'anamnesis'       THEN '🗣️ Anamnesis: qué cuenta el dueño. Opcional.'
    WHEN 'diagnostico'     THEN '🔬 Diagnóstico presuntivo o definitivo.'
    WHEN 'tratamiento'     THEN '💊 Plan de tratamiento.'
    WHEN 'recomendaciones' THEN '🏠 Recomendaciones para la casa. Opcional.'
    WHEN 'remision'        THEN '🏥 Remisión externa: qué examen y a dónde. Opcional.'
    WHEN 'proxima'         THEN '📅 Próxima revisión, en días (por ejemplo 8). Opcional.'
    ELSE 'Escribe la respuesta.'
  END;

  v_actual := CASE p_paso
    WHEN 'motivo'          THEN c.motivo_consulta
    WHEN 'anamnesis'       THEN c.anamnesis
    WHEN 'diagnostico'     THEN COALESCE(c.diagnostico_definitivo, c.diagnostico_presuntivo)
    WHEN 'tratamiento'     THEN c.plan_tratamiento
    WHEN 'recomendaciones' THEN c.recomendaciones
    WHEN 'remision'        THEN c.remision_externa
    WHEN 'proxima'         THEN to_char(c.proxima_revision, 'DD/MM/YYYY')
    ELSE NULL
  END;

  v_texto := format('%s <b>%s</b> · borrador%s%s',
               p->>'emoji', esc(p->>'nombre'), E'\n', v_texto);

  IF v_actual IS NOT NULL THEN
    v_texto := v_texto || E'\n\n' || '<i>Ahora dice:</i> ' || esc(v_actual) || E'\n' ||
               'Lo que escribas lo reemplaza.';
  END IF;

  -- Sólo lo opcional se puede saltar. Motivo, diagnóstico y tratamiento
  -- no tienen botón de saltar porque sin ellos no se puede firmar.
  IF p_paso IN ('anamnesis','recomendaciones','remision','proxima') THEN
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '⏭️ Saltar', 'd', 'cli:paso:' || bot_cli_siguiente_paso(p_paso))));
  END IF;

  IF p_paso = 'proxima' THEN
    v_bot := jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '8 días',  'd', 'cli:rev:8'),
               jsonb_build_object('t', '15 días', 'd', 'cli:rev:15'),
               jsonb_build_object('t', '30 días', 'd', 'cli:rev:30'))) || v_bot;
  END IF;

  RETURN jsonb_build_object('texto', v_texto,
    'botones', v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '📄 Ver resumen', 'd', 'cli:paso:resumen'),
      jsonb_build_object('t', '💾 Salir', 'd', 'cli:pausa'))));
END;
$$;

-- Resumen y firma. Mientras diga «borrador», no es registro clínico
-- válido, y el texto lo dice con todas las letras (§8.2.4).
CREATE OR REPLACE FUNCTION bot_cli_resumen(p_consulta_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  c jsonb := consulta_json(p_consulta_id);
  v_texto text;
  v_meds text;
  v_bot jsonb := '[]'::jsonb;
  v_faltan text[] := ARRAY[]::text[];
BEGIN
  IF c IS NULL THEN
    RETURN jsonb_build_object('texto', 'Esa consulta ya no existe.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
  END IF;

  v_texto := format('%s <b>%s</b> · %s%s',
               c->'paciente'->>'emoji', esc(c->'paciente'->>'nombre'),
               CASE c->>'estado'
                 WHEN 'firmada' THEN '✅ firmada'
                 WHEN 'anulada' THEN '🚫 anulada'
                 ELSE '📝 borrador' END,
               E'\n');

  v_texto := v_texto || concat_ws(E'\n',
    CASE WHEN c->>'motivo_consulta' IS NOT NULL THEN '📝 ' || esc(c->>'motivo_consulta') END,
    CASE WHEN c->>'anamnesis' IS NOT NULL THEN '🗣️ ' || esc(c->>'anamnesis') END,
    CASE WHEN c->>'examen_texto' IS NOT NULL THEN '🩺 ' || esc(c->>'examen_texto') END,
    CASE WHEN COALESCE(c->>'diagnostico_definitivo', c->>'diagnostico_presuntivo') IS NOT NULL
         THEN '🔬 ' || esc(COALESCE(c->>'diagnostico_definitivo', c->>'diagnostico_presuntivo')) END,
    CASE WHEN c->>'plan_tratamiento' IS NOT NULL THEN '💊 ' || esc(c->>'plan_tratamiento') END,
    CASE WHEN c->>'recomendaciones' IS NOT NULL THEN '🏠 ' || esc(c->>'recomendaciones') END,
    CASE WHEN c->>'remision_externa' IS NOT NULL THEN '🏥 ' || esc(c->>'remision_externa') END,
    CASE WHEN c->>'proxima_revision' IS NOT NULL
         THEN '📅 Próxima revisión: ' || to_char((c->>'proxima_revision')::date, 'DD/MM/YYYY') END);

  SELECT string_agg(format('%s %s %s', esc(m->>'nombre'),
                           fmt_cant((m->>'cantidad')::numeric), esc(m->>'unidad')), ', ')
    INTO v_meds FROM jsonb_array_elements(c->'medicamentos') m;
  IF v_meds IS NOT NULL THEN
    v_texto := v_texto || E'\n' || '💉 Despachado: ' || v_meds;
  END IF;

  IF c->>'estado' = 'borrador' THEN
    IF c->>'motivo_consulta' IS NULL THEN v_faltan := v_faltan || 'el motivo'::text; END IF;
    IF COALESCE(c->>'diagnostico_definitivo', c->>'diagnostico_presuntivo') IS NULL
      THEN v_faltan := v_faltan || 'el diagnóstico'::text; END IF;
    IF c->>'plan_tratamiento' IS NULL THEN v_faltan := v_faltan || 'el tratamiento'::text; END IF;

    IF array_length(v_faltan, 1) IS NULL THEN
      v_texto := v_texto || E'\n\n' || '⚠️ Es un <b>borrador</b>: no es registro clínico hasta que lo firmes.';
      v_bot := v_bot || jsonb_build_array(jsonb_build_array(
                 jsonb_build_object('t', '✅ Firmar', 'd', 'cli:firmar')));
    ELSE
      v_texto := v_texto || E'\n\n' ||
                 '⚠️ Para firmar falta ' || esc(frase_lista(v_faltan)) || '.';
    END IF;

    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '📝 Motivo',      'd', 'cli:paso:motivo'),
               jsonb_build_object('t', '🔬 Diagnóstico', 'd', 'cli:paso:diagnostico'),
               jsonb_build_object('t', '💊 Tratamiento', 'd', 'cli:paso:tratamiento')));
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '🩺 Examen',   'd', 'cli:paso:examen'),
               jsonb_build_object('t', '🏥 Remisión', 'd', 'cli:paso:remision'),
               jsonb_build_object('t', '📅 Revisión', 'd', 'cli:paso:proxima')));
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '💾 Salir y seguir después', 'd', 'cli:pausa')));
  ELSE
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '➕ Adenda', 'd', 'cli:adenda'),
               jsonb_build_object('t', '⬅️ Menú',   'd', 'cli:cancelar')));
  END IF;

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_bot);
END;
$$;

-- ---------------------------------------------------------------------
-- Callbacks del módulo clínico
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_cli_callback(
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
  v_consulta uuid;
  v_paciente uuid;
  v_paso   text;
BEGIN
  IF v_partes[1] <> 'cli' THEN
    RETURN NULL;
  END IF;

  v_estado := estado_leer(p_chat_id);
  v_datos  := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_consulta := NULLIF(v_datos->>'consulta_id', '')::uuid;

  CASE v_partes[2]

    -- --- Entrada al módulo -----------------------------------------
    WHEN 'consulta' THEN
      PERFORM exigir_permiso(p_usuario_id, 'consulta.crear');
      v_consulta := consulta_en_curso(p_usuario_id);

      IF v_consulta IS NOT NULL THEN
        -- Hay un borrador abierto: seguirlo es lo que casi siempre se
        -- quiere, pero empezar otro tiene que ser posible sin salir.
        PERFORM estado_guardar(p_chat_id, 'consulta', 'resumen',
                  jsonb_build_object('consulta_id', v_consulta), p_usuario_id, p_mensaje_id);
        v_vista := bot_cli_resumen(v_consulta);
        v_vista := jsonb_set(v_vista, '{botones}',
                     (v_vista->'botones') || jsonb_build_array(jsonb_build_array(
                       jsonb_build_object('t', '🆕 Otra consulta', 'd', 'cli:nueva'))));
      ELSE
        -- El paciente del turno que este veterinario tiene en la mesa.
        SELECT paciente_id INTO v_paciente FROM turno
         WHERE veterinario_id = p_usuario_id AND fecha = hoy_bogota()
           AND estado = 'en_atencion' AND paciente_id IS NOT NULL
         ORDER BY en_atencion_at DESC LIMIT 1;

        IF v_paciente IS NOT NULL THEN
          v_r := abrir_consulta(p_usuario_id, v_paciente);
          IF (v_r->>'ok')::boolean THEN
            v_consulta := (v_r->'consulta'->>'consulta_id')::uuid;
            PERFORM estado_guardar(p_chat_id, 'consulta', 'motivo',
                      jsonb_build_object('consulta_id', v_consulta), p_usuario_id, p_mensaje_id);
            v_vista := bot_cli_vista_paso(v_consulta, 'motivo');
          ELSE
            v_alerta := v_r->>'mensaje';
            v_vista := bot_cli_pedir_paciente(p_usuario_id);
          END IF;
        ELSE
          PERFORM estado_limpiar(p_chat_id);
          PERFORM estado_guardar(p_chat_id, 'consulta', 'paciente', '{}'::jsonb,
                                 p_usuario_id, p_mensaje_id);
          v_vista := bot_cli_pedir_paciente(p_usuario_id);
        END IF;
      END IF;

    WHEN 'nueva' THEN
      PERFORM exigir_permiso(p_usuario_id, 'consulta.crear');
      PERFORM estado_limpiar(p_chat_id);
      PERFORM estado_guardar(p_chat_id, 'consulta', 'paciente', '{}'::jsonb,
                             p_usuario_id, p_mensaje_id);
      v_vista := bot_cli_pedir_paciente(p_usuario_id);

    WHEN 'buscar' THEN
      PERFORM exigir_permiso(p_usuario_id, 'pacientes.ver');
      PERFORM estado_limpiar(p_chat_id);
      PERFORM estado_guardar(p_chat_id, 'paciente_buscar', 'texto', '{}'::jsonb,
                             p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '🐾 <b>Pacientes</b>' || E'\n' ||
        'Escribe el nombre de la mascota, del dueño o el teléfono.',
        'botones', jsonb_build_array(
          jsonb_build_array(jsonb_build_object('t', '➕ Paciente nuevo', 'd', 'cli:nuevo')),
          jsonb_build_array(jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));

    -- --- Ficha e historia -------------------------------------------
    WHEN 'pac' THEN
      -- Elegido dentro del flujo de consulta: se abre directamente. Fuera
      -- de él, se muestra la ficha.
      IF v_estado->>'flujo' = 'consulta' THEN
        v_r := abrir_consulta(p_usuario_id, v_partes[3]::uuid);
        IF (v_r->>'ok')::boolean THEN
          v_consulta := (v_r->'consulta'->>'consulta_id')::uuid;
          v_paso := CASE WHEN (v_r->>'reabierta')::boolean THEN 'resumen' ELSE 'motivo' END;
          PERFORM estado_guardar(p_chat_id, 'consulta', v_paso,
                    jsonb_build_object('consulta_id', v_consulta), p_usuario_id, p_mensaje_id);
          v_vista := bot_cli_vista_paso(v_consulta, v_paso);
        ELSE
          v_alerta := v_r->>'mensaje';
          v_vista := bot_cli_ficha(v_partes[3]::uuid, p_usuario_id);
        END IF;
      ELSE
        PERFORM estado_limpiar(p_chat_id);
        v_vista := bot_cli_ficha(v_partes[3]::uuid, p_usuario_id);
      END IF;

    WHEN 'abrir' THEN
      v_r := abrir_consulta(p_usuario_id, v_partes[3]::uuid);
      IF (v_r->>'ok')::boolean THEN
        v_consulta := (v_r->'consulta'->>'consulta_id')::uuid;
        v_paso := CASE WHEN (v_r->>'reabierta')::boolean THEN 'resumen' ELSE 'motivo' END;
        PERFORM estado_guardar(p_chat_id, 'consulta', v_paso,
                  jsonb_build_object('consulta_id', v_consulta), p_usuario_id, p_mensaje_id);
        v_vista := bot_cli_vista_paso(v_consulta, v_paso);
      ELSE
        v_alerta := v_r->>'mensaje';
        v_vista := bot_cli_ficha(v_partes[3]::uuid, p_usuario_id);
      END IF;

    WHEN 'hist' THEN
      PERFORM exigir_permiso(p_usuario_id, 'pacientes.ver');
      v_vista := bot_cli_historia(v_partes[3]::uuid);

    -- --- Alta de paciente -------------------------------------------
    WHEN 'nuevo' THEN
      PERFORM exigir_permiso(p_usuario_id, 'pacientes.editar');
      -- Estado nuevo de cero: estado_guardar mezcla, y aquí no queremos
      -- arrastrar el consulta_id del flujo del que venimos.
      v_paso := COALESCE(v_estado->>'flujo', 'menu');
      PERFORM estado_limpiar(p_chat_id);
      PERFORM estado_guardar(p_chat_id, 'paciente_nuevo', 'dueno_nombre',
                jsonb_build_object('venia_de', v_paso),
                p_usuario_id, p_mensaje_id);
      v_datos := jsonb_build_object('venia_de', v_paso);
      v_vista := bot_cli_alta_vista('dueno_nombre', '{}'::jsonb);

    WHEN 'sindueno' THEN
      v_datos := v_datos || jsonb_build_object('sin_dueno', true);
      PERFORM estado_guardar(p_chat_id, 'paciente_nuevo', 'mascota_nombre', v_datos,
                             p_usuario_id, p_mensaje_id);
      v_vista := bot_cli_alta_vista('mascota_nombre', v_datos);

    WHEN 'saltar' THEN
      IF v_partes[3] = 'dueno_telefono' THEN
        PERFORM estado_guardar(p_chat_id, 'paciente_nuevo', 'mascota_nombre', v_datos,
                               p_usuario_id, p_mensaje_id);
        v_vista := bot_cli_alta_vista('mascota_nombre', v_datos);
      ELSE
        v_alerta := 'Nada que saltar.';
        v_vista := bot_menu_principal(p_usuario_id);
      END IF;

    WHEN 'esp' THEN
      v_datos := v_datos || jsonb_build_object('especie', v_partes[3]);
      PERFORM estado_guardar(p_chat_id, 'paciente_nuevo', 'sexo', v_datos,
                             p_usuario_id, p_mensaje_id);
      v_vista := bot_cli_alta_vista('sexo', v_datos);

    WHEN 'sexo' THEN
      v_datos := v_datos || jsonb_build_object('sexo', v_partes[3]);
      PERFORM estado_guardar(p_chat_id, 'paciente_nuevo', 'confirmar', v_datos,
                             p_usuario_id, p_mensaje_id);

      -- Última oportunidad de no duplicar (§8.1).
      v_vista := bot_cli_duplicados(v_datos);
      IF v_vista IS NULL THEN
        v_vista := bot_cli_crear_paciente(p_usuario_id, p_chat_id, v_datos, p_mensaje_id);
      END IF;

    WHEN 'crear' THEN
      v_vista := bot_cli_crear_paciente(p_usuario_id, p_chat_id, v_datos, p_mensaje_id);

    WHEN 'dueno' THEN
      -- Se reutiliza un dueño existente: se salta el teléfono.
      v_datos := v_datos || jsonb_build_object('dueno_id', v_partes[3]);
      PERFORM estado_guardar(p_chat_id, 'paciente_nuevo', 'mascota_nombre', v_datos,
                             p_usuario_id, p_mensaje_id);
      v_vista := bot_cli_alta_vista('mascota_nombre', v_datos);

    -- --- Pasos de la consulta ---------------------------------------
    WHEN 'paso' THEN
      IF v_consulta IS NULL THEN
        v_alerta := 'La consulta se perdió por el camino.';
        v_vista := bot_cli_pedir_paciente(p_usuario_id);
      ELSE
        PERFORM estado_guardar(p_chat_id, 'consulta', v_partes[3], v_datos,
                               p_usuario_id, p_mensaje_id);
        v_vista := bot_cli_vista_paso(v_consulta, v_partes[3]);
      END IF;

    -- Campo numérico del examen: se pide por texto.
    WHEN 'exc' THEN
      PERFORM estado_guardar(p_chat_id, 'consulta', 'examen_valor',
                v_datos || jsonb_build_object('examen_clave', v_partes[3]),
                p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        CASE v_partes[3]
          WHEN 'peso_kg'       THEN '⚖️ Peso en kilos (por ejemplo 4.2).'
          WHEN 'temperatura_c' THEN '🌡️ Temperatura en °C (por ejemplo 38.5).'
          WHEN 'fc'            THEN 'Frecuencia cardiaca, latidos por minuto.'
          WHEN 'fr'            THEN 'Frecuencia respiratoria, por minuto.'
          ELSE 'TLLC en segundos (por ejemplo 1.5).'
        END,
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver al examen', 'd', 'cli:paso:examen'))));

    -- Campo enumerado del examen: botones.
    WHEN 'exl' THEN
      v_vista := jsonb_build_object('texto',
        CASE v_partes[3]
          WHEN 'mucosas'     THEN '👄 ¿Cómo están las mucosas?'
          WHEN 'hidratacion' THEN '💧 ¿Estado de hidratación?'
          ELSE '📏 ¿Condición corporal?'
        END,
        'botones', bot_cli_botones_opciones(v_partes[3], 'cli:exo:' || v_partes[3] || ':')
          || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '⬅️ Volver al examen', 'd', 'cli:paso:examen'))));

    WHEN 'exo' THEN
      v_r := guardar_examen(p_usuario_id, v_consulta, v_partes[3], v_partes[4]);
      IF NOT (v_r->>'ok')::boolean THEN v_alerta := v_r->>'mensaje'; END IF;
      PERFORM estado_guardar(p_chat_id, 'consulta', 'examen', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := bot_cli_examen(v_consulta);

    -- Próxima revisión en días: la cuenta la hace el sistema.
    WHEN 'rev' THEN
      v_r := guardar_consulta(p_usuario_id, v_consulta, 'proxima_revision',
                              (hoy_bogota() + (v_partes[3]::int))::text);
      IF NOT (v_r->>'ok')::boolean THEN
        v_alerta := v_r->>'mensaje';
      ELSE
        v_alerta := 'Revisión en ' || v_partes[3] || ' días';
      END IF;
      PERFORM estado_guardar(p_chat_id, 'consulta', 'resumen', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := bot_cli_resumen(v_consulta);

    -- --- Firma -------------------------------------------------------
    WHEN 'firmar' THEN
      v_r := firmar_consulta(p_usuario_id, v_consulta);
      IF (v_r->>'ok')::boolean THEN
        PERFORM estado_limpiar(p_chat_id);
        v_alerta := 'Consulta firmada';
        v_vista := bot_cli_resumen(v_consulta);
        v_vista := jsonb_set(v_vista, '{texto}',
                     to_jsonb('✅ <b>Consulta firmada</b>' || E'\n' || (v_vista->>'texto')));
      ELSE
        v_alerta := v_r->>'mensaje';
        v_vista := bot_cli_resumen(v_consulta);
      END IF;

    WHEN 'adenda' THEN
      PERFORM estado_guardar(p_chat_id, 'consulta', 'adenda', v_datos, p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '➕ <b>Adenda</b>' || E'\n' ||
        'Lo firmado no se edita. Escribe la corrección o el dato que faltó: queda añadido con tu nombre y la hora.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '🚫 Cancelar', 'd', 'cli:cancelar'))));

    -- --- Salidas ------------------------------------------------------
    WHEN 'pausa' THEN
      -- El borrador queda guardado; sólo se suelta la conversación.
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_menu_principal(p_usuario_id);
      v_alerta := 'Borrador guardado';

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

-- Crea dueño (si hay) y paciente con lo recogido en el flujo, y encadena
-- con la consulta si de ahí veníamos.
CREATE OR REPLACE FUNCTION bot_cli_crear_paciente(
  p_usuario_id uuid, p_chat_id bigint, p_datos jsonb, p_mensaje_id bigint)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_dueno uuid := NULLIF(p_datos->>'dueno_id', '')::uuid;
  v_r     jsonb;
  v_paciente uuid;
  v_consulta uuid;
BEGIN
  IF v_dueno IS NULL AND NOT COALESCE((p_datos->>'sin_dueno')::boolean, false) THEN
    v_r := crear_dueno(p_usuario_id, p_datos->>'dueno_nombre', p_datos->>'dueno_telefono');
    IF NOT (v_r->>'ok')::boolean THEN
      RETURN jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
    END IF;
    v_dueno := (v_r->'dueno'->>'dueno_id')::uuid;
  END IF;

  v_r := crear_paciente(p_usuario_id, p_datos->>'mascota_nombre',
                        COALESCE(p_datos->>'especie', 'otro'), v_dueno,
                        COALESCE(p_datos->>'sexo', 'desconocido'));

  IF NOT (v_r->>'ok')::boolean THEN
    RETURN jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
  END IF;

  v_paciente := (v_r->'paciente'->>'paciente_id')::uuid;

  -- Si el paciente se registró para atenderlo ya, se sigue de largo a la
  -- consulta en vez de devolver al menú.
  IF p_datos->>'venia_de' = 'consulta' AND tiene_permiso(p_usuario_id, 'consulta.crear') THEN
    v_r := abrir_consulta(p_usuario_id, v_paciente);
    IF (v_r->>'ok')::boolean THEN
      v_consulta := (v_r->'consulta'->>'consulta_id')::uuid;
      PERFORM estado_guardar(p_chat_id, 'consulta', 'motivo',
                jsonb_build_object('consulta_id', v_consulta), p_usuario_id, p_mensaje_id);
      RETURN bot_cli_vista_paso(v_consulta, 'motivo');
    END IF;
  END IF;

  PERFORM estado_limpiar(p_chat_id);
  RETURN bot_cli_ficha(v_paciente, p_usuario_id);
END;
$$;

-- ---------------------------------------------------------------------
-- Texto libre del módulo clínico
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_cli_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado jsonb := estado_leer(p_chat_id);
  v_flujo  text  := v_estado->>'flujo';
  v_paso   text  := v_estado->>'paso';
  v_datos  jsonb := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_consulta uuid := NULLIF(v_datos->>'consulta_id', '')::uuid;
  v_vista  jsonb;
  v_r      jsonb;
  v_campo  text;
  v_dup    jsonb;
BEGIN
  -- Comando suelto: buscar un paciente sin pasar por el menú.
  IF p_texto ~* '^(paciente|mascota)\s+\S' AND tiene_permiso(p_usuario_id, 'pacientes.ver') THEN
    v_vista := bot_cli_resultados_paciente(
                 regexp_replace(p_texto, '^\s*(paciente|mascota)\s+', '', 'i'), 'pac');
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
  END IF;

  IF v_flujo NOT IN ('consulta', 'paciente_nuevo', 'paciente_buscar') OR v_flujo IS NULL THEN
    RETURN NULL;   -- no es nuestro: que siga el enrutador
  END IF;

  -- --- Búsqueda suelta de paciente ---------------------------------
  IF v_flujo = 'paciente_buscar' THEN
    PERFORM exigir_permiso(p_usuario_id, 'pacientes.ver');
    v_vista := bot_cli_resultados_paciente(p_texto, 'pac');

  -- --- Alta de paciente ---------------------------------------------
  ELSIF v_flujo = 'paciente_nuevo' THEN
    PERFORM exigir_permiso(p_usuario_id, 'pacientes.editar');

    CASE v_paso
      WHEN 'dueno_nombre' THEN
        v_datos := v_datos || jsonb_build_object('dueno_nombre', trim(p_texto));

        -- ¿Ese dueño ya existe? Preguntarlo aquí ahorra el duplicado y
        -- las dos preguntas siguientes.
        SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
                 't', '👤 ' || nombre || COALESCE(' · ' || mascotas, ''),
                 'd', 'cli:dueno:' || dueno_id))), '[]'::jsonb)
          INTO v_dup
          FROM buscar_dueno(trim(p_texto), 3);

        PERFORM estado_guardar(p_chat_id, 'paciente_nuevo', 'dueno_telefono', v_datos,
                               p_usuario_id);

        IF jsonb_array_length(v_dup) > 0 THEN
          v_vista := jsonb_build_object('texto',
            '👤 ¿Es alguno de estos, o es un dueño nuevo?',
            'botones', v_dup || jsonb_build_array(jsonb_build_array(
              jsonb_build_object('t', '➕ Es nuevo', 'd', 'cli:saltar:dueno_telefono'),
              jsonb_build_object('t', '🚫 Cancelar', 'd', 'cli:cancelar'))));
        ELSE
          v_vista := bot_cli_alta_vista('dueno_telefono', v_datos);
        END IF;

      WHEN 'dueno_telefono' THEN
        v_datos := v_datos || jsonb_build_object('dueno_telefono', trim(p_texto));
        PERFORM estado_guardar(p_chat_id, 'paciente_nuevo', 'mascota_nombre', v_datos, p_usuario_id);
        v_vista := bot_cli_alta_vista('mascota_nombre', v_datos);

      WHEN 'mascota_nombre' THEN
        v_datos := v_datos || jsonb_build_object('mascota_nombre', trim(p_texto));
        PERFORM estado_guardar(p_chat_id, 'paciente_nuevo', 'especie', v_datos, p_usuario_id);
        v_vista := bot_cli_alta_vista('especie', v_datos);

      ELSE
        RETURN NULL;
    END CASE;

  -- --- Captura de la consulta ---------------------------------------
  ELSE
    IF v_paso = 'paciente' THEN
      PERFORM exigir_permiso(p_usuario_id, 'pacientes.ver');
      v_vista := bot_cli_resultados_paciente(p_texto, 'pac');

    ELSIF v_consulta IS NULL THEN
      RETURN NULL;

    ELSIF v_paso = 'adenda' THEN
      v_r := agregar_adenda(p_usuario_id, v_consulta, p_texto);
      IF (v_r->>'ok')::boolean THEN
        PERFORM estado_limpiar(p_chat_id);
        v_vista := bot_cli_resumen(v_consulta);
      ELSE
        v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
      END IF;

    ELSIF v_paso = 'examen_valor' THEN
      v_r := guardar_examen(p_usuario_id, v_consulta, v_datos->>'examen_clave', p_texto);
      IF (v_r->>'ok')::boolean THEN
        PERFORM estado_guardar(p_chat_id, 'consulta', 'examen', v_datos, p_usuario_id);
        v_vista := bot_cli_examen(v_consulta);
      ELSE
        v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje') ||
          E'\n' || 'Escríbelo otra vez.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver al examen', 'd', 'cli:paso:examen'))));
      END IF;

    ELSE
      -- Pasos narrativos: el nombre del paso dice en qué columna va.
      v_campo := CASE v_paso
                   WHEN 'motivo'          THEN 'motivo_consulta'
                   WHEN 'anamnesis'       THEN 'anamnesis'
                   WHEN 'diagnostico'     THEN 'diagnostico_presuntivo'
                   WHEN 'tratamiento'     THEN 'plan_tratamiento'
                   WHEN 'recomendaciones' THEN 'recomendaciones'
                   WHEN 'remision'        THEN 'remision_externa'
                   ELSE NULL
                 END;

      IF v_campo IS NULL THEN
        RETURN NULL;
      END IF;

      v_r := guardar_consulta(p_usuario_id, v_consulta, v_campo, p_texto);

      IF NOT (v_r->>'ok')::boolean THEN
        v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '📄 Ver resumen', 'd', 'cli:paso:resumen'),
            jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
      ELSE
        v_paso := bot_cli_siguiente_paso(v_paso);
        PERFORM estado_guardar(p_chat_id, 'consulta', v_paso, v_datos, p_usuario_id);
        v_vista := bot_cli_vista_paso(v_consulta, v_paso);
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('acciones', jsonb_build_array(
    accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;

-- ---------------------------------------------------------------------
-- Despachadores: se añade el módulo clínico a los de 046
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_cli_menu(p_usuario_id) || bot_inv_menu(p_usuario_id);
$$;

CREATE OR REPLACE FUNCTION bot_modulo_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_inv_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_cli_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_modulo_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_inv_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cli_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id));
$$;
