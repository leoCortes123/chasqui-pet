-- =====================================================================
-- Chasqui Pet — 160_agenda.sql
-- Ámbito: VERTICAL (agenda de citas veterinarias; convención de cabecera,
-- Fase A7a).
--
-- Fase B1 del plan de consolidación: la agenda de citas deja de ser un
-- cascarón.
--
-- El estado del que se parte: `cita` y `disponibilidad` existen desde
-- `050_pacientes.sql:126` y `050:144`, pero ninguna función las lee ni
-- las escribe y `consulta.cita_id` (`050:181`) siempre queda NULL. El
-- propio archivo lo declara en `050:16-17`: «Agendamiento — fuera del
-- MVP: se modela el terreno, no se expone». Esta migración expone el
-- terreno, y antes de hacerlo lo corrige donde no aguantaba.
--
-- Qué le faltaba a la forma de las tablas (revisión pedida por el plan
-- antes de escribir nada encima):
--
--   · Nada impedía reservar dos veces al mismo veterinario a la misma
--     hora. Un índice único no sirve —el choque es de RANGOS, no de
--     valores— así que se usa una restricción EXCLUDE con btree_gist.
--     Es la única reja que aguanta dos recepcionistas agendando al mismo
--     tiempo; validar «a mano» antes del INSERT deja la carrera abierta.
--   · No había dónde anotar por qué se canceló, quién canceló, cuándo
--     confirmó el dueño ni si ya se le mandó el recordatorio. Sin esa
--     última columna, el job diario de recordatorios no puede ser
--     idempotente.
--   · `disponibilidad` no decía a qué sede pertenece la franja (el
--     consultorio es opcional) ni cada cuánto se ofrece un cupo dentro de
--     ella.
--   · No existía forma de decir «este martes el doctor no está»: sin
--     eso, la única manera de tapar un hueco era desactivar la franja
--     entera y perder la historia. De ahí `bloqueo_agenda`.
--
-- Decisiones de diseño que conviene tener a la vista:
--
--   · **La franja sugiere, no prohíbe.** `horarios_disponibles` ofrece
--     los cupos que salen de `disponibilidad`; `crear_cita` NO exige que
--     la hora caiga dentro de una franja. Una clínica real encaja
--     pacientes fuera de horario y el sistema no debe pelearse con eso.
--     Lo que sí es infranqueable: el solapamiento con otra cita del
--     mismo veterinario o consultorio, y los bloqueos.
--   · **Reprogramar es mover la misma fila**, no cancelar y crear otra.
--     Así el dueño conserva «su» cita, el EXCLUDE no choca contra la
--     versión vieja de sí misma y la historia queda donde tiene que
--     quedar: en `evento_auditoria`, con antes y después.
--   · **`confirmar_asistencia` es la llegada al mostrador**, no la
--     confirmación telefónica previa: genera el turno del día con
--     `crear_turno_manual` y ata `cita.turno_id`. El estado `confirmada`
--     y la columna `confirmada_at` quedan listos para cuando el
--     recordatorio del dueño se implemente (canales, tanda siguiente).
--   · La cita no se borra nunca: se cancela con motivo.
-- =====================================================================

SET client_min_messages = warning;

-- btree_gist es lo que permite mezclar en una misma restricción EXCLUDE
-- una igualdad (el veterinario) con un solapamiento de rangos (la hora).
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- ---------------------------------------------------------------------
-- 1. Lo que le faltaba a las tablas
-- ---------------------------------------------------------------------
ALTER TABLE cita ADD COLUMN IF NOT EXISTS canal_origen            text;
ALTER TABLE cita ADD COLUMN IF NOT EXISTS confirmada_at           timestamptz;
ALTER TABLE cita ADD COLUMN IF NOT EXISTS cancelada_at            timestamptz;
ALTER TABLE cita ADD COLUMN IF NOT EXISTS cancelada_por           uuid REFERENCES usuario(id);
ALTER TABLE cita ADD COLUMN IF NOT EXISTS motivo_cancelacion      text;
ALTER TABLE cita ADD COLUMN IF NOT EXISTS recordatorio_enviado_at timestamptz;

COMMENT ON COLUMN cita.canal_origen IS
  'Por dónde entró la cita: telegram, web o sistema.';
COMMENT ON COLUMN cita.recordatorio_enviado_at IS
  'Sello del aviso al dueño. Es la reja de idempotencia del job diario: se avisa una vez.';

-- Se pone por separado del ADD COLUMN para que el archivo siga siendo
-- idempotente en una base donde la columna ya exista.
UPDATE cita SET canal_origen = 'telegram' WHERE canal_origen IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cita_canal_origen_check') THEN
    ALTER TABLE cita
      ADD CONSTRAINT cita_canal_origen_check
      CHECK (canal_origen IN ('telegram','web','sistema'));
  END IF;
END $$;

ALTER TABLE cita ALTER COLUMN canal_origen SET DEFAULT 'telegram';

-- Doble reserva: imposible, no «improbable». El rango es semiabierto
-- —[inicio, fin)— para que una cita que termina a las 10:00 y otra que
-- empieza a las 10:00 no se consideren solapadas.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cita_sin_choque_veterinario') THEN
    ALTER TABLE cita ADD CONSTRAINT cita_sin_choque_veterinario
      EXCLUDE USING gist (
        veterinario_id WITH =,
        tstzrange(inicio_at, fin_at, '[)') WITH &&
      ) WHERE (veterinario_id IS NOT NULL AND estado IN ('programada','confirmada'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cita_sin_choque_consultorio') THEN
    ALTER TABLE cita ADD CONSTRAINT cita_sin_choque_consultorio
      EXCLUDE USING gist (
        consultorio_id WITH =,
        tstzrange(inicio_at, fin_at, '[)') WITH &&
      ) WHERE (consultorio_id IS NOT NULL AND estado IN ('programada','confirmada'));
  END IF;
END $$;

-- La sede de la franja: el consultorio es opcional, así que no se puede
-- deducir siempre de él.
ALTER TABLE disponibilidad ADD COLUMN IF NOT EXISTS sede_id uuid REFERENCES sede(id);
-- 0 = «usa la duración del tipo de servicio». Sirve para la franja que
-- atiende de a 30 minutos aunque el servicio dure 15.
ALTER TABLE disponibilidad ADD COLUMN IF NOT EXISTS duracion_slot_min int NOT NULL DEFAULT 0;

COMMENT ON COLUMN disponibilidad.duracion_slot_min IS
  'Cada cuántos minutos se ofrece un cupo dentro de la franja. 0 = la duración del tipo de servicio.';

-- Una franja es «la misma» si es el mismo veterinario, el mismo día de la
-- semana, a la misma hora y desde la misma fecha. Sin esto,
-- `definir_disponibilidad` no puede ser idempotente.
CREATE UNIQUE INDEX IF NOT EXISTS idx_disponibilidad_franja
  ON disponibilidad (veterinario_id, dia_semana, hora_inicio, vigente_desde);

CREATE INDEX IF NOT EXISTS idx_disponibilidad_dia
  ON disponibilidad (dia_semana, activo);


-- ---------------------------------------------------------------------
-- 2. bloqueo_agenda — «ese día no hay»
--
-- Ausencia, festivo, hora de almuerzo, cirugía programada. Con
-- `veterinario_id` en NULL el bloqueo es de toda la sede, que es como se
-- expresa un festivo sin repetirlo por cada médico.
--
-- No se borra: se desactiva. Saber que el 20 de julio estuvo bloqueado
-- explica por qué no hubo citas ese día.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bloqueo_agenda (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sede_id        uuid NOT NULL REFERENCES sede(id),
  veterinario_id uuid REFERENCES usuario(id),   -- NULL = toda la sede
  inicio_at      timestamptz NOT NULL,
  fin_at         timestamptz NOT NULL,
  motivo         text NOT NULL,
  activo         boolean NOT NULL DEFAULT true,
  creado_por     uuid REFERENCES usuario(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (fin_at > inicio_at)
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'bloqueo_agenda_touch') THEN
    CREATE TRIGGER bloqueo_agenda_touch BEFORE UPDATE ON bloqueo_agenda
      FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_bloqueo_agenda_vigente
  ON bloqueo_agenda (sede_id, inicio_at, fin_at) WHERE activo;

COMMENT ON TABLE bloqueo_agenda IS
  'Franjas en las que no se agenda: ausencia, festivo, almuerzo. veterinario_id NULL bloquea toda la sede.';


-- ---------------------------------------------------------------------
-- 3. Permisos y configuración
--
-- `agenda.ver` y `agenda.gestionar`. Recepción los tiene los dos: agendar
-- es literalmente su trabajo (§4). El veterinario también, porque quien
-- fija el control de una mascota es él.
-- ---------------------------------------------------------------------
INSERT INTO permiso (codigo, modulo, descripcion) VALUES
  ('agenda.ver',       'agenda', 'Ver la agenda de citas y los horarios disponibles'),
  ('agenda.gestionar', 'agenda', 'Crear, reprogramar y cancelar citas, y definir disponibilidad')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO rol_permiso (rol_codigo, permiso_codigo) VALUES
  ('superadmin',  'agenda.ver'),
  ('superadmin',  'agenda.gestionar'),
  ('admin',       'agenda.ver'),
  ('admin',       'agenda.gestionar'),
  ('veterinario', 'agenda.ver'),
  ('veterinario', 'agenda.gestionar'),
  ('auxiliar',    'agenda.ver'),
  ('auxiliar',    'agenda.gestionar'),
  ('recepcion',   'agenda.ver'),
  ('recepcion',   'agenda.gestionar')
ON CONFLICT DO NOTHING;

INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('agenda_paso_min',       '15',  'entero', 'Cada cuántos minutos se ofrece un cupo cuando la franja no lo dice', true),
  ('agenda_horizonte_dias', '90',  'entero', 'Cuántos días hacia adelante se permite agendar una cita', true)
ON CONFLICT (clave) DO NOTHING;


-- ---------------------------------------------------------------------
-- 4. Utilidades
-- ---------------------------------------------------------------------

-- El bot y el portal mandan la hora como la escribe una persona en
-- Bogotá («2026-08-13 09:00»), sin zona. Un `::timestamptz` sobre eso
-- usaría la zona de la sesión, que en el worker o en un psql suelto puede
-- no ser la de la clínica. Si el texto SÍ trae zona (el portal manda ISO
-- con offset), se respeta.
CREATE OR REPLACE FUNCTION agenda_instante(p_texto text)
RETURNS timestamptz
-- STABLE y no IMMUTABLE: `AT TIME ZONE` y el cast a timestamptz dependen
-- de la base de datos de zonas horarias, no son constantes puras.
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN p_texto IS NULL OR trim(p_texto) = '' THEN NULL
           WHEN p_texto ~ '(Z|[+-][0-9]{2}(:?[0-9]{2})?)\s*$' THEN p_texto::timestamptz
           ELSE (p_texto::timestamp) AT TIME ZONE 'America/Bogota'
         END;
$$;

COMMENT ON FUNCTION agenda_instante(text) IS
  'Texto de fecha y hora a timestamptz. Sin zona explícita se interpreta como hora de Bogotá.';

CREATE OR REPLACE FUNCTION cita_json(p_cita_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'cita_id',        c.id,
    'estado',         c.estado,
    'inicio',         c.inicio_at,
    'fin',            c.fin_at,
    'fecha',          (c.inicio_at AT TIME ZONE 'America/Bogota')::date,
    'hora',           to_char(c.inicio_at AT TIME ZONE 'America/Bogota', 'HH24:MI'),
    'duracion_min',   (EXTRACT(epoch FROM (c.fin_at - c.inicio_at)) / 60)::int,
    'sede_id',        c.sede_id,
    'tipo',           ts.codigo,
    'tipo_nombre',    ts.nombre,
    'paciente_id',    c.paciente_id,
    'paciente',       CASE WHEN c.paciente_id IS NOT NULL THEN paciente_json(c.paciente_id) END,
    'dueno_id',       c.dueno_id,
    'dueno',          d.nombre_completo,
    'veterinario_id', c.veterinario_id,
    'veterinario',    u.nombre_completo,
    'consultorio_id', c.consultorio_id,
    'consultorio',    co.nombre,
    'turno_id',       c.turno_id,
    'turno',          t.codigo,
    'notas',          c.notas,
    'motivo_cancelacion', c.motivo_cancelacion,
    'recordatorio_enviado_at', c.recordatorio_enviado_at)
  FROM cita c
  JOIN tipo_servicio ts ON ts.id = c.tipo_servicio_id
  LEFT JOIN dueno d       ON d.id  = c.dueno_id
  LEFT JOIN usuario u     ON u.id  = c.veterinario_id
  LEFT JOIN consultorio co ON co.id = c.consultorio_id
  LEFT JOIN turno t       ON t.id  = c.turno_id
 WHERE c.id = p_cita_id;
$$;

-- La sede efectiva del actor, con la misma cascada que usa
-- `crear_turno_manual` (030:270): lo que pidan, si no la del usuario, si
-- no la primera sede activa.
CREATE OR REPLACE FUNCTION agenda_sede(p_actor uuid, p_sede_id uuid)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(p_sede_id,
                  (SELECT sede_id FROM usuario WHERE id = p_actor),
                  (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1));
$$;


-- ---------------------------------------------------------------------
-- 5. Disponibilidad y bloqueos — sin esto la agenda no tiene qué ofrecer
--
-- Van con `agenda.gestionar` y no con `config.editar` a propósito: el
-- horario de un médico lo cuadra quien maneja la agenda, no quien toca la
-- configuración del sistema.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION definir_disponibilidad(
  p_actor uuid,
  p_args  jsonb,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_vet    uuid := NULLIF(p_args->>'veterinario_id', '')::uuid;
  v_dia    int  := NULLIF(p_args->>'dia_semana', '')::int;
  v_desde  time := NULLIF(p_args->>'hora_inicio', '')::time;
  v_hasta  time := NULLIF(p_args->>'hora_fin', '')::time;
  v_desde_d date := COALESCE(NULLIF(p_args->>'vigente_desde', '')::date, hoy_bogota());
  v_sede   uuid;
  v_id     uuid;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.gestionar');

  IF v_vet IS NULL OR v_dia IS NULL OR v_desde IS NULL OR v_hasta IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'datos_incompletos',
             'mensaje', 'Faltan datos: veterinario, día de la semana, hora de inicio y hora de fin.');
  END IF;

  IF v_dia < 0 OR v_dia > 6 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'dia_invalido',
             'mensaje', 'El día de la semana va de 0 (domingo) a 6 (sábado).');
  END IF;

  IF v_hasta <= v_desde THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'franja_invalida',
             'mensaje', 'La hora de fin tiene que ser posterior a la de inicio.');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM usuario WHERE id = v_vet AND activo) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'veterinario_inexistente',
             'mensaje', 'Ese veterinario no existe o está inactivo.');
  END IF;

  v_sede := agenda_sede(v_vet, NULLIF(p_args->>'sede_id', '')::uuid);

  INSERT INTO disponibilidad (veterinario_id, consultorio_id, sede_id, dia_semana,
                              hora_inicio, hora_fin, duracion_slot_min,
                              vigente_desde, vigente_hasta, activo)
  VALUES (v_vet, NULLIF(p_args->>'consultorio_id', '')::uuid, v_sede, v_dia,
          v_desde, v_hasta, COALESCE((p_args->>'duracion_slot_min')::int, 0),
          v_desde_d, NULLIF(p_args->>'vigente_hasta', '')::date,
          COALESCE((p_args->>'activo')::boolean, true))
  ON CONFLICT (veterinario_id, dia_semana, hora_inicio, vigente_desde) DO UPDATE
    SET hora_fin          = EXCLUDED.hora_fin,
        consultorio_id    = EXCLUDED.consultorio_id,
        sede_id           = EXCLUDED.sede_id,
        duracion_slot_min = EXCLUDED.duracion_slot_min,
        vigente_hasta     = EXCLUDED.vigente_hasta,
        activo            = EXCLUDED.activo
  RETURNING id INTO v_id;

  PERFORM auditar('disponibilidad', v_id::text, 'definir', p_actor, p_canal, NULL,
                  jsonb_build_object('veterinario_id', v_vet, 'dia_semana', v_dia,
                                     'hora_inicio', v_desde, 'hora_fin', v_hasta));

  RETURN jsonb_build_object('ok', true, 'disponibilidad_id', v_id,
           'mensaje', 'Franja de atención guardada.');
END;
$$;

CREATE OR REPLACE FUNCTION bloquear_agenda(
  p_actor uuid,
  p_args  jsonb,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_inicio timestamptz := agenda_instante(p_args->>'inicio');
  v_fin    timestamptz := agenda_instante(p_args->>'fin');
  v_motivo text := NULLIF(trim(COALESCE(p_args->>'motivo', '')), '');
  v_sede   uuid;
  v_id     uuid;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.gestionar');

  IF v_inicio IS NULL OR v_fin IS NULL OR v_motivo IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'datos_incompletos',
             'mensaje', 'Un bloqueo necesita inicio, fin y motivo.');
  END IF;

  IF v_fin <= v_inicio THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'franja_invalida',
             'mensaje', 'El fin del bloqueo tiene que ser posterior al inicio.');
  END IF;

  v_sede := agenda_sede(p_actor, NULLIF(p_args->>'sede_id', '')::uuid);

  INSERT INTO bloqueo_agenda (sede_id, veterinario_id, inicio_at, fin_at, motivo, creado_por)
  VALUES (v_sede, NULLIF(p_args->>'veterinario_id', '')::uuid, v_inicio, v_fin, v_motivo, p_actor)
  RETURNING id INTO v_id;

  PERFORM auditar('bloqueo_agenda', v_id::text, 'crear', p_actor, p_canal, NULL,
                  jsonb_build_object('inicio', v_inicio, 'fin', v_fin, 'motivo', v_motivo));

  -- Las citas ya agendadas dentro del bloqueo NO se tocan: cancelarlas en
  -- silencio dejaría a un dueño esperando en la puerta. Se cuentan y se
  -- informan para que quien bloquea llame y las reprograme.
  RETURN jsonb_build_object('ok', true, 'bloqueo_id', v_id,
           'citas_afectadas', (SELECT count(*) FROM cita c
                                WHERE c.sede_id = v_sede
                                  AND c.estado IN ('programada','confirmada')
                                  AND (NULLIF(p_args->>'veterinario_id','')::uuid IS NULL
                                       OR c.veterinario_id = NULLIF(p_args->>'veterinario_id','')::uuid)
                                  AND tstzrange(c.inicio_at, c.fin_at, '[)')
                                      && tstzrange(v_inicio, v_fin, '[)')),
           'mensaje', 'Bloqueo registrado.');
END;
$$;

CREATE OR REPLACE FUNCTION liberar_bloqueo(
  p_actor uuid,
  p_bloqueo_id uuid,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.gestionar');

  UPDATE bloqueo_agenda SET activo = false WHERE id = p_bloqueo_id AND activo;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_bloqueo',
             'mensaje', 'Ese bloqueo no existe o ya estaba liberado.');
  END IF;

  PERFORM auditar('bloqueo_agenda', p_bloqueo_id::text, 'liberar', p_actor, p_canal);

  RETURN jsonb_build_object('ok', true, 'mensaje', 'Bloqueo liberado.');
END;
$$;


-- ---------------------------------------------------------------------
-- 6. horarios_disponibles — qué cupos hay
--
-- Sale de la franja semanal del veterinario, se le restan las citas ya
-- tomadas y los bloqueos, y se descarta lo que ya pasó. La duración del
-- cupo es la del tipo de servicio; el PASO entre cupos es el de la franja
-- si lo declara, y si no `agenda_paso_min`.
--
-- El rango se compara semiabierto `[)` igual que la restricción EXCLUDE:
-- las dos definiciones de «choque» tienen que ser la misma o el sistema
-- ofrecería cupos que después rechaza al insertar.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION horarios_disponibles(
  p_actor uuid,
  p_sede_id uuid,
  p_fecha date,
  p_tipo_codigo text DEFAULT 'general',
  p_veterinario_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_sede  uuid;
  v_dur   int;
  v_paso  int := config_int('agenda_paso_min', 15);
  v_fecha date := COALESCE(p_fecha, hoy_bogota());
  v_slots jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.ver');

  SELECT duracion_estimada_min INTO v_dur
    FROM tipo_servicio WHERE codigo = p_tipo_codigo AND activo;
  IF v_dur IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'tipo_desconocido',
             'mensaje', format('No existe el tipo de servicio «%s».', p_tipo_codigo));
  END IF;

  v_sede := agenda_sede(p_actor, p_sede_id);

  WITH franja AS (
    SELECT d.veterinario_id,
           d.consultorio_id,
           d.hora_inicio,
           d.hora_fin,
           COALESCE(NULLIF(d.duracion_slot_min, 0), v_paso) AS paso
      FROM disponibilidad d
      LEFT JOIN consultorio c ON c.id = d.consultorio_id
      LEFT JOIN usuario u ON u.id = d.veterinario_id
     WHERE d.activo
       AND d.dia_semana = EXTRACT(dow FROM v_fecha)::int
       AND d.vigente_desde <= v_fecha
       AND (d.vigente_hasta IS NULL OR d.vigente_hasta >= v_fecha)
       AND (p_veterinario_id IS NULL OR d.veterinario_id = p_veterinario_id)
       AND COALESCE(d.sede_id, c.sede_id, u.sede_id) = v_sede
  ),
  slot AS (
    SELECT f.veterinario_id,
           f.consultorio_id,
           g AS inicio_at,
           g + make_interval(mins => v_dur) AS fin_at
      FROM franja f,
           LATERAL generate_series(
             (v_fecha + f.hora_inicio) AT TIME ZONE 'America/Bogota',
             ((v_fecha + f.hora_fin) AT TIME ZONE 'America/Bogota')
               - make_interval(mins => v_dur),
             make_interval(mins => f.paso)) AS g
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'inicio', s.inicio_at,
           'fin', s.fin_at,
           'hora', to_char(s.inicio_at AT TIME ZONE 'America/Bogota', 'HH24:MI'),
           'veterinario_id', s.veterinario_id,
           'veterinario', (SELECT nombre_completo FROM usuario WHERE id = s.veterinario_id),
           'consultorio_id', s.consultorio_id)
           ORDER BY s.inicio_at, s.veterinario_id), '[]'::jsonb)
    INTO v_slots
    FROM slot s
   WHERE s.inicio_at > now()
     AND NOT EXISTS (
           SELECT 1 FROM cita ci
            WHERE ci.veterinario_id = s.veterinario_id
              AND ci.estado IN ('programada','confirmada')
              AND tstzrange(ci.inicio_at, ci.fin_at, '[)')
                  && tstzrange(s.inicio_at, s.fin_at, '[)'))
     AND NOT EXISTS (
           SELECT 1 FROM bloqueo_agenda b
            WHERE b.activo
              AND b.sede_id = v_sede
              AND (b.veterinario_id IS NULL OR b.veterinario_id = s.veterinario_id)
              AND tstzrange(b.inicio_at, b.fin_at, '[)')
                  && tstzrange(s.inicio_at, s.fin_at, '[)'));

  RETURN jsonb_build_object(
    'ok', true,
    'fecha', v_fecha,
    'tipo', p_tipo_codigo,
    'duracion_min', v_dur,
    'slots', v_slots,
    'total', jsonb_array_length(v_slots));
END;
$$;


-- ---------------------------------------------------------------------
-- 7. crear_cita
--
-- Contrato uniforme del proyecto: (p_actor, args, p_canal) → {ok, …}.
-- El permiso primero, antes de mirar un solo dato.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_cita(
  p_actor uuid,
  p_args  jsonb,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_inicio  timestamptz := agenda_instante(p_args->>'inicio');
  v_pac     uuid := NULLIF(p_args->>'paciente_id', '')::uuid;
  v_vet     uuid := NULLIF(p_args->>'veterinario_id', '')::uuid;
  v_cons    uuid := NULLIF(p_args->>'consultorio_id', '')::uuid;
  v_tipo    tipo_servicio;
  v_dueno   uuid;
  v_sede    uuid;
  v_dur     int;
  v_fin     timestamptz;
  v_id      uuid;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.gestionar');

  IF v_inicio IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_inicio',
             'mensaje', 'Falta la fecha y hora de la cita.');
  END IF;

  SELECT * INTO v_tipo FROM tipo_servicio
   WHERE codigo = COALESCE(NULLIF(p_args->>'tipo', ''), 'general') AND activo;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'tipo_desconocido',
             'mensaje', 'Ese tipo de servicio no existe.');
  END IF;

  IF v_pac IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_paciente',
             'mensaje', 'Una cita necesita la mascota que se va a atender.');
  END IF;

  SELECT dueno_id INTO v_dueno FROM paciente WHERE id = v_pac AND estado = 'activo';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'paciente_inexistente',
             'mensaje', 'Esa mascota no existe o está inactiva.');
  END IF;
  v_dueno := COALESCE(NULLIF(p_args->>'dueno_id', '')::uuid, v_dueno);

  IF v_inicio <= now() THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'inicio_pasado',
             'mensaje', 'No se puede agendar una cita en el pasado.');
  END IF;

  IF v_inicio > now() + make_interval(days => config_int('agenda_horizonte_dias', 90)) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'fuera_de_horizonte',
             'mensaje', format('No se agenda a más de %s días.',
                               config_int('agenda_horizonte_dias', 90)));
  END IF;

  IF v_vet IS NOT NULL AND NOT EXISTS (SELECT 1 FROM usuario WHERE id = v_vet AND activo) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'veterinario_inexistente',
             'mensaje', 'Ese veterinario no existe o está inactivo.');
  END IF;

  v_sede := agenda_sede(p_actor, NULLIF(p_args->>'sede_id', '')::uuid);
  v_dur  := GREATEST(COALESCE(NULLIF(p_args->>'duracion_min', '')::int,
                              v_tipo.duracion_estimada_min), 5);
  v_fin  := v_inicio + make_interval(mins => v_dur);

  -- El bloqueo sí prohíbe (la franja no): si el médico no está, no está.
  IF EXISTS (SELECT 1 FROM bloqueo_agenda b
              WHERE b.activo AND b.sede_id = v_sede
                AND (b.veterinario_id IS NULL OR b.veterinario_id = v_vet)
                AND tstzrange(b.inicio_at, b.fin_at, '[)') && tstzrange(v_inicio, v_fin, '[)')) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'agenda_bloqueada',
             'mensaje', 'Esa franja está bloqueada en la agenda.');
  END IF;

  -- El choque lo decide la restricción EXCLUDE, no una consulta previa:
  -- entre el SELECT y el INSERT cabe otra recepcionista.
  BEGIN
    INSERT INTO cita (sede_id, paciente_id, dueno_id, tipo_servicio_id, veterinario_id,
                      consultorio_id, inicio_at, fin_at, notas, canal_origen, creado_por)
    VALUES (v_sede, v_pac, v_dueno, v_tipo.id, v_vet, v_cons, v_inicio, v_fin,
            NULLIF(trim(COALESCE(p_args->>'notas', '')), ''),
            CASE WHEN p_canal IN ('telegram','web','sistema') THEN p_canal ELSE 'sistema' END,
            p_actor)
    RETURNING id INTO v_id;
  EXCEPTION WHEN exclusion_violation THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'ocupado',
             'mensaje', 'Ese horario ya está tomado. Consulta los cupos libres y elige otro.');
  END;

  PERFORM auditar('cita', v_id::text, 'crear', p_actor, p_canal, NULL,
                  jsonb_build_object('paciente_id', v_pac, 'veterinario_id', v_vet,
                                     'inicio', v_inicio, 'tipo', v_tipo.codigo));

  RETURN jsonb_build_object('ok', true, 'cita', cita_json(v_id),
           'mensaje', 'Cita agendada.');
END;
$$;


-- ---------------------------------------------------------------------
-- 8. reprogramar_cita — mover la misma fila
--
-- No se cancela y se crea otra: el dueño conserva su cita, el EXCLUDE no
-- choca contra la versión vieja de sí misma (la fila es la misma) y el
-- antes/después queda en la auditoría, que es donde se consulta la
-- historia.
--
-- Reprogramar reinicia el recordatorio: cambió la hora, hay que volver a
-- avisar.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reprogramar_cita(
  p_actor uuid,
  p_cita_id uuid,
  p_inicio text,
  p_veterinario_id uuid DEFAULT NULL,
  p_motivo text DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_c      cita;
  v_inicio timestamptz := agenda_instante(p_inicio);
  v_dur    int;
  v_fin    timestamptz;
  v_vet    uuid;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.gestionar');

  SELECT * INTO v_c FROM cita WHERE id = p_cita_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_cita',
             'mensaje', 'Esa cita no existe.');
  END IF;

  IF v_c.estado NOT IN ('programada','confirmada') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'estado_no_reprogramable',
             'mensaje', format('Una cita %s no se reprograma; agenda una nueva.', v_c.estado));
  END IF;

  IF v_inicio IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_inicio',
             'mensaje', 'Falta la nueva fecha y hora.');
  END IF;

  IF v_inicio <= now() THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'inicio_pasado',
             'mensaje', 'No se puede reprogramar hacia el pasado.');
  END IF;

  v_vet := COALESCE(p_veterinario_id, v_c.veterinario_id);
  v_dur := (EXTRACT(epoch FROM (v_c.fin_at - v_c.inicio_at)) / 60)::int;
  v_fin := v_inicio + make_interval(mins => v_dur);

  IF EXISTS (SELECT 1 FROM bloqueo_agenda b
              WHERE b.activo AND b.sede_id = v_c.sede_id
                AND (b.veterinario_id IS NULL OR b.veterinario_id = v_vet)
                AND tstzrange(b.inicio_at, b.fin_at, '[)') && tstzrange(v_inicio, v_fin, '[)')) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'agenda_bloqueada',
             'mensaje', 'Esa franja está bloqueada en la agenda.');
  END IF;

  BEGIN
    UPDATE cita
       SET inicio_at = v_inicio,
           fin_at    = v_fin,
           veterinario_id = v_vet,
           estado    = 'programada',      -- vuelve a necesitar confirmación
           confirmada_at = NULL,
           recordatorio_enviado_at = NULL
     WHERE id = p_cita_id;
  EXCEPTION WHEN exclusion_violation THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'ocupado',
             'mensaje', 'Ese horario ya está tomado. Elige otro.');
  END;

  PERFORM auditar('cita', p_cita_id::text, 'reprogramar', p_actor, p_canal,
                  jsonb_build_object('inicio', v_c.inicio_at, 'veterinario_id', v_c.veterinario_id),
                  jsonb_build_object('inicio', v_inicio, 'veterinario_id', v_vet),
                  p_motivo);

  RETURN jsonb_build_object('ok', true, 'cita', cita_json(p_cita_id),
           'mensaje', 'Cita reprogramada.');
END;
$$;


-- ---------------------------------------------------------------------
-- 9. cancelar_cita — no se borra, se cancela con motivo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancelar_cita(
  p_actor uuid,
  p_cita_id uuid,
  p_motivo text DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.gestionar');

  SELECT estado INTO v_estado FROM cita WHERE id = p_cita_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_cita',
             'mensaje', 'Esa cita no existe.');
  END IF;

  -- Idempotente: cancelar lo cancelado no es un error, es que alguien
  -- tocó el botón dos veces.
  IF v_estado = 'cancelada' THEN
    RETURN jsonb_build_object('ok', true, 'ya_estaba', true,
             'cita', cita_json(p_cita_id), 'mensaje', 'Esa cita ya estaba cancelada.');
  END IF;

  IF v_estado = 'cumplida' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'cita_cumplida',
             'mensaje', 'Esa cita ya se atendió: no se puede cancelar.');
  END IF;

  UPDATE cita
     SET estado = 'cancelada',
         cancelada_at = now(),
         cancelada_por = p_actor,
         motivo_cancelacion = NULLIF(trim(COALESCE(p_motivo, '')), '')
   WHERE id = p_cita_id;

  PERFORM auditar('cita', p_cita_id::text, 'cancelar', p_actor, p_canal,
                  jsonb_build_object('estado', v_estado),
                  jsonb_build_object('estado', 'cancelada'), p_motivo);

  RETURN jsonb_build_object('ok', true, 'cita', cita_json(p_cita_id),
           'mensaje', 'Cita cancelada.');
END;
$$;


-- ---------------------------------------------------------------------
-- 10. confirmar_asistencia — la mascota llegó
--
-- Aquí es donde la agenda se junta con la cola: la cita genera el turno
-- del día (`crear_turno_manual`, 030:252) y queda atada a él. De ese
-- vínculo cuelga después `consulta.cita_id`.
--
-- Idempotente por diseño: si la cita ya generó su turno, se devuelve el
-- mismo. Recepción presiona dos veces cuando la sala está llena.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION confirmar_asistencia(
  p_actor uuid,
  p_cita_id uuid,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_c     cita;
  v_tipo  text;
  v_r     jsonb;
  v_turno uuid;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.gestionar');

  SELECT * INTO v_c FROM cita WHERE id = p_cita_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_cita',
             'mensaje', 'Esa cita no existe.');
  END IF;

  IF v_c.turno_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'ya_estaba', true,
             'cita', cita_json(p_cita_id), 'turno', turno_json(v_c.turno_id),
             'mensaje', 'Esa cita ya tenía su turno.');
  END IF;

  IF v_c.estado NOT IN ('programada','confirmada') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'estado_no_confirmable',
             'mensaje', format('Una cita %s no genera turno.', v_c.estado));
  END IF;

  SELECT codigo INTO v_tipo FROM tipo_servicio WHERE id = v_c.tipo_servicio_id;

  -- `crear_turno_manual` vuelve a exigir 'turnos.crear': quien recibe en
  -- el mostrador ya lo tiene, y si no, la operación falla entera antes de
  -- marcar la cita como cumplida.
  v_r := crear_turno_manual(p_actor, v_c.sede_id, v_tipo, false,
                            v_c.dueno_id, v_c.paciente_id,
                            COALESCE(v_c.notas, 'Llegó por cita agendada'),
                            NULL, p_canal);

  IF NOT (v_r->>'ok')::boolean THEN
    RETURN v_r;
  END IF;

  v_turno := (v_r->'turno'->>'turno_id')::uuid;

  UPDATE cita
     SET turno_id = v_turno,
         estado   = 'cumplida',
         confirmada_at = COALESCE(confirmada_at, now())
   WHERE id = p_cita_id;

  PERFORM auditar('cita', p_cita_id::text, 'confirmar_asistencia', p_actor, p_canal,
                  jsonb_build_object('estado', v_c.estado),
                  jsonb_build_object('estado', 'cumplida', 'turno_id', v_turno));

  RETURN jsonb_build_object('ok', true, 'cita', cita_json(p_cita_id),
           'turno', v_r->'turno', 'mensaje', 'Llegada registrada: la cita ya tiene turno.');
END;
$$;


-- ---------------------------------------------------------------------
-- 11. agenda_del_dia — lo que hay que atender
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION agenda_del_dia(
  p_actor uuid,
  p_sede_id uuid DEFAULT NULL,
  p_fecha date DEFAULT NULL,
  p_veterinario_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_sede  uuid;
  v_fecha date := COALESCE(p_fecha, hoy_bogota());
  v_citas jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor, 'agenda.ver');

  v_sede := agenda_sede(p_actor, p_sede_id);

  SELECT COALESCE(jsonb_agg(cita_json(c.id) ORDER BY c.inicio_at), '[]'::jsonb)
    INTO v_citas
    FROM cita c
   WHERE c.sede_id = v_sede
     AND (c.inicio_at AT TIME ZONE 'America/Bogota')::date = v_fecha
     AND (p_veterinario_id IS NULL OR c.veterinario_id = p_veterinario_id);

  RETURN jsonb_build_object(
    'ok', true,
    'fecha', v_fecha,
    'sede_id', v_sede,
    'citas', v_citas,
    'total', jsonb_array_length(v_citas),
    'por_estado', (
      SELECT COALESCE(jsonb_object_agg(estado, n), '{}'::jsonb)
        FROM (SELECT c.estado, count(*) AS n
                FROM cita c
               WHERE c.sede_id = v_sede
                 AND (c.inicio_at AT TIME ZONE 'America/Bogota')::date = v_fecha
                 AND (p_veterinario_id IS NULL OR c.veterinario_id = p_veterinario_id)
               GROUP BY c.estado) x));
END;
$$;


-- ---------------------------------------------------------------------
-- 12. `consulta.cita_id` deja de ser NULL para siempre
--
-- Reemplazo ADITIVO de `abrir_consulta` (050:951). Lo único que cambia:
-- al insertar la consulta, si el turno nació de una cita, se copia
-- `cita_id`. Todo lo demás —reabrir el borrador, el turno ya atendido, el
-- consultorio de la sesión abierta, la auditoría, el contrato de
-- salida— queda palabra por palabra como estaba.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION abrir_consulta(
  p_actor_id uuid,
  p_paciente_id uuid,
  p_turno_id uuid DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
  v_turno turno;
  v_consultorio uuid;
  v_sede uuid;
  v_dueno uuid;
  v_cita uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'consulta.crear');

  SELECT dueno_id INTO v_dueno FROM paciente WHERE id = p_paciente_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese paciente no existe.');
  END IF;

  -- Sin turno explícito: el que este veterinario tiene en atención.
  IF p_turno_id IS NULL THEN
    SELECT * INTO v_turno FROM turno
     WHERE veterinario_id = p_actor_id AND fecha = hoy_bogota()
       AND estado = 'en_atencion'
     ORDER BY en_atencion_at DESC LIMIT 1;
  ELSE
    SELECT * INTO v_turno FROM turno WHERE id = p_turno_id;
  END IF;

  -- Reabrir en vez de duplicar: si ese turno ya tiene consulta en
  -- borrador del mismo paciente, se continúa.
  IF v_turno.id IS NOT NULL THEN
    SELECT id INTO v_id FROM consulta
     WHERE turno_id = v_turno.id AND estado = 'borrador' AND paciente_id = p_paciente_id;
    IF v_id IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'reabierta', true,
                                'consulta', consulta_json(v_id));
    END IF;

    IF EXISTS (SELECT 1 FROM consulta WHERE turno_id = v_turno.id) THEN
      -- El turno ya tiene su consulta. Si es del mismo paciente, esto es
      -- un segundo intento y hay que decirlo; si es de otro —una segunda
      -- mascota de la misma familia, una consulta suelta— se abre sin
      -- turno en vez de bloquear la atención.
      IF EXISTS (SELECT 1 FROM consulta
                  WHERE turno_id = v_turno.id AND paciente_id = p_paciente_id) THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'turno_ya_atendido',
                 'mensaje', 'Ese turno ya tiene una consulta firmada. Agrégale una adenda.');
      END IF;
      v_turno := NULL;
    END IF;
  END IF;

  SELECT sc.consultorio_id, c.sede_id INTO v_consultorio, v_sede
    FROM sesion_consultorio sc
    JOIN consultorio c ON c.id = sc.consultorio_id
   WHERE sc.usuario_id = p_actor_id AND sc.cerrada_at IS NULL;

  -- Fase B1: si el turno lo generó una cita agendada, la consulta hereda
  -- el vínculo. Es lo que cierra el círculo agenda → cola → historia y lo
  -- que hace que `consulta.cita_id` deje de ser una columna muerta.
  IF v_turno.id IS NOT NULL THEN
    SELECT id INTO v_cita FROM cita
     WHERE turno_id = v_turno.id AND paciente_id = p_paciente_id
     LIMIT 1;
  END IF;

  INSERT INTO consulta (turno_id, cita_id, paciente_id, dueno_id, veterinario_id,
                        consultorio_id, sede_id, canal_origen)
  VALUES (v_turno.id, v_cita, p_paciente_id, v_dueno, p_actor_id,
          COALESCE(v_turno.consultorio_id, v_consultorio),
          COALESCE(v_turno.sede_id, v_sede), p_canal)
  RETURNING id INTO v_id;

  IF v_turno.id IS NOT NULL THEN
    UPDATE turno SET consulta_id = v_id,
                     paciente_id = COALESCE(paciente_id, p_paciente_id),
                     dueno_id    = COALESCE(dueno_id, v_dueno)
     WHERE id = v_turno.id;
  END IF;

  PERFORM auditar('consulta', v_id::text, 'abrir', p_actor_id, p_canal, NULL,
                  jsonb_build_object('paciente_id', p_paciente_id, 'turno_id', v_turno.id,
                                     'cita_id', v_cita));

  RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(v_id));
END;
$$;


-- ---------------------------------------------------------------------
-- 13. Permisos de ejecución
--
-- `ALTER DEFAULT PRIVILEGES` de 090 cubre tablas y secuencias, no
-- funciones: estas se otorgan a mano, como en 150.
-- ---------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION agenda_instante(text)                          TO chasquipet_app;
GRANT EXECUTE ON FUNCTION cita_json(uuid)                                TO chasquipet_app;
GRANT EXECUTE ON FUNCTION agenda_sede(uuid, uuid)                        TO chasquipet_app;
GRANT EXECUTE ON FUNCTION definir_disponibilidad(uuid, jsonb, text)      TO chasquipet_app;
GRANT EXECUTE ON FUNCTION bloquear_agenda(uuid, jsonb, text)             TO chasquipet_app;
GRANT EXECUTE ON FUNCTION liberar_bloqueo(uuid, uuid, text)              TO chasquipet_app;
GRANT EXECUTE ON FUNCTION horarios_disponibles(uuid, uuid, date, text, uuid) TO chasquipet_app;
GRANT EXECUTE ON FUNCTION crear_cita(uuid, jsonb, text)                  TO chasquipet_app;
GRANT EXECUTE ON FUNCTION reprogramar_cita(uuid, uuid, text, uuid, text, text) TO chasquipet_app;
GRANT EXECUTE ON FUNCTION cancelar_cita(uuid, uuid, text, text)          TO chasquipet_app;
GRANT EXECUTE ON FUNCTION confirmar_asistencia(uuid, uuid, text)         TO chasquipet_app;
GRANT EXECUTE ON FUNCTION agenda_del_dia(uuid, uuid, date, uuid)         TO chasquipet_app;

GRANT SELECT ON bloqueo_agenda TO chasquipet_lectura;

COMMENT ON FUNCTION crear_cita(uuid, jsonb, text) IS
  'Agenda una cita. El solapamiento lo impide una restricción EXCLUDE, no una consulta previa (Fase B1).';
COMMENT ON FUNCTION confirmar_asistencia(uuid, uuid, text) IS
  'La mascota llegó: genera el turno del día y lo ata a la cita. Idempotente (Fase B1).';
