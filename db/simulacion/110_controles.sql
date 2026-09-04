-- =====================================================================
-- Chasqui Pet — db/simulacion/110_controles.sql
-- Controles pendientes (Fase B2) para el día en curso. Se carga con:
--
--     bash scripts/simular.sh dia
--
-- Un control no es una tabla: es una consulta firmada con
-- `proxima_revision` puesta (§B2). Este archivo le pone fecha de revisión
-- a las últimas consultas firmadas de los pacientes de simulación, con
-- horizontes escogidos para que cada caso de la bandeja tenga al menos
-- un ejemplo:
--
--   · uno vencido hace 6 días (sale marcado en rojo),
--   · uno para hoy,
--   · uno dentro de 3 días —el valor de `control_aviso_dias_antes`—, que
--     es el que `controles_avisar()` va a encolar cuando corra el job,
--   · uno dentro de 3 días YA avisado, para comprobar que no se avisa
--     dos veces,
--   · uno dentro de 8 y otro dentro de 15 días,
--   · uno dentro de 5 días que YA tiene su cita agendada, que es el caso
--     que `controles_pendientes()` tiene que dejar fuera de la bandeja.
--
-- Depende de db/demo/030_clinico_demo.sql (historia clínica) y de
-- db/simulacion/100_agenda.sql (veterinarios con franja, para la cita
-- del control ya agendado).
--
-- Se escribe directo sobre la consulta firmada, desactivando el trigger
-- de inmutabilidad dentro de la transacción. En operación real eso no se
-- hace nunca —lo firmado no se toca (§8.2.4)— pero aquí no se está
-- corrigiendo una historia clínica: se está fabricando el pasado que la
-- prueba necesita.
--
-- Re-ejecutable: primero limpia las fechas de revisión y los avisos de
-- los pacientes de simulación.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

DO $sim$
DECLARE
  c_tg_base constant bigint := 900000000;
  c_tg_tope constant bigint := 900999999;

  -- Días hasta la revisión, en el orden en que se reparten. El NULL de
  -- la séptima posición no existe: las siete entradas se usan todas.
  v_horizontes constant int[] := ARRAY[-6, 0, 3, 3, 8, 15, 5];

  v_sede   uuid;
  v_vet    uuid;
  v_cons   uuid;
  v_tipo   uuid;
  v_pacientes uuid[];
  v_consulta  uuid;
  v_dueno     uuid;
  v_pac       uuid;
  v_inicio timestamptz;
  v_i      int;
  v_n      int := 0;
BEGIN
  SELECT id INTO v_sede FROM sede WHERE activa ORDER BY created_at LIMIT 1;

  SELECT u.id INTO v_vet
    FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id AND ur.rol_codigo = 'veterinario'
   WHERE u.telegram_user_id BETWEEN c_tg_base AND c_tg_tope
   ORDER BY u.telegram_user_id LIMIT 1;

  IF v_vet IS NULL THEN
    RAISE EXCEPTION 'No hay veterinarios de simulación. Cargue antes db/demo/010_turnos_demo.sql.';
  END IF;

  SELECT id INTO v_cons FROM consultorio
   WHERE sede_id = v_sede AND activo ORDER BY orden, nombre LIMIT 1;

  SELECT id INTO v_tipo FROM tipo_servicio WHERE codigo = 'control' AND activo;

  -- Orden por nombre y no por created_at: db/demo/030 inserta los quince
  -- pacientes en la misma transacción, así que todos comparten el
  -- created_at y ordenar por él devuelve un orden distinto en cada
  -- carga. Se excluye al callejero sin dueño: una cita, un control o una
  -- remisión necesitan a quién avisar.
  SELECT array_agg(id ORDER BY nombre) INTO v_pacientes
    FROM paciente
   WHERE notas = 'DEMO' AND estado = 'activo' AND dueno_id IS NOT NULL;

  IF v_pacientes IS NULL OR array_length(v_pacientes, 1) < array_length(v_horizontes, 1) THEN
    RAISE EXCEPTION 'Faltan pacientes de simulación. Cargue antes db/demo/030_clinico_demo.sql.';
  END IF;

  ALTER TABLE consulta DISABLE TRIGGER consulta_no_editar_firmada;

  -- ===================================================================
  -- BLOQUE 1 — Limpieza de la carga anterior.
  -- ===================================================================
  DELETE FROM aviso_control_enviado a
   USING consulta c
   WHERE a.consulta_id = c.id AND c.paciente_id = ANY (v_pacientes);

  UPDATE consulta SET proxima_revision = NULL
   WHERE paciente_id = ANY (v_pacientes)
     AND proxima_revision IS NOT NULL;

  -- ===================================================================
  -- BLOQUE 2 — Fechas de revisión.
  -- A cada paciente le toca su ÚLTIMA consulta firmada: es la que un
  -- veterinario habría usado para citar el control.
  -- ===================================================================
  FOR v_i IN 1 .. array_length(v_horizontes, 1) LOOP
    v_pac := v_pacientes[v_i];

    SELECT c.id, c.dueno_id INTO v_consulta, v_dueno
      FROM consulta c
     WHERE c.paciente_id = v_pac AND c.estado = 'firmada'
     ORDER BY c.fecha DESC, c.firmada_at DESC
     LIMIT 1;

    CONTINUE WHEN v_consulta IS NULL;

    UPDATE consulta
       SET proxima_revision = hoy_bogota() + v_horizontes[v_i],
           recomendaciones  = COALESCE(recomendaciones, 'Traerla a revisión en la fecha indicada.')
     WHERE id = v_consulta;

    -- El cuarto caso ya recibió su aviso: la reja de `controles_avisar()`
    -- es esta tabla, y hay que poder comprobar que no manda dos veces.
    IF v_i = 4 THEN
      INSERT INTO aviso_control_enviado (consulta_id, tipo, enviado_at)
      VALUES (v_consulta, 'proximo', now() - interval '2 hours')
      ON CONFLICT DO NOTHING;
    END IF;

    -- El séptimo ya tiene su cita: `controles_pendientes()` lo descarta
    -- por `control_cita()`, y así se ve que la bandeja no repite trabajo.
    IF v_i = 7 THEN
      v_inicio := ((hoy_bogota() + 5) + time '16:00') AT TIME ZONE 'America/Bogota';

      INSERT INTO cita (sede_id, paciente_id, dueno_id, tipo_servicio_id, veterinario_id,
                        consultorio_id, inicio_at, fin_at, estado, notas, canal_origen,
                        creado_por, consulta_origen_id)
      SELECT v_sede, v_pac, v_dueno, v_tipo, v_vet, v_cons,
             v_inicio, v_inicio + interval '10 minutes', 'programada',
             'Control agendado desde la consulta.', 'telegram', v_vet, v_consulta
       WHERE NOT EXISTS (SELECT 1 FROM cita WHERE consulta_origen_id = v_consulta);
    END IF;

    v_n := v_n + 1;
  END LOOP;

  ALTER TABLE consulta ENABLE TRIGGER consulta_no_editar_firmada;

  PERFORM auditar('simulacion', '110_controles', 'cargar', NULL, 'sistema', NULL,
                  jsonb_build_object('controles', v_n),
                  'Carga de simulación de controles pendientes');

  RAISE NOTICE 'Controles simulados: % consultas con próxima revisión.', v_n;
END
$sim$;

COMMIT;
