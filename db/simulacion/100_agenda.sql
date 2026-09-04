-- =====================================================================
-- Chasqui Pet — db/simulacion/100_agenda.sql
-- Agenda de citas (Fase B1/B1b) para el día en curso. Se carga con:
--
--     bash scripts/simular.sh dia
--
-- Qué produce:
--   · La franja semanal de los dos veterinarios de simulación: lunes a
--     sábado, 08:00–12:00 y 14:00–18:00, cada uno en su consultorio. Sin
--     esto `horarios_disponibles()` devuelve una lista vacía y no se
--     puede agendar nada por el portal ni por el bot.
--   · Citas de hoy: dos ya cumplidas, una confirmada y tres programadas
--     en las próximas horas, para que el tablero del portal y el
--     «📅 Agenda» del bot tengan algo vivo.
--   · Una cita de ayer a la que el dueño no llegó y otra cancelada, que
--     es lo que alimenta el indicador de inasistencia.
--   · Citas de mañana y de los próximos días CON el recordatorio
--     pendiente (`recordatorio_enviado_at IS NULL`), que es lo que busca
--     el job «Agenda diaria» de n8n: sin ellas ese job no tiene nada que
--     hacer y no se puede probar.
--
-- Depende de db/demo/010_turnos_demo.sql (personal y consultorios) y de
-- db/demo/030_clinico_demo.sql (pacientes y dueños). Por eso el
-- orquestador lo corre después.
--
-- Las citas se insertan directo y no por `crear_cita()` a propósito: esa
-- función —con razón— rechaza cualquier cita en el pasado (§B1), y una
-- simulación necesita justamente el pasado del día para que los
-- indicadores no salgan en cero. Lo que sí se respeta es el modelo: cada
-- cita cae dentro de la franja de su veterinario y ninguna se solapa con
-- otra del mismo médico ni del mismo consultorio, que es lo que exigen
-- las restricciones EXCLUDE de la tabla.
--
-- Re-ejecutable: borra las citas y la disponibilidad del personal de
-- simulación antes de volver a generarlas.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

DO $sim$
DECLARE
  c_tg_base constant bigint := 900000000;
  c_tg_tope constant bigint := 900999999;

  v_sede uuid;
  v_vet1 uuid;
  v_vet2 uuid;
  v_c1   uuid;
  v_c2   uuid;

  v_pacientes uuid[];
  v_pac       uuid;
  v_dueno     uuid;

  -- Ancla temporal. `v_base` es la próxima hora en punto: garantiza que
  -- toda cita «futura de hoy» quede realmente en el futuro sin importar a
  -- qué hora se cargue la simulación.
  v_base    timestamptz := date_trunc('hour', now()) + interval '1 hour';
  v_hoy_fin timestamptz := (hoy_bogota() + 1)::timestamp AT TIME ZONE 'America/Bogota';

  v_tipo   record;
  v_inicio timestamptz;
  v_estado text;
  v_vet    uuid;
  v_cons   uuid;
  v_i      int;
  v_n      int := 0;
  v_futuras boolean;
BEGIN
  SELECT id INTO v_sede FROM sede WHERE activa ORDER BY created_at LIMIT 1;
  IF v_sede IS NULL THEN
    RAISE EXCEPTION 'No hay sede activa. Aplique primero las migraciones.';
  END IF;

  SELECT u.id INTO v_vet1
    FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id AND ur.rol_codigo = 'veterinario'
   WHERE u.telegram_user_id BETWEEN c_tg_base AND c_tg_tope
   ORDER BY u.telegram_user_id LIMIT 1;

  SELECT u.id INTO v_vet2
    FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id AND ur.rol_codigo = 'veterinario'
   WHERE u.telegram_user_id BETWEEN c_tg_base AND c_tg_tope AND u.id <> v_vet1
   ORDER BY u.telegram_user_id LIMIT 1;

  IF v_vet1 IS NULL OR v_vet2 IS NULL THEN
    RAISE EXCEPTION 'No hay dos veterinarios de simulación. Cargue antes db/demo/010_turnos_demo.sql.';
  END IF;

  SELECT id INTO v_c1 FROM consultorio
   WHERE sede_id = v_sede AND activo ORDER BY orden, nombre LIMIT 1;
  SELECT id INTO v_c2 FROM consultorio
   WHERE sede_id = v_sede AND activo AND id <> v_c1 ORDER BY orden, nombre LIMIT 1;

  -- Orden por nombre y no por created_at: db/demo/030 inserta los quince
  -- pacientes en la misma transacción, así que todos comparten el
  -- created_at y ordenar por él devuelve un orden distinto en cada
  -- carga. Se excluye al callejero sin dueño: una cita, un control o una
  -- remisión necesitan a quién avisar.
  SELECT array_agg(id ORDER BY nombre) INTO v_pacientes
    FROM paciente
   WHERE notas = 'DEMO' AND estado = 'activo' AND dueno_id IS NOT NULL;

  IF v_pacientes IS NULL OR array_length(v_pacientes, 1) < 8 THEN
    RAISE EXCEPTION 'No hay pacientes de simulación. Cargue antes db/demo/030_clinico_demo.sql.';
  END IF;

  -- ===================================================================
  -- BLOQUE 1 — Limpieza de la carga anterior.
  -- Sólo lo del personal de simulación: si alguien de la clínica definió
  -- su propia franja probando el portal, se respeta.
  -- ===================================================================
  DELETE FROM cita
   WHERE creado_por IN (v_vet1, v_vet2)
      OR veterinario_id IN (v_vet1, v_vet2)
      OR paciente_id = ANY (v_pacientes);

  DELETE FROM disponibilidad WHERE veterinario_id IN (v_vet1, v_vet2);
  DELETE FROM bloqueo_agenda WHERE veterinario_id IN (v_vet1, v_vet2);

  -- ===================================================================
  -- BLOQUE 2 — Franja semanal.
  -- Lunes (1) a sábado (6), jornada partida. `duracion_slot_min = 0`
  -- deja que el paso lo fije `agenda_paso_min` de config (15 minutos),
  -- que es como se comporta una clínica que no reserva por bloques
  -- fijos. Vigente desde hace un mes para que las citas de ayer también
  -- caigan dentro de la franja.
  -- ===================================================================
  FOR v_i IN 1..6 LOOP
    INSERT INTO disponibilidad (veterinario_id, consultorio_id, sede_id, dia_semana,
                                hora_inicio, hora_fin, duracion_slot_min, vigente_desde)
    VALUES (v_vet1, v_c1, v_sede, v_i, time '08:00', time '12:00', 0, hoy_bogota() - 30),
           (v_vet1, v_c1, v_sede, v_i, time '14:00', time '18:00', 0, hoy_bogota() - 30),
           (v_vet2, v_c2, v_sede, v_i, time '08:00', time '12:00', 0, hoy_bogota() - 30),
           (v_vet2, v_c2, v_sede, v_i, time '14:00', time '18:00', 0, hoy_bogota() - 30)
    ON CONFLICT (veterinario_id, dia_semana, hora_inicio, vigente_desde) DO NOTHING;
  END LOOP;

  -- ===================================================================
  -- BLOQUE 3 — Las citas.
  --
  -- Se arman en una tabla temporal con desplazamientos relativos para
  -- que la simulación se vea igual a cualquier hora del día. `dia` es el
  -- desplazamiento en días respecto de hoy y `hora` la hora local;
  -- cuando `hora` es NULL la cita se ancla a `v_base` más los minutos de
  -- `desde_base`, que es como se consiguen las citas «dentro de un rato»
  -- sin caer en el pasado.
  -- ===================================================================
  CREATE TEMP TABLE _sim_citas (
    ord         serial,
    dia         int,
    hora        time,
    desde_base  int,
    slot        int,          -- 1 = veterinario 1, 2 = veterinario 2
    tipo        text,
    estado      text,
    idx_pac     int,
    avisada     boolean NOT NULL DEFAULT false,
    notas       text
  ) ON COMMIT DROP;

  -- ¿Alcanza el día para citas futuras? Cargar la simulación a las 23:40
  -- no puede producir una cita de «hoy» que en realidad es de mañana.
  v_futuras := v_base < v_hoy_fin;

  -- --- 3.a Ayer: lo que salió mal, que es lo que hay que poder ver ----
  INSERT INTO _sim_citas (dia, hora, desde_base, slot, tipo, estado, idx_pac, avisada, notas) VALUES
    (-1, time '10:00', NULL, 1, 'general',    'no_asistio', 3, true,  'El dueño no llegó ni avisó.'),
    (-1, time '15:00', NULL, 2, 'vacunacion', 'cancelada',  4, true,  'El dueño canceló la noche anterior.');

  -- --- 3.b Hoy, ya pasadas -------------------------------------------
  INSERT INTO _sim_citas (dia, hora, desde_base, slot, tipo, estado, idx_pac, avisada, notas) VALUES
    (0, time '08:30', NULL, 1, 'general', 'cumplida', 1, true, NULL),
    (0, time '09:30', NULL, 2, 'control', 'cumplida', 2, true, 'Retiro de puntos.');

  -- --- 3.c Hoy, por venir --------------------------------------------
  IF v_futuras THEN
    INSERT INTO _sim_citas (dia, hora, desde_base, slot, tipo, estado, idx_pac, avisada, notas) VALUES
      (0, NULL,   0, 1, 'general',    'confirmada', 5, true, 'El dueño confirmó por el bot.'),
      (0, NULL,  30, 2, 'vacunacion', 'programada', 6, true, NULL),
      (0, NULL,  60, 1, 'control',    'programada', 7, true, NULL),
      (0, NULL, 120, 2, 'general',    'programada', 8, true, NULL);
  ELSE
    RAISE NOTICE 'Es muy tarde para citas de hoy (base %): se generan sólo las de los próximos días.', v_base;
  END IF;

  -- --- 3.d Mañana y los próximos días --------------------------------
  -- `avisada = false`: el recordatorio queda pendiente a propósito, para
  -- que el job «Agenda diaria» tenga qué encolar cuando corra.
  INSERT INTO _sim_citas (dia, hora, desde_base, slot, tipo, estado, idx_pac, avisada, notas) VALUES
    (1, time '08:00', NULL, 2, 'general',    'programada', 1, false, NULL),
    (1, time '08:30', NULL, 1, 'vacunacion', 'programada', 2, false, 'Refuerzo anual.'),
    (1, time '09:30', NULL, 1, 'general',    'confirmada', 3, false, NULL),
    (1, time '10:00', NULL, 2, 'control',    'programada', 4, false, NULL),
    (2, time '09:00', NULL, 1, 'general',    'programada', 5, false, NULL),
    (2, time '14:30', NULL, 2, 'general',    'programada', 6, false, NULL),
    (3, time '11:00', NULL, 1, 'control',    'programada', 7, false, 'Control posoperatorio.'),
    (7, time '10:30', NULL, 2, 'vacunacion', 'programada', 8, false, NULL);

  -- ===================================================================
  -- BLOQUE 4 — Volcado a la tabla real.
  -- La duración sale del tipo de servicio, igual que hace `crear_cita()`.
  -- ===================================================================
  FOR v_i IN SELECT ord FROM _sim_citas ORDER BY ord LOOP
    DECLARE
      c record;
    BEGIN
      SELECT * INTO c FROM _sim_citas WHERE ord = v_i;

      SELECT * INTO v_tipo FROM tipo_servicio WHERE codigo = c.tipo AND activo;

      IF c.hora IS NOT NULL THEN
        v_inicio := ((hoy_bogota() + c.dia) + c.hora) AT TIME ZONE 'America/Bogota';
      ELSE
        v_inicio := v_base + make_interval(mins => c.desde_base);
      END IF;

      v_vet    := CASE c.slot WHEN 1 THEN v_vet1 ELSE v_vet2 END;
      v_cons   := CASE c.slot WHEN 1 THEN v_c1   ELSE v_c2   END;
      v_pac    := v_pacientes[1 + ((c.idx_pac - 1) % array_length(v_pacientes, 1))];
      v_estado := c.estado;

      SELECT dueno_id INTO v_dueno FROM paciente WHERE id = v_pac;

      INSERT INTO cita (sede_id, paciente_id, dueno_id, tipo_servicio_id, veterinario_id,
                        consultorio_id, inicio_at, fin_at, estado, notas, canal_origen,
                        creado_por, confirmada_at, cancelada_at, cancelada_por,
                        motivo_cancelacion, recordatorio_enviado_at, created_at)
      VALUES (v_sede, v_pac, v_dueno, v_tipo.id, v_vet, v_cons,
              v_inicio,
              v_inicio + make_interval(mins => v_tipo.duracion_estimada_min),
              v_estado,
              c.notas,
              CASE WHEN c.ord % 2 = 0 THEN 'telegram' ELSE 'web' END,
              v_vet,
              CASE WHEN v_estado IN ('confirmada','cumplida') THEN v_inicio - interval '1 day' END,
              CASE WHEN v_estado = 'cancelada' THEN v_inicio - interval '10 hours' END,
              CASE WHEN v_estado = 'cancelada' THEN v_vet END,
              CASE WHEN v_estado = 'cancelada' THEN 'El dueño no puede traerla ese día.' END,
              CASE WHEN c.avisada THEN v_inicio - interval '1 day' END,
              LEAST(v_inicio - interval '2 days', now()));

      v_n := v_n + 1;
    END;
  END LOOP;

  PERFORM auditar('simulacion', '100_agenda', 'cargar', NULL, 'sistema', NULL,
                  jsonb_build_object('citas', v_n,
                                     'franjas', (SELECT count(*) FROM disponibilidad
                                                  WHERE veterinario_id IN (v_vet1, v_vet2))),
                  'Carga de simulación de la agenda de citas');

  RAISE NOTICE 'Agenda simulada: % citas y % franjas de disponibilidad.',
               v_n, (SELECT count(*) FROM disponibilidad WHERE veterinario_id IN (v_vet1, v_vet2));
END
$sim$;

COMMIT;
