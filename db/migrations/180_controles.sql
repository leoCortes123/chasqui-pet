-- =====================================================================
-- Chasqui Pet — 180_controles.sql
-- Ámbito: VERTICAL (seguimiento clínico; convención de cabecera, A7a).
--
-- Fase B2 del plan de consolidación: `consulta.proxima_revision` deja de
-- ser un dato muerto.
--
-- El estado del que se parte: el veterinario fija la próxima revisión por
-- botón en el bot (`056:756`, opciones de 8/15/30 días), por formulario en
-- el portal y por el asistente (`079`). Y ahí se acaba. NADIE lee ese
-- campo con un `WHERE proxima_revision <= …`: el único que lo mira es
-- `enviar_resumen_consulta.js`, para escribirlo en el mensaje del día, y
-- `reporte_pacientes`, para contarlos. La clínica anota que hay que ver a
-- la mascota en 15 días y después nadie se entera.
--
-- Lo que hace esta fase, en el orden en que ocurre:
--
--   1. **Al fijar la revisión se ofrece agendarla.** No se crea la cita
--      sola: un control es una cita real que ocupa un cupo, y decidirla
--      por el veterinario sería llenarle la agenda de citas que nadie
--      confirmó. Se ofrece con un botón, y ese botón llama a
--      `agendar_control`, que reutiliza `crear_cita` de B1 en vez de
--      construir un segundo mecanismo de agenda.
--
--   2. **Lo que no se agendó no se pierde.** `controles_pendientes`
--      responde «a quién hay que llamar», y el job diario avisa al dueño
--      unos días antes con `controles_avisar`.
--
--   3. **Si el control YA tiene cita, este job se calla.** De recordarla
--      se encarga `agenda_recordatorios` (B1b), que ya sabe hacerlo. Dos
--      mensajes por lo mismo es peor que ninguno.
--
-- Ley 1581 de 2012 (§12), igual que en B1b: se filtra por consentimiento
-- y chat vinculado antes de encolar, y el worker lo vuelve a comprobar al
-- enviar. Ninguna capa sustituye a la otra.
--
-- Sobre la memoria de lo avisado: va en una tabla aparte
-- (`aviso_control_enviado`) y no en una columna de `consulta`, porque una
-- consulta firmada es inmutable —el trigger `consulta_inmutable`
-- (`050:247`) rechaza cualquier UPDATE que no sea la anulación— y porque
-- ese es el patrón que ya existe para lo mismo en turnos
-- (`035_aviso_turno.sql`).
--
-- Vacunación y desparasitación: **fuera de alcance, y por qué** — ver la
-- nota al final del archivo.
-- =====================================================================

SET client_min_messages = warning;

INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('control_aviso_dias_antes', '3',     'entero',
   'Con cuántos días de anticipación se avisa al dueño de un control pendiente de agendar', true),
  ('control_hora_defecto',     '09:00', 'texto',
   'Hora que se propone para un control cuando ese día no hay cupos declarados', true)
ON CONFLICT (clave) DO NOTHING;


-- ---------------------------------------------------------------------
-- 1. La cita sabe de qué consulta salió
--
-- Sin esta columna no hay forma de responder «¿este control ya está
-- agendado?», que es la pregunta de la que dependen las tres cosas de la
-- fase: no ofrecerlo dos veces, no listarlo como pendiente y no mandar un
-- aviso que duplica el recordatorio de la cita.
-- ---------------------------------------------------------------------
ALTER TABLE cita ADD COLUMN IF NOT EXISTS consulta_origen_id uuid REFERENCES consulta(id);

COMMENT ON COLUMN cita.consulta_origen_id IS
  'Consulta cuyo control originó esta cita (Fase B2). NULL en una cita agendada por cualquier otro motivo.';

CREATE INDEX IF NOT EXISTS idx_cita_consulta_origen
  ON cita (consulta_origen_id) WHERE consulta_origen_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 2. Memoria de lo ya avisado
--
-- Mismo diseño que `aviso_turno_enviado` (035): la PK es la que decide,
-- sin carreras, quién manda el aviso — el `INSERT … ON CONFLICT DO
-- NOTHING` es la operación atómica, no un `SELECT` previo.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aviso_control_enviado (
  consulta_id uuid        NOT NULL REFERENCES consulta(id) ON DELETE CASCADE,
  tipo        text        NOT NULL,   -- 'proximo' | …
  enviado_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (consulta_id, tipo)
);

COMMENT ON TABLE aviso_control_enviado IS
  'Avisos de control ya enviados por consulta. Evita repetir el mismo aviso en cada corrida del job (Fase B2).';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chasquipet_app') THEN
    GRANT SELECT, INSERT, DELETE ON aviso_control_enviado TO chasquipet_app;
    GRANT SELECT ON aviso_control_enviado TO chasquipet_lectura;
  END IF;
END
$$;


-- ---------------------------------------------------------------------
-- 3. ¿Este control ya tiene cita?
--
-- Una cita cancelada o no asistida no cuenta: el control sigue
-- pendiente, y ese es justamente el caso en el que hay que volver a
-- llamar al dueño.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION control_cita(p_consulta_id uuid)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM cita
   WHERE consulta_origen_id = p_consulta_id
     AND estado IN ('programada','confirmada','cumplida')
   ORDER BY inicio_at DESC
   LIMIT 1;
$$;


-- ---------------------------------------------------------------------
-- 4. agendar_control — el control se vuelve una cita
--
-- No es una segunda forma de agendar: arma los argumentos y llama a
-- `crear_cita`, que sigue siendo la única puerta (con su permiso, su
-- restricción EXCLUDE contra el solapamiento y su auditoría).
--
-- La hora, si nadie la dice: el primer cupo libre de ese día, y si no hay
-- franja declarada, `control_hora_defecto`. Proponer algo es lo que hace
-- que el botón sea un botón y no un formulario.
--
-- Idempotente: si el control ya tiene cita, devuelve esa misma y no
-- agenda otra. Es lo que evita que dos personas mirando la misma lista
-- creen dos citas para la misma mascota.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION agendar_control(
  p_actor uuid,
  p_consulta_id uuid,
  p_args jsonb DEFAULT '{}'::jsonb,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_c       consulta;
  v_fecha   date;
  v_hora    text;
  v_ya      uuid;
  v_r       jsonb;
  v_cita    uuid;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.gestionar');

  SELECT * INTO v_c FROM consulta WHERE id = p_consulta_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_consulta',
             'mensaje', 'Esa consulta no existe.');
  END IF;

  IF v_c.estado = 'anulada' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'consulta_anulada',
             'mensaje', 'Esa consulta está anulada: su control no se agenda.');
  END IF;

  -- La fecha del control puede venir en los argumentos (alguien la mueve
  -- al agendar), pero por defecto es la que el veterinario anotó.
  v_fecha := COALESCE(NULLIF(p_args->>'fecha', '')::date, v_c.proxima_revision);
  IF v_fecha IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_fecha',
             'mensaje', 'Esa consulta no tiene próxima revisión anotada. '
                        'Anótala primero o dime la fecha del control.');
  END IF;

  v_ya := control_cita(p_consulta_id);
  IF v_ya IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'ya_estaba', true,
             'cita', cita_json(v_ya),
             'mensaje', 'Ese control ya estaba agendado.');
  END IF;

  -- Un cupo real si lo hay; si no, la hora de siempre. `horarios_
  -- disponibles` exige `agenda.ver`, así que solo se consulta cuando el
  -- actor puede: quien solo tiene `agenda.gestionar` agenda igual, con la
  -- hora por defecto.
  IF NULLIF(p_args->>'hora', '') IS NOT NULL THEN
    v_hora := p_args->>'hora';
  ELSIF tiene_permiso(p_actor, 'agenda.ver') THEN
    SELECT s->>'hora' INTO v_hora
      FROM jsonb_array_elements(
             horarios_disponibles(p_actor, v_c.sede_id, v_fecha, 'control')->'slots') s
     LIMIT 1;
  END IF;
  v_hora := COALESCE(v_hora, config_txt('control_hora_defecto', '09:00'));

  v_r := crear_cita(p_actor, jsonb_build_object(
           'paciente_id',    v_c.paciente_id,
           'dueno_id',       v_c.dueno_id,
           'sede_id',        v_c.sede_id,
           'veterinario_id', COALESCE(NULLIF(p_args->>'veterinario_id', '')::uuid,
                                      v_c.veterinario_id),
           'tipo',           COALESCE(NULLIF(p_args->>'tipo', ''), 'control'),
           'inicio',         v_fecha::text || ' ' || v_hora,
           'notas',          COALESCE(NULLIF(p_args->>'notas', ''),
                                      'Control de la consulta del ' ||
                                      to_char(v_c.fecha, 'DD/MM/YYYY'))), p_canal);

  IF NOT (v_r->>'ok')::boolean THEN
    RETURN v_r;   -- el canal ya sabe mostrar {ok:false, motivo, mensaje}
  END IF;

  v_cita := (v_r->'cita'->>'cita_id')::uuid;

  UPDATE cita SET consulta_origen_id = p_consulta_id WHERE id = v_cita;

  -- `crear_cita` ya auditó la cita. Esto audita el vínculo, que es lo que
  -- después explica por qué esa cita existe.
  PERFORM auditar('consulta', p_consulta_id::text, 'agendar_control', p_actor, p_canal, NULL,
                  jsonb_build_object('cita_id', v_cita, 'fecha', v_fecha));

  RETURN jsonb_build_object('ok', true, 'cita', cita_json(v_cita),
           'mensaje', 'Control agendado.');
END;
$$;


-- ---------------------------------------------------------------------
-- 5. controles_pendientes — a quién hay que llamar
--
-- Consultas firmadas con revisión anotada, sin cita viva, dentro de la
-- ventana. Incluye las VENCIDAS (`proxima_revision` ya pasó): un control
-- que se pasó de fecha no desaparece, es precisamente el que hay que
-- perseguir. `dias_faltan` sale negativo en ese caso y el canal lo dice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION controles_pendientes(
  p_actor uuid,
  p_sede_id uuid DEFAULT NULL,
  p_dias int DEFAULT 15
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_sede uuid;
  v_l    jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.ver');

  v_sede := agenda_sede(p_actor, p_sede_id);

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'fecha_control'), '[]'::jsonb) INTO v_l
    FROM (
      SELECT jsonb_build_object(
               'consulta_id',  c.id,
               'fecha_control', c.proxima_revision,
               'dias_faltan',  c.proxima_revision - hoy_bogota(),
               'vencido',      c.proxima_revision < hoy_bogota(),
               'paciente_id',  c.paciente_id,
               'paciente',     p.nombre,
               'especie',      p.especie,
               'dueno_id',     c.dueno_id,
               'dueno',        d.nombre_completo,
               'telefono',     d.telefono,
               'avisable',     COALESCE(d.consentimiento_datos, false)
                               AND d.telegram_chat_id IS NOT NULL,
               'avisado',      EXISTS (SELECT 1 FROM aviso_control_enviado a
                                        WHERE a.consulta_id = c.id AND a.tipo = 'proximo'),
               'veterinario',  u.nombre_completo,
               'consulta_fecha', c.fecha) AS x
        FROM consulta c
        JOIN paciente p ON p.id = c.paciente_id
        LEFT JOIN dueno d ON d.id = c.dueno_id
        LEFT JOIN usuario u ON u.id = c.veterinario_id
       WHERE c.estado = 'firmada'
         AND c.proxima_revision IS NOT NULL
         AND c.proxima_revision <= hoy_bogota() + GREATEST(COALESCE(p_dias, 15), 0)
         AND p.estado = 'activo'
         AND COALESCE(c.sede_id, v_sede) = v_sede
         AND control_cita(c.id) IS NULL
    ) t;

  RETURN jsonb_build_object('ok', true, 'sede_id', v_sede,
    'hasta', hoy_bogota() + GREATEST(COALESCE(p_dias, 15), 0),
    'controles', v_l,
    'total', jsonb_array_length(v_l),
    'vencidos', (SELECT count(*) FROM jsonb_array_elements(v_l) e
                  WHERE (e->>'vencido')::boolean));
END;
$$;


-- ---------------------------------------------------------------------
-- 6. controles_avisar — el job
--
-- Avisa al dueño de un control que se acerca y NO está agendado, para que
-- llame a pedir la cita. Si ya hay cita, no dice nada: de eso se encarga
-- `agenda_recordatorios`.
--
-- Como `mantenimiento_diario()` o `agenda_recordatorios`, la llama el
-- sistema y no una persona: no exige permiso. Lo que sí respeta es la
-- Ley 1581 (§12).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION controles_avisar(p_dias int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_dias      int := COALESCE(p_dias, config_int('control_aviso_dias_antes', 3));
  v_fecha     date;
  v_encolados int := 0;
  v_sin_canal int := 0;
  v_ins       int;
  r           record;
BEGIN
  v_fecha := hoy_bogota() + GREATEST(v_dias, 0);

  FOR r IN
    SELECT c.id AS consulta_id, c.dueno_id, c.proxima_revision,
           p.nombre AS mascota,
           COALESCE(d.consentimiento_datos, false) AND d.telegram_chat_id IS NOT NULL AS avisable
      FROM consulta c
      JOIN paciente p ON p.id = c.paciente_id
      LEFT JOIN dueno d ON d.id = c.dueno_id
     WHERE c.estado = 'firmada'
       AND c.proxima_revision = v_fecha
       AND p.estado = 'activo'
       AND control_cita(c.id) IS NULL
  LOOP
    IF NOT r.avisable THEN
      -- Sin consentimiento o sin chat no hay canal. Se cuenta para que el
      -- reporte diga la verdad y NO se marca: si el dueño autoriza el
      -- contacto mañana, el control siguiente sí le llega.
      v_sin_canal := v_sin_canal + 1;
      CONTINUE;
    END IF;

    -- La reja: quien logra insertar es quien manda el aviso.
    INSERT INTO aviso_control_enviado (consulta_id, tipo)
    VALUES (r.consulta_id, 'proximo')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_ins = ROW_COUNT;

    IF v_ins = 1 THEN
      PERFORM encolar_tarea(
        'enviar_aviso_dueno',
        jsonb_build_object(
          'dueno_id', r.dueno_id,
          'mensaje', format(
            'A %s le toca control el %s. Escríbanos por aquí o llámenos para agendar la cita.',
            r.mascota, to_char(r.proxima_revision, 'DD/MM/YYYY'))),
        5,
        'control_' || r.consulta_id::text,
        0, 3);

      PERFORM auditar('consulta', r.consulta_id::text, 'avisar_control', NULL, 'sistema', NULL,
                      jsonb_build_object('dueno_id', r.dueno_id,
                                         'fecha_control', r.proxima_revision));
      v_encolados := v_encolados + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'fecha_control', v_fecha,
    'encolados', v_encolados, 'sin_canal', v_sin_canal);
END;
$$;

GRANT EXECUTE ON FUNCTION control_cita(uuid)                            TO chasquipet_app;
GRANT EXECUTE ON FUNCTION agendar_control(uuid, uuid, jsonb, text)      TO chasquipet_app;
GRANT EXECUTE ON FUNCTION controles_pendientes(uuid, uuid, int)         TO chasquipet_app;
GRANT EXECUTE ON FUNCTION controles_avisar(int)                         TO chasquipet_app;


-- =====================================================================
-- 7. El bot
-- =====================================================================

-- ---------------------------------------------------------------------
-- Vista: los controles por agendar
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_ctl_lista(p_usuario_id uuid, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_r     jsonb := controles_pendientes(p_usuario_id, p_sede_id, 15);
  v_texto text;
  v_bot   jsonb := '[]'::jsonb;
  c       jsonb;
BEGIN
  v_texto := '🔔 <b>Controles por agendar</b>';

  IF (v_r->>'total')::int = 0 THEN
    v_texto := v_texto || E'\n' || 'No hay controles pendientes en los próximos 15 días.';
  END IF;

  FOR c IN SELECT * FROM jsonb_array_elements(v_r->'controles') LIMIT 10 LOOP
    v_texto := v_texto || E'\n' ||
      CASE WHEN (c->>'vencido')::boolean THEN '⚠️' ELSE '📅' END || ' ' ||
      to_char((c->>'fecha_control')::date, 'DD/MM') || ' · <b>' ||
      esc(c->>'paciente') || '</b>' ||
      COALESCE(' (' || esc(c->>'dueno') || ')', '') ||
      CASE WHEN (c->>'vencido')::boolean THEN ' · <i>vencido</i>'
           ELSE ' · en ' || (c->>'dias_faltan') || ' días' END;

    v_bot := v_bot || jsonb_build_array(jsonb_build_object(
      't', '📅 ' || (c->>'paciente') || ' · ' ||
           to_char((c->>'fecha_control')::date, 'DD/MM'),
      'd', 'ctl:agendar:' || (c->>'consulta_id')));
  END LOOP;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '⬅️ Menú', 'd', 'ctl:salir')));

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_bot);
END;
$$;

CREATE OR REPLACE FUNCTION bot_ctl_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_n int;
BEGIN
  IF NOT tiene_permiso(p_usuario_id, 'agenda.gestionar') THEN
    RETURN '[]'::jsonb;
  END IF;

  -- El botón solo aparece si hay algo que hacer: un menú con opciones que
  -- no llevan a ninguna parte es ruido en una pantalla de celular.
  SELECT (controles_pendientes(p_usuario_id, NULL, 7)->>'total')::int INTO v_n;
  IF COALESCE(v_n, 0) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '🔔 Controles (' || v_n || ')', 'd', 'ctl:lista')));
END;
$$;

CREATE OR REPLACE FUNCTION bot_ctl_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_partes text[] := string_to_array(p_data, ':');
  v_vista  jsonb;
  v_alerta text := NULL;
  v_r      jsonb;
BEGIN
  IF v_partes[1] IS DISTINCT FROM 'ctl' THEN
    RETURN NULL;   -- no es nuestro: que siga el enrutador
  END IF;

  CASE v_partes[2]

    WHEN 'lista' THEN
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_ctl_lista(p_usuario_id, p_sede_id);

    WHEN 'agendar' THEN
      v_r := agendar_control(p_usuario_id, v_partes[3]::uuid, '{}'::jsonb, 'telegram');
      IF (v_r->>'ok')::boolean THEN
        v_alerta := COALESCE(v_r->>'mensaje', 'Control agendado');
        v_vista := bot_age_cita((v_r->'cita'->>'cita_id')::uuid, p_usuario_id);
      ELSE
        v_alerta := v_r->>'mensaje';
        v_vista := bot_ctl_lista(p_usuario_id, p_sede_id);
      END IF;

    WHEN 'salir' THEN
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_menu_principal(p_usuario_id);

    ELSE
      v_alerta := 'Esa opción ya no está disponible.';
      v_vista := bot_menu_principal(p_usuario_id);
  END CASE;

  RETURN jsonb_build_object(
    'alerta', v_alerta,
    'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;

CREATE OR REPLACE FUNCTION bot_ctl_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_vista jsonb;
BEGIN
  IF p_texto IN ('/controles', 'controles') AND tiene_permiso(p_usuario_id, 'agenda.ver') THEN
    PERFORM estado_limpiar(p_chat_id);
    v_vista := bot_ctl_lista(p_usuario_id, p_sede_id);
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
  END IF;

  RETURN NULL;   -- este módulo no tiene flujo conversacional propio
END;
$$;

-- ---------------------------------------------------------------------
-- El ofrecimiento, donde se toma la decisión
--
-- Reemplazo ADITIVO de `bot_cli_resumen` (`056:451`). Se conserva palabra
-- por palabra —el texto, los campos que faltan para firmar, los botones
-- de cada paso, la adenda— y se agrega UNA fila: «Agendar el control»,
-- visible solo cuando hay revisión anotada y todavía no hay cita.
--
-- Va aquí y no en el `WHEN 'rev'` del callback porque este resumen es la
-- pantalla que el veterinario ve después de fijar la revisión, y la que
-- vuelve a ver al firmar.
-- ---------------------------------------------------------------------
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

  -- Fase B2: la revisión anotada deja de ser un dato muerto en la misma
  -- pantalla donde se anota.
  IF c->>'proxima_revision' IS NOT NULL AND control_cita(p_consulta_id) IS NOT NULL THEN
    v_texto := v_texto || E'\n' || '✅ El control ya está agendado.';
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

    -- Fase B2: el botón nuevo, solo cuando hay algo que agendar.
    IF c->>'proxima_revision' IS NOT NULL AND control_cita(p_consulta_id) IS NULL THEN
      v_bot := v_bot || jsonb_build_array(jsonb_build_array(
                 jsonb_build_object('t', '📅 Agendar el control',
                                    'd', 'ctl:agendar:' || p_consulta_id)));
    END IF;

    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '💾 Salir y seguir después', 'd', 'cli:pausa')));
  ELSE
    IF c->>'proxima_revision' IS NOT NULL AND control_cita(p_consulta_id) IS NULL THEN
      v_bot := v_bot || jsonb_build_array(jsonb_build_array(
                 jsonb_build_object('t', '📅 Agendar el control',
                                    'd', 'ctl:agendar:' || p_consulta_id)));
    END IF;

    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
               jsonb_build_object('t', '➕ Adenda', 'd', 'cli:adenda'),
               jsonb_build_object('t', '⬅️ Menú',   'd', 'cli:cancelar')));
  END IF;

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_bot);
END;
$$;


-- =====================================================================
-- 8. El asistente — una lectura más
--
-- No hace falta escritura nueva: `agendar_cita` (B1b) ya agenda, y
-- `agendar_control` es su atajo desde una consulta. Lo que el modelo no
-- podía responder es «¿a quién hay que llamar para control?».
-- =====================================================================
CREATE OR REPLACE FUNCTION op_controles_pendientes(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'datos',
    COALESCE(controles_pendientes(p_actor, p_sede,
               COALESCE((p_args->>'dias')::int, 15)), 'null'::jsonb));
$$;

INSERT INTO ia_herramienta (nombre, permiso, escribe, critica, orden, descripcion, esquema) VALUES
('controles_pendientes', 'agenda.ver', false, false, 78,
 'Mascotas con control o revisión anotada por el veterinario que TODAVÍA no tienen cita '
 'agendada, con la fecha del control, el dueño, su teléfono y si se le puede escribir por '
 'Telegram. Incluye los vencidos (dias_faltan negativo). Úsala para «a quién hay que '
 'llamar», «qué controles vienen», «quién no ha vuelto a control». Para agendar uno, usa '
 'agendar_cita con el paciente_id y la fecha del control.',
 '{"type":"object","properties":{"dias":{"type":"integer","description":"Ventana hacia adelante en días. Por defecto 15."}}}'::jsonb)
ON CONFLICT (nombre) DO NOTHING;

UPDATE ia_herramienta
   SET funcion = 'op_controles_pendientes', funcion_borrador = NULL, modulo = 'agenda'
 WHERE nombre = 'controles_pendientes';

GRANT EXECUTE ON FUNCTION op_controles_pendientes(uuid, uuid, jsonb) TO chasquipet_app;


-- =====================================================================
-- 9. Enganches del enrutador — se añade controles
--
-- Reemplazo ADITIVO de las versiones de 170: se conserva el orden y solo
-- se intercala `bot_ctl_*`. `bot_ia_texto` sigue de último.
-- =====================================================================
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_cli_menu(p_usuario_id) || bot_inv_menu(p_usuario_id)
      || bot_cob_menu(p_usuario_id) || bot_com_menu(p_usuario_id)
      || bot_age_menu(p_usuario_id) || bot_ctl_menu(p_usuario_id)
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
    bot_ctl_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
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
    bot_ctl_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cli_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_ia_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_texto_ayuda(p_usuario_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT '<b>Comandos</b>' || E'\n' ||
         '/menu — menú principal' || E'\n' ||
         '/chasqui — hablar con Chasqui en lenguaje natural' || E'\n' ||
         '/cola — pacientes en espera' || E'\n' ||
         '/agenda — citas agendadas de hoy' || E'\n' ||
         '/controles — controles pendientes de agendar' || E'\n' ||
         '/stock — existencias y alertas de inventario' || E'\n' ||
         '/entrada — registrar una compra que llegó' || E'\n' ||
         '/proveedores — proveedores y última compra' || E'\n' ||
         '/cobrar — cuentas abiertas por cobrar' || E'\n' ||
         '/caja — estado de la caja del día' || E'\n' ||
         '/portal — enlace para entrar al portal' || E'\n' ||
         '/sesiones — sesiones abiertas en el portal' || E'\n' ||
         '/ayuda — esta ayuda';
$$;


-- =====================================================================
-- 10. Vacunación y desparasitación: por qué NO están aquí
--
-- El plan lo pedía «si el modelo de datos lo permite sin inventar un
-- módulo nuevo; si no, dejarlo anotado y no forzarlo». No lo permite:
--
--   · No existe registro de vacunas por paciente. Hay un `tipo_servicio`
--     'vacunacion' y una `tarifa` 'vacuna', que son cosas que se cobran,
--     no dosis aplicadas; y `movimiento_inventario` sabe qué producto
--     salió, pero no qué enfermedad cubre ni cada cuánto se repite.
--   · Sin esquema de vacunación (producto → dosis → intervalo → refuerzo)
--     no hay forma de calcular «la próxima»: habría que inventarlo, y eso
--     es un módulo nuevo, con su catálogo, su carné y su historia.
--   · La desparasitación está peor: hoy es una tarifa de valor libre.
--
-- Lo que SÍ cubre esta fase mientras tanto: el veterinario que aplica una
-- vacuna anota la próxima revisión en la consulta y el control entra por
-- el mismo camino que todos los demás. Es menos que un carné de vacunas,
-- pero no es una promesa a medias.
-- =====================================================================
