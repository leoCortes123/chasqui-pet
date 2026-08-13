-- =====================================================================
-- Chasqui Pet — 170_agenda_canales.sql
-- Ámbito: VERTICAL (agenda de citas; convención de cabecera, Fase A7a).
--
-- Fase B1b: la agenda que `160_agenda.sql` puso en pie sale a los canales.
-- Aquí NO hay reglas de negocio nuevas: todo lo que sigue traduce la
-- misma docena de funciones a cuatro formas de usarlas.
--
--   1. **Recordatorio y no-asistencia** — las dos funciones que corre el
--      job programado (n8n `05-job-agenda.json`, 18:00). Son del mismo
--      tipo que `mantenimiento_diario()` o `bloquear_lotes_vencidos()`:
--      las llama el sistema, no una persona, y por eso no exigen permiso.
--      Lo que sí respetan es la Ley 1581 (§12): no se le escribe a un
--      dueño que no autorizó el contacto.
--
--   2. **Módulo del bot** (`bot_age_*`) — ver la agenda del día, registrar
--      la llegada, agendar, reprogramar y cancelar desde Telegram. Los
--      cupos ofrecidos se guardan en `conversacion_estado` y el botón
--      lleva su índice: `callback_data` son 64 bytes y una fecha con
--      veterinario no cabe.
--
--   3. **Asistente** — tres herramientas: dos lecturas y una escritura
--      con confirmación humana (C6.9). La escritura pasa por un borrador
--      propio, como las otras seis que normalizan lenguaje de mostrador;
--      así no hay que tocar `ia_resumen_accion`.
--
--   4. **Portal** — no necesita SQL nuevo: `agenda_del_dia`,
--      `horarios_disponibles` y las funciones de escritura le bastan.
-- =====================================================================

SET client_min_messages = warning;

INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('agenda_gracia_no_asistio_min', '60', 'entero',
   'Minutos de gracia tras la hora de la cita antes de marcarla como no asistió', true)
ON CONFLICT (clave) DO NOTHING;


-- =====================================================================
-- 1. Lo que corre solo
-- =====================================================================

-- ---------------------------------------------------------------------
-- agenda_recordatorios — un aviso por cita, el día antes
--
-- `recordatorio_enviado_at` es la reja: una cita avisada no se vuelve a
-- avisar aunque el job corra dos veces. Se marca en la MISMA sentencia
-- que selecciona (UPDATE … RETURNING), así que dos corridas simultáneas
-- no pueden encolar el mismo aviso.
--
-- Ley 1581 (§12): solo se le escribe a quien autorizó el contacto y tiene
-- chat vinculado. Se filtra aquí para no encolar lo que no se puede
-- enviar, y el worker (`enviar_aviso_dueno.js`) lo vuelve a comprobar en
-- el momento del envío, porque el consentimiento puede retirarse entre
-- una cosa y la otra. Ninguna de las dos capas sustituye a la otra.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION agenda_recordatorios(p_dias int DEFAULT 1)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_fecha    date := hoy_bogota() + GREATEST(COALESCE(p_dias, 1), 0);
  v_encolados int := 0;
  v_sin_canal int;
  r          record;
BEGIN
  -- Sin canal: se cuentan para que el reporte diga la verdad («había 7
  -- citas, se avisaron 5»), pero no se marcan como avisadas — si el dueño
  -- da su consentimiento hoy, mañana sí recibe el recordatorio.
  SELECT count(*) INTO v_sin_canal
    FROM cita c
    LEFT JOIN dueno d ON d.id = c.dueno_id
   WHERE c.estado IN ('programada','confirmada')
     AND (c.inicio_at AT TIME ZONE 'America/Bogota')::date = v_fecha
     AND c.recordatorio_enviado_at IS NULL
     AND (d.id IS NULL OR NOT d.consentimiento_datos OR d.telegram_chat_id IS NULL);

  FOR r IN
    UPDATE cita c
       SET recordatorio_enviado_at = now()
      FROM dueno d, paciente p
     WHERE d.id = c.dueno_id
       AND p.id = c.paciente_id
       AND c.estado IN ('programada','confirmada')
       AND (c.inicio_at AT TIME ZONE 'America/Bogota')::date = v_fecha
       AND c.recordatorio_enviado_at IS NULL
       AND d.consentimiento_datos
       AND d.telegram_chat_id IS NOT NULL
    RETURNING c.id AS cita_id, c.dueno_id, c.inicio_at, p.nombre AS mascota
  LOOP
    PERFORM encolar_tarea(
      'enviar_aviso_dueno',
      jsonb_build_object(
        'dueno_id', r.dueno_id,
        'mensaje', format(
          'Le recordamos la cita de %s: %s a las %s. Si no puede asistir, avísenos por aquí.',
          r.mascota,
          to_char(r.inicio_at AT TIME ZONE 'America/Bogota', 'DD/MM/YYYY'),
          to_char(r.inicio_at AT TIME ZONE 'America/Bogota', 'HH24:MI'))),
      5,
      'recordatorio_cita_' || r.cita_id::text,   -- idempotencia también en la cola
      0, 3);

    PERFORM auditar('cita', r.cita_id::text, 'recordar', NULL, 'sistema', NULL,
                    jsonb_build_object('dueno_id', r.dueno_id));
    v_encolados := v_encolados + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'fecha', v_fecha,
    'encolados', v_encolados, 'sin_canal', v_sin_canal);
END;
$$;

COMMENT ON FUNCTION agenda_recordatorios(int) IS
  'Encola el recordatorio de las citas de dentro de N días. Idempotente por recordatorio_enviado_at (Fase B1b).';

-- ---------------------------------------------------------------------
-- agenda_marcar_no_asistio — cerrar el día
--
-- Una cita que pasó su hora con margen y nunca generó turno es una
-- inasistencia. Marcarla importa para dos cosas: dejar de contarla como
-- pendiente y poder medir después cuánta gente no viene.
--
-- Solo mira días ya pasados o la hora ya vencida: nunca toca una cita del
-- futuro.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION agenda_marcar_no_asistio()
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_gracia int := config_int('agenda_gracia_no_asistio_min', 60);
  v_n      int := 0;
  r        record;
BEGIN
  FOR r IN
    UPDATE cita
       SET estado = 'no_asistio'
     WHERE estado IN ('programada','confirmada')
       AND turno_id IS NULL
       AND fin_at + make_interval(mins => v_gracia) < now()
    RETURNING id
  LOOP
    PERFORM auditar('cita', r.id::text, 'no_asistio', NULL, 'sistema', NULL,
                    jsonb_build_object('gracia_min', v_gracia));
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'marcadas', v_n);
END;
$$;

GRANT EXECUTE ON FUNCTION agenda_recordatorios(int)      TO chasquipet_app;
GRANT EXECUTE ON FUNCTION agenda_marcar_no_asistio()     TO chasquipet_app;


-- =====================================================================
-- 2. El bot
-- =====================================================================

-- ---------------------------------------------------------------------
-- Botón propio en el menú principal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_age_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_fila jsonb := '[]'::jsonb; v_n int;
BEGIN
  IF NOT tiene_permiso(p_usuario_id, 'agenda.ver') THEN
    RETURN '[]'::jsonb;
  END IF;

  -- El número de citas de hoy va en el botón: es el dato que se mira de
  -- reojo, y ahorra entrar a la sección para descubrir que está vacía.
  SELECT count(*) INTO v_n
    FROM cita c
    JOIN usuario u ON u.id = p_usuario_id
   WHERE c.sede_id = COALESCE(u.sede_id, c.sede_id)
     AND (c.inicio_at AT TIME ZONE 'America/Bogota')::date = hoy_bogota()
     AND c.estado IN ('programada','confirmada');

  v_fila := v_fila || jsonb_build_object(
    't', '📅 Agenda' || CASE WHEN v_n > 0 THEN ' (' || v_n || ')' ELSE '' END,
    'd', 'age:dia:' || hoy_bogota()::text);

  RETURN jsonb_build_array(v_fila);
END;
$$;

-- ---------------------------------------------------------------------
-- Vista: la agenda de un día
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_age_dia(p_usuario_id uuid, p_sede_id uuid, p_fecha date)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_r     jsonb;
  v_texto text;
  v_bot   jsonb := '[]'::jsonb;
  c       jsonb;
BEGIN
  v_r := agenda_del_dia(p_usuario_id, p_sede_id, p_fecha);

  v_texto := '📅 <b>Agenda</b> · ' || to_char(p_fecha, 'DD/MM/YYYY') ||
             CASE WHEN p_fecha = hoy_bogota() THEN ' (hoy)'
                  WHEN p_fecha = hoy_bogota() + 1 THEN ' (mañana)'
                  ELSE '' END;

  IF jsonb_array_length(v_r->'citas') = 0 THEN
    v_texto := v_texto || E'\n' || 'No hay citas ese día.';
  END IF;

  FOR c IN SELECT * FROM jsonb_array_elements(v_r->'citas') LOOP
    v_texto := v_texto || E'\n' ||
      CASE c->>'estado'
        WHEN 'cumplida'  THEN '✅'
        WHEN 'cancelada' THEN '✖️'
        WHEN 'no_asistio' THEN '🚫'
        WHEN 'confirmada' THEN '☑️'
        ELSE '🕐' END ||
      ' <b>' || esc(c->>'hora') || '</b> · ' ||
      esc(COALESCE(c->'paciente'->>'nombre', 'sin mascota')) ||
      COALESCE(' (' || esc(c->>'dueno') || ')', '') ||
      COALESCE(' · ' || esc(c->>'veterinario'), '');

    -- Solo lo que todavía se puede tocar lleva botón: una cita cumplida o
    -- cancelada se lee, no se opera.
    IF c->>'estado' IN ('programada','confirmada') THEN
      v_bot := v_bot || jsonb_build_array(jsonb_build_object(
        't', (c->>'hora') || ' · ' || COALESCE(c->'paciente'->>'nombre', 'cita'),
        'd', 'age:cita:' || (c->>'cita_id')));
    END IF;
  END LOOP;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '◀️', 'd', 'age:dia:' || (p_fecha - 1)::text),
    jsonb_build_object('t', '📆 Hoy', 'd', 'age:dia:' || hoy_bogota()::text),
    jsonb_build_object('t', '▶️', 'd', 'age:dia:' || (p_fecha + 1)::text)));

  IF tiene_permiso(p_usuario_id, 'agenda.gestionar') THEN
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '➕ Agendar cita', 'd', 'age:nueva')));
  END IF;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '⬅️ Menú', 'd', 'age:salir')));

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_bot);
END;
$$;

-- ---------------------------------------------------------------------
-- Vista: una cita y lo que se puede hacer con ella
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_age_cita(p_cita_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  j     jsonb := cita_json(p_cita_id);
  v_bot jsonb := '[]'::jsonb;
  v_dia date;
BEGIN
  IF j IS NULL THEN
    RETURN jsonb_build_object('texto', '⚠️ Esa cita ya no existe.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'age:salir'))));
  END IF;

  v_dia := (j->>'fecha')::date;

  IF tiene_permiso(p_usuario_id, 'agenda.gestionar')
     AND j->>'estado' IN ('programada','confirmada') THEN
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '✅ Llegó', 'd', 'age:llego:' || p_cita_id),
      jsonb_build_object('t', '🕐 Reprogramar', 'd', 'age:reprog:' || p_cita_id)));
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '✖️ Cancelar cita', 'd', 'age:cancel:' || p_cita_id)));
  END IF;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '⬅️ Agenda', 'd', 'age:dia:' || v_dia::text)));

  RETURN jsonb_build_object('texto',
    '📅 <b>Cita</b> · ' || esc(j->>'tipo_nombre') || E'\n' ||
    '🗓 ' || to_char(v_dia, 'DD/MM/YYYY') || ' a las <b>' || esc(j->>'hora') || '</b>' ||
    ' (' || (j->>'duracion_min') || ' min)' || E'\n' ||
    '🐾 ' || esc(COALESCE(j->'paciente'->>'nombre', 'sin mascota')) ||
    COALESCE(' · ' || esc(j->>'dueno'), '') ||
    COALESCE(E'\n' || '👤 ' || esc(j->>'veterinario'), '') ||
    E'\n' || 'Estado: <b>' || esc(j->>'estado') || '</b>' ||
    COALESCE(E'\n' || '📝 ' || esc(j->>'notas'), '') ||
    CASE WHEN j->>'turno' IS NOT NULL
         THEN E'\n' || '🎫 Turno <b>' || esc(j->>'turno') || '</b>' ELSE '' END,
    'botones', v_bot);
END;
$$;

-- ---------------------------------------------------------------------
-- Vista: cupos libres de un día, como botones
--
-- Los cupos se guardan en el estado de la conversación y el botón lleva
-- su ÍNDICE, no la fecha ni el veterinario: `callback_data` admite 64
-- bytes y un timestamptz con un uuid no cabe.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_age_cupos(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_fecha date, p_mensaje_id bigint)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_r     jsonb;
  v_slots jsonb;
  v_bot   jsonb := '[]'::jsonb;
  v_fila  jsonb := '[]'::jsonb;
  v_i     int := 0;
  s       jsonb;
BEGIN
  v_r := horarios_disponibles(p_usuario_id, p_sede_id, p_fecha, 'general');
  v_slots := COALESCE(v_r->'slots', '[]'::jsonb);

  -- Máximo 12 cupos: más botones que eso no se leen en un celular. El
  -- resto se alcanza escribiendo la hora.
  FOR s IN SELECT * FROM jsonb_array_elements(v_slots) LIMIT 12 LOOP
    v_fila := v_fila || jsonb_build_object('t', s->>'hora', 'd', 'age:slot:' || v_i);
    v_i := v_i + 1;
    IF jsonb_array_length(v_fila) = 3 THEN
      v_bot := v_bot || jsonb_build_array(v_fila);
      v_fila := '[]'::jsonb;
    END IF;
  END LOOP;
  IF jsonb_array_length(v_fila) > 0 THEN v_bot := v_bot || jsonb_build_array(v_fila); END IF;

  PERFORM estado_guardar(p_chat_id, 'agenda', 'cupo',
            jsonb_build_object('fecha', p_fecha, 'slots', v_slots),
            p_usuario_id, p_mensaje_id);

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '◀️', 'd', 'age:fecha:' || (p_fecha - 1)::text),
    jsonb_build_object('t', '▶️', 'd', 'age:fecha:' || (p_fecha + 1)::text)));
  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '🚫 Cancelar', 'd', 'age:salir')));

  RETURN jsonb_build_object('texto',
    '🕐 <b>Cupos del ' || to_char(p_fecha, 'DD/MM/YYYY') || '</b>' || E'\n' ||
    CASE WHEN jsonb_array_length(v_slots) = 0
         THEN 'No hay cupos libres declarados ese día.' || E'\n' ||
              'Escribe la hora (por ejemplo <b>15:30</b>) para agendar de todos modos.'
         ELSE 'Elige un cupo o escribe la hora que necesites (por ejemplo <b>15:30</b>).' END,
    'botones', v_bot);
END;
$$;

-- ---------------------------------------------------------------------
-- Callbacks del módulo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_age_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_partes text[] := string_to_array(p_data, ':');
  v_estado jsonb  := estado_leer(p_chat_id);
  v_datos  jsonb  := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_vista  jsonb;
  v_alerta text := NULL;
  v_r      jsonb;
  v_fecha  date;
  v_slot   jsonb;
BEGIN
  IF v_partes[1] IS DISTINCT FROM 'age' THEN
    RETURN NULL;    -- no es nuestro: que siga el enrutador
  END IF;

  CASE v_partes[2]

    WHEN 'dia' THEN
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_age_dia(p_usuario_id, p_sede_id, v_partes[3]::date);

    WHEN 'cita' THEN
      v_vista := bot_age_cita(v_partes[3]::uuid, p_usuario_id);

    WHEN 'llego' THEN
      v_r := confirmar_asistencia(p_usuario_id, v_partes[3]::uuid, 'telegram');
      IF (v_r->>'ok')::boolean THEN
        v_alerta := 'Turno ' || COALESCE(v_r->'turno'->>'codigo', 'creado');
      ELSE
        v_alerta := v_r->>'mensaje';
      END IF;
      v_vista := bot_age_cita(v_partes[3]::uuid, p_usuario_id);

    WHEN 'cancel' THEN
      PERFORM exigir_permiso(p_usuario_id, 'agenda.gestionar');
      PERFORM estado_guardar(p_chat_id, 'agenda', 'motivo_cancelar',
                jsonb_build_object('cita_id', v_partes[3]), p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '✖️ <b>Cancelar la cita</b>' || E'\n' ||
        'Escribe por qué se cancela. Queda registrado con la cita.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'age:cita:' || v_partes[3]))));

    WHEN 'reprog' THEN
      PERFORM exigir_permiso(p_usuario_id, 'agenda.gestionar');
      PERFORM estado_guardar(p_chat_id, 'agenda', 'reprogramar',
                jsonb_build_object('cita_id', v_partes[3]), p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '🕐 <b>Reprogramar</b>' || E'\n' ||
        'Escribe la fecha y hora nuevas: <b>AAAA-MM-DD HH:MM</b>, o solo <b>HH:MM</b> ' ||
        'para dejarla el mismo día.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'age:cita:' || v_partes[3]))));

    -- --- Agendar: paciente → fecha → cupo ---------------------------
    WHEN 'nueva' THEN
      PERFORM exigir_permiso(p_usuario_id, 'agenda.gestionar');
      PERFORM estado_guardar(p_chat_id, 'agenda', 'paciente', '{}'::jsonb,
                             p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '➕ <b>Agendar cita</b>' || E'\n' ||
        'Escribe el nombre de la mascota, del dueño o el teléfono.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '🚫 Cancelar', 'd', 'age:salir'))));

    WHEN 'pac' THEN
      PERFORM estado_guardar(p_chat_id, 'agenda', 'fecha',
                jsonb_build_object('paciente_id', v_partes[3]), p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '📆 <b>¿Qué día?</b>' || E'\n' ||
        'Elige uno o escribe la fecha (<b>AAAA-MM-DD</b>).',
        'botones', jsonb_build_array(
          jsonb_build_array(
            jsonb_build_object('t', 'Mañana', 'd', 'age:fecha:' || (hoy_bogota() + 1)::text),
            jsonb_build_object('t', 'En 2 días', 'd', 'age:fecha:' || (hoy_bogota() + 2)::text),
            jsonb_build_object('t', 'En 8 días', 'd', 'age:fecha:' || (hoy_bogota() + 8)::text)),
          jsonb_build_array(
            jsonb_build_object('t', 'Hoy', 'd', 'age:fecha:' || hoy_bogota()::text),
            jsonb_build_object('t', '🚫 Cancelar', 'd', 'age:salir'))));

    WHEN 'fecha' THEN
      v_fecha := v_partes[3]::date;
      v_vista := bot_age_cupos(p_usuario_id, p_chat_id, p_sede_id, v_fecha, p_mensaje_id);

    WHEN 'slot' THEN
      v_slot := (v_datos->'slots')->(v_partes[3]::int);
      IF v_slot IS NULL THEN
        v_alerta := 'Ese cupo ya no está en pantalla. Elige el día otra vez.';
        v_vista := bot_age_dia(p_usuario_id, p_sede_id, hoy_bogota());
      ELSE
        v_r := crear_cita(p_usuario_id, jsonb_build_object(
                 'paciente_id',    v_datos->>'paciente_id',
                 'veterinario_id', v_slot->>'veterinario_id',
                 'consultorio_id', v_slot->>'consultorio_id',
                 'sede_id',        p_sede_id,
                 'inicio',         v_slot->>'inicio'), 'telegram');
        IF (v_r->>'ok')::boolean THEN
          PERFORM estado_limpiar(p_chat_id);
          v_alerta := 'Cita agendada';
          v_vista := bot_age_cita((v_r->'cita'->>'cita_id')::uuid, p_usuario_id);
        ELSE
          v_alerta := v_r->>'mensaje';
          v_vista := bot_age_cupos(p_usuario_id, p_chat_id, p_sede_id,
                                   (v_datos->>'fecha')::date, p_mensaje_id);
        END IF;
      END IF;

    WHEN 'salir' THEN
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
-- Texto del módulo: el comando /agenda y las respuestas del flujo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_age_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado jsonb := estado_leer(p_chat_id);
  v_flujo  text  := v_estado->>'flujo';
  v_paso   text  := v_estado->>'paso';
  v_datos  jsonb := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_msg_id bigint := (v_estado->>'mensaje_id')::bigint;
  v_vista  jsonb;
  v_r      jsonb;
  v_bot    jsonb;
  v_n      int;
  v_fecha  date;
  v_hora   time;
  v_cita   uuid;
BEGIN
  -- Comando suelto, sin pasar por el menú.
  IF p_texto IN ('/agenda', 'agenda') AND tiene_permiso(p_usuario_id, 'agenda.ver') THEN
    PERFORM estado_limpiar(p_chat_id);
    v_vista := bot_age_dia(p_usuario_id, p_sede_id, hoy_bogota());
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
  END IF;

  IF v_flujo IS DISTINCT FROM 'agenda' THEN
    RETURN NULL;   -- no es nuestro
  END IF;

  CASE v_paso

    -- Búsqueda de la mascota para la cita nueva.
    WHEN 'paciente' THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_array(jsonb_build_object(
               't', emoji_especie(especie) || ' ' || nombre ||
                    COALESCE(' · ' || dueno, ' · sin dueño'),
               'd', 'age:pac:' || paciente_id)) ORDER BY puntaje DESC), '[]'::jsonb),
             count(*)
        INTO v_bot, v_n
        FROM buscar_paciente(p_texto, 5);

      IF v_n = 0 THEN
        v_vista := jsonb_build_object('texto',
          '🔎 Sin resultados para «' || esc(p_texto) || '».' || E'\n' ||
          'Prueba con otro nombre o teléfono.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '🚫 Cancelar', 'd', 'age:salir'))));
      ELSE
        v_vista := jsonb_build_object('texto',
          '🐾 <b>¿Para cuál mascota?</b>',
          'botones', v_bot || jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '🚫 Cancelar', 'd', 'age:salir'))));
      END IF;

    -- Fecha escrita a mano en vez de elegida con botón.
    WHEN 'fecha' THEN
      BEGIN
        v_fecha := p_texto::date;
      EXCEPTION WHEN others THEN v_fecha := NULL;
      END;

      IF v_fecha IS NULL THEN
        v_vista := jsonb_build_object('texto',
          '⚠️ «' || esc(p_texto) || '» no es una fecha. Escríbela como <b>AAAA-MM-DD</b>.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '🚫 Cancelar', 'd', 'age:salir'))));
      ELSE
        v_vista := bot_age_cupos(p_usuario_id, p_chat_id, p_sede_id, v_fecha, v_msg_id);
      END IF;

    -- Hora escrita a mano estando en la pantalla de cupos: se agenda
    -- fuera de la franja, que es una decisión legítima del mostrador.
    WHEN 'cupo' THEN
      BEGIN
        v_hora := p_texto::time;
      EXCEPTION WHEN others THEN v_hora := NULL;
      END;

      IF v_hora IS NULL THEN
        v_vista := jsonb_build_object('texto',
          '⚠️ «' || esc(p_texto) || '» no es una hora. Escríbela como <b>15:30</b>.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '🚫 Cancelar', 'd', 'age:salir'))));
      ELSE
        v_r := crear_cita(p_usuario_id, jsonb_build_object(
                 'paciente_id', v_datos->>'paciente_id',
                 'sede_id',     p_sede_id,
                 'inicio',      (v_datos->>'fecha') || ' ' || to_char(v_hora, 'HH24:MI')),
                 'telegram');
        IF (v_r->>'ok')::boolean THEN
          PERFORM estado_limpiar(p_chat_id);
          v_vista := bot_age_cita((v_r->'cita'->>'cita_id')::uuid, p_usuario_id);
        ELSE
          v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
            'botones', jsonb_build_array(jsonb_build_array(
              jsonb_build_object('t', '🚫 Cancelar', 'd', 'age:salir'))));
        END IF;
      END IF;

    WHEN 'motivo_cancelar' THEN
      v_cita := (v_datos->>'cita_id')::uuid;
      v_r := cancelar_cita(p_usuario_id, v_cita, p_texto, 'telegram');
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_age_cita(v_cita, p_usuario_id);
      IF NOT (v_r->>'ok')::boolean THEN
        v_vista := jsonb_set(v_vista, '{texto}',
          to_jsonb('⚠️ ' || esc(v_r->>'mensaje') || E'\n\n' || (v_vista->>'texto')));
      END IF;

    WHEN 'reprogramar' THEN
      v_cita := (v_datos->>'cita_id')::uuid;

      -- Solo la hora: se conserva el día que ya tenía la cita.
      IF p_texto ~ '^\s*[0-9]{1,2}:[0-9]{2}\s*$' THEN
        SELECT (inicio_at AT TIME ZONE 'America/Bogota')::date INTO v_fecha
          FROM cita WHERE id = v_cita;
        v_r := reprogramar_cita(p_usuario_id, v_cita,
                 v_fecha::text || ' ' || trim(p_texto), NULL, NULL, 'telegram');
      ELSE
        v_r := reprogramar_cita(p_usuario_id, v_cita, p_texto, NULL, NULL, 'telegram');
      END IF;

      IF (v_r->>'ok')::boolean THEN
        PERFORM estado_limpiar(p_chat_id);
        v_vista := bot_age_cita(v_cita, p_usuario_id);
      ELSE
        v_vista := jsonb_build_object('texto',
          '⚠️ ' || esc(COALESCE(v_r->>'mensaje', 'No se pudo reprogramar.')) || E'\n' ||
          'Escribe la fecha y hora como <b>AAAA-MM-DD HH:MM</b>.',
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'age:cita:' || v_cita))));
      END IF;

    ELSE
      RETURN NULL;
  END CASE;

  RETURN jsonb_build_object('acciones', jsonb_build_array(
    accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;


-- =====================================================================
-- 3. El asistente
--
-- Dos lecturas y una escritura. La escritura pasa por un borrador propio
-- —como las otras seis herramientas que normalizan lenguaje de
-- mostrador— y por eso no hay que tocar `ia_resumen_accion`: el borrador
-- arma su propia tarjeta y deja la propuesta en `ia_accion_pendiente`.
-- La confirmación humana sigue siendo obligatoria (C6.9).
-- =====================================================================

CREATE OR REPLACE FUNCTION op_agenda_del_dia(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'datos',
    COALESCE(agenda_del_dia(p_actor, p_sede, NULLIF(p_args->>'fecha', '')::date,
                            NULLIF(p_args->>'veterinario_id', '')::uuid), 'null'::jsonb));
$$;

CREATE OR REPLACE FUNCTION op_horarios_disponibles(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'datos',
    COALESCE(horarios_disponibles(p_actor, p_sede,
               COALESCE(NULLIF(p_args->>'fecha', '')::date, hoy_bogota()),
               COALESCE(NULLIF(p_args->>'tipo', ''), 'general'),
               NULLIF(p_args->>'veterinario_id', '')::uuid), 'null'::jsonb));
$$;

-- El ejecutor: se llama DESPUÉS de que la persona confirma.
--
-- Enriquece el `mensaje` en vez de agregarle una rama a
-- `ia_texto_resultado`: esa función antepone `mensaje` a cualquier rama
-- suya (`COALESCE(NULLIF(esc(p_resultado->>'mensaje'), ''), CASE …)`), así
-- que una rama nueva ahí sería código muerto. El lugar donde el resultado
-- se adapta al asistente es este envoltorio.
CREATE OR REPLACE FUNCTION op_agendar_cita(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  v := crear_cita(p_actor, p_args || jsonb_build_object('sede_id', p_sede), 'telegram');

  IF (v->>'ok')::boolean THEN
    v := v || jsonb_build_object('mensaje', format(
      'Cita agendada para %s el %s a las %s.',
      COALESCE(v->'cita'->'paciente'->>'nombre', 'la mascota'),
      to_char((v->'cita'->>'fecha')::date, 'DD/MM/YYYY'),
      v->'cita'->>'hora'));
  END IF;

  RETURN v;
END;
$$;

-- ---------------------------------------------------------------------
-- El borrador: convierte «agéndame a Luna el martes a las 10» en una
-- tarjeta que se puede revisar antes de tocar el botón.
--
-- Nada de lo que decide el modelo se acepta a ciegas: el paciente sale de
-- `buscar_paciente` (el modelo pasa su `paciente_id`), la hora se
-- interpreta con `agenda_instante` y el choque lo sigue decidiendo la
-- restricción EXCLUDE al ejecutar. Lo que hace el borrador es AVISAR de
-- lo que se ve venir —horario ocupado, franja bloqueada— para no gastar
-- un toque de botón en algo que va a fallar.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_agenda_borrador(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_pac     uuid := NULLIF(p_args->>'paciente_id', '')::uuid;
  v_inicio  timestamptz := agenda_instante(p_args->>'inicio');
  v_tipo    tipo_servicio;
  v_vet     uuid := NULLIF(p_args->>'veterinario_id', '')::uuid;
  v_dur     int;
  v_fin     timestamptz;
  v_pacnom  text;
  v_dueno   text;
  v_aviso   text := '';
  v_resumen text;
  v_accion  uuid;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'agenda.gestionar');

  IF v_pac IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta la mascota. Usa buscar_paciente y pasa su paciente_id.');
  END IF;

  SELECT p.nombre, d.nombre_completo INTO v_pacnom, v_dueno
    FROM paciente p LEFT JOIN dueno d ON d.id = p.dueno_id
   WHERE p.id = v_pac AND p.estado = 'activo';
  IF v_pacnom IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Esa mascota no existe o está inactiva.');
  END IF;

  IF v_inicio IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta la fecha y hora. Escríbela como AAAA-MM-DD HH:MM en hora de Bogotá. '
      'Si no sabes qué cupos hay, consulta horarios_disponibles primero.');
  END IF;

  IF v_inicio <= now() THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Esa fecha y hora ya pasó. Pregunta al usuario cuándo quiere la cita.');
  END IF;

  SELECT * INTO v_tipo FROM tipo_servicio
   WHERE codigo = COALESCE(NULLIF(p_args->>'tipo', ''), 'general') AND activo;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Ese tipo de servicio no existe. Consulta informacion_clinica para ver los válidos.');
  END IF;

  v_dur := v_tipo.duracion_estimada_min;
  v_fin := v_inicio + make_interval(mins => v_dur);

  -- Lo que se ve venir se dice antes de confirmar, no después.
  IF EXISTS (SELECT 1 FROM cita c
              WHERE c.veterinario_id = v_vet AND v_vet IS NOT NULL
                AND c.estado IN ('programada','confirmada')
                AND tstzrange(c.inicio_at, c.fin_at, '[)') && tstzrange(v_inicio, v_fin, '[)')) THEN
    v_aviso := v_aviso || E'\n' || '🚫 Ese veterinario ya tiene una cita a esa hora: esto va a fallar.';
  END IF;

  IF EXISTS (SELECT 1 FROM bloqueo_agenda b
              WHERE b.activo AND b.sede_id = p_sede_id
                AND (b.veterinario_id IS NULL OR b.veterinario_id = v_vet)
                AND tstzrange(b.inicio_at, b.fin_at, '[)') && tstzrange(v_inicio, v_fin, '[)')) THEN
    v_aviso := v_aviso || E'\n' || '🚫 Esa franja está bloqueada en la agenda: esto va a fallar.';
  END IF;

  v_resumen := '📅 <b>Agendar cita</b>' || E'\n' ||
               '🐾 ' || esc(v_pacnom) || COALESCE(' · ' || esc(v_dueno), '') || E'\n' ||
               '🗓 <b>' || to_char(v_inicio AT TIME ZONE 'America/Bogota', 'DD/MM/YYYY') ||
               ' a las ' || to_char(v_inicio AT TIME ZONE 'America/Bogota', 'HH24:MI') ||
               '</b> (' || v_dur || ' min)' || E'\n' ||
               '🩺 ' || esc(v_tipo.nombre) ||
               COALESCE(E'\n' || '👤 ' ||
                 esc((SELECT nombre_completo FROM usuario WHERE id = v_vet)), '') ||
               CASE WHEN NULLIF(p_args->>'notas', '') IS NOT NULL
                    THEN E'\n' || '📝 ' || esc(p_args->>'notas') ELSE '' END ||
               v_aviso;

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, 'agendar_cita',
          jsonb_build_object(
            'paciente_id',    v_pac,
            'veterinario_id', v_vet,
            'tipo',           v_tipo.codigo,
            'inicio',         to_char(v_inicio AT TIME ZONE 'America/Bogota',
                                      'YYYY-MM-DD HH24:MI'),
            'notas',          NULLIF(p_args->>'notas', '')),
          v_resumen)
  RETURNING id INTO v_accion;

  RETURN jsonb_build_object('ok', true, 'requiere_confirmacion', true,
    'accion_id', v_accion, 'critica', false, 'resumen', v_resumen);
END;
$$;

-- ---------------------------------------------------------------------
-- El catálogo
-- ---------------------------------------------------------------------
INSERT INTO ia_herramienta (nombre, permiso, escribe, critica, orden, descripcion, esquema) VALUES

('agenda_del_dia', 'agenda.ver', false, false, 75,
 'Citas agendadas de un día: hora, mascota, dueño, veterinario y estado (programada, '
 'confirmada, cumplida, cancelada o no asistió). Sin fecha, es el día de hoy. Úsala para '
 '«qué citas hay», «quién viene mañana», «cómo está la agenda».',
 '{"type":"object","properties":{"fecha":{"type":"string","description":"Fecha AAAA-MM-DD. Omitir para hoy."},"veterinario_id":{"type":"string","description":"Filtrar por un veterinario. Omitir para toda la sede."}}}'::jsonb),

('horarios_disponibles', 'agenda.ver', false, false, 76,
 'Cupos libres para agendar en un día: hora de inicio, veterinario y consultorio. '
 'Descuenta las citas ya tomadas y las franjas bloqueadas. Úsala ANTES de agendar_cita '
 'cuando el usuario no dijo una hora exacta, y para responder «a qué horas hay».',
 '{"type":"object","properties":{"fecha":{"type":"string","description":"Fecha AAAA-MM-DD. Omitir para hoy."},"tipo":{"type":"string","description":"Código del tipo de servicio: general, vacunacion, control, urgencia. Por defecto general."},"veterinario_id":{"type":"string","description":"Filtrar por un veterinario."}}}'::jsonb),

('agendar_cita', 'agenda.gestionar', true, false, 77,
 'Agenda una cita para una mascota. Necesita el paciente_id (búscalo antes con '
 'buscar_paciente) y la fecha y hora en formato AAAA-MM-DD HH:MM, en hora de Bogotá. '
 'Si el usuario no dijo una hora exacta, consulta horarios_disponibles y ofrécele las '
 'opciones antes de proponer. NO ejecuta nada: deja una propuesta que la persona '
 'confirma con un botón.',
 '{"type":"object","properties":{"paciente_id":{"type":"string","description":"UUID de la mascota, obtenido de buscar_paciente"},"inicio":{"type":"string","description":"Fecha y hora AAAA-MM-DD HH:MM en hora de Bogotá"},"tipo":{"type":"string","description":"Código del tipo de servicio: general, vacunacion, control, urgencia. Por defecto general."},"veterinario_id":{"type":"string","description":"UUID del veterinario, si el usuario pidió uno"},"notas":{"type":"string","description":"Motivo o nota corta de la cita"}},"required":["paciente_id","inicio"]}'::jsonb)

ON CONFLICT (nombre) DO NOTHING;

-- El registro declarativo de la Fase A5: qué función atiende cada una.
UPDATE ia_herramienta h
   SET funcion = r.funcion, funcion_borrador = r.borrador, modulo = r.modulo
  FROM (VALUES
    ('agenda_del_dia',       'op_agenda_del_dia',       NULL,                 'agenda'),
    ('horarios_disponibles', 'op_horarios_disponibles', NULL,                 'agenda'),
    ('agendar_cita',         'op_agendar_cita',         'ia_agenda_borrador', 'agenda')
  ) AS r(nombre, funcion, borrador, modulo)
 WHERE h.nombre = r.nombre;

-- `ia_texto_resultado` NO se toca. Antepone el `mensaje` del resultado a
-- cualquier rama propia, y `op_agendar_cita` ya devuelve el mensaje
-- completo: una rama nueva ahí no se ejecutaría nunca. Reemplazar una
-- función de enganche de 50 líneas para agregarle código muerto es
-- exactamente el riesgo que la regla de «cambio aditivo» quiere evitar.

GRANT EXECUTE ON FUNCTION agenda_recordatorios(int)                       TO chasquipet_app;
GRANT EXECUTE ON FUNCTION op_agenda_del_dia(uuid, uuid, jsonb)            TO chasquipet_app;
GRANT EXECUTE ON FUNCTION op_horarios_disponibles(uuid, uuid, jsonb)      TO chasquipet_app;
GRANT EXECUTE ON FUNCTION op_agendar_cita(uuid, uuid, jsonb)              TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_agenda_borrador(uuid, bigint, uuid, jsonb)   TO chasquipet_app;


-- =====================================================================
-- 4. Enganches del enrutador — se añade agenda a los módulos anteriores
--
-- Reemplazo ADITIVO de las versiones de 078: se conserva el orden que
-- tenían y solo se intercala el módulo nuevo. `bot_ia_texto` sigue de
-- ÚLTIMO: si alguien está a mitad de un flujo de botones, su texto es la
-- respuesta al flujo y no un mensaje para el asistente.
-- =====================================================================
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_cli_menu(p_usuario_id) || bot_inv_menu(p_usuario_id)
      || bot_cob_menu(p_usuario_id) || bot_com_menu(p_usuario_id)
      || bot_age_menu(p_usuario_id)
      || bot_por_menu(p_usuario_id) || bot_ia_menu(p_usuario_id);
$$;

CREATE OR REPLACE FUNCTION bot_modulo_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_ia_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_inv_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_cli_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_cob_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_com_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_age_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_por_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_auth_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_modulo_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_auth_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_por_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_inv_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cob_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_com_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_age_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cli_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_ia_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id));
$$;

-- Reemplazo aditivo de la lista de 078 (la vigente, con /chasqui y
-- /portal): se conserva línea por línea y se agrega /agenda.
CREATE OR REPLACE FUNCTION bot_texto_ayuda(p_usuario_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT '<b>Comandos</b>' || E'\n' ||
         '/menu — menú principal' || E'\n' ||
         '/chasqui — hablar con Chasqui en lenguaje natural' || E'\n' ||
         '/cola — pacientes en espera' || E'\n' ||
         '/agenda — citas agendadas de hoy' || E'\n' ||
         '/stock — existencias y alertas de inventario' || E'\n' ||
         '/entrada — registrar una compra que llegó' || E'\n' ||
         '/proveedores — proveedores y última compra' || E'\n' ||
         '/cobrar — cuentas abiertas por cobrar' || E'\n' ||
         '/caja — estado de la caja del día' || E'\n' ||
         '/portal — enlace para entrar al portal' || E'\n' ||
         '/sesiones — sesiones abiertas en el portal' || E'\n' ||
         '/ayuda — esta ayuda';
$$;
