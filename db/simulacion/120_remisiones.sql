-- =====================================================================
-- Chasqui Pet — db/simulacion/120_remisiones.sql
-- Remisiones externas (Fase B3) para el día en curso. Se carga con:
--
--     bash scripts/simular.sh dia
--
-- Qué produce, un caso por estado del ciclo:
--   · Dos pendientes en plazo (una de laboratorio pedida hoy y una de
--     imágenes de anteayer): son las que el bot lista en «🧪 Remisiones».
--   · Dos pendientes VENCIDAS —el resultado se esperaba ayer y hace
--     cuatro días—: son las que `alertas_remisiones()` reporta y las que
--     hacen que el job «Remisiones diarias» de n8n tenga algo que decir.
--   · Una recibida con su resultado escrito y el dueño ya avisado, que
--     es el final feliz del ciclo.
--   · Una anulada con motivo, para que el filtro por estado se vea.
--
-- Depende de db/demo/030_clinico_demo.sql (pacientes, dueños y consultas
-- firmadas de las que cuelga cada remisión).
--
-- Se insertan directo y no por `crear_remision()` porque esa función
-- fecha la solicitud en el día de hoy y esta simulación necesita
-- remisiones pedidas hace días para que las vencidas existan. El resto
-- del modelo se respeta: cada remisión apunta a una consulta firmada del
-- mismo paciente y el resultado cuelga de su remisión.
--
-- Re-ejecutable: borra las remisiones de los pacientes de simulación
-- antes de volver a generarlas.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

DO $sim$
DECLARE
  c_tg_base constant bigint := 900000000;
  c_tg_tope constant bigint := 900999999;

  -- tipo, destino, exámenes, días desde la solicitud, días de plazo,
  -- estado. El plazo se cuenta desde la solicitud: solicitud + plazo es
  -- la fecha esperada, y si ya pasó, la remisión está vencida.
  v_casos constant text[][] := ARRAY[
    ARRAY['laboratorio','Laboratorio VetLab','Hemograma completo y química sanguínea','0','5','pendiente'],
    ARRAY['imagenes','Centro de Imágenes Animalia','Radiografía de tórax, dos proyecciones','2','4','pendiente'],
    ARRAY['laboratorio','Laboratorio VetLab','Coprológico seriado','6','5','pendiente'],
    ARRAY['especialista','Dra. Restrepo — Dermatología','Valoración dermatológica y raspado de piel','9','5','pendiente'],
    ARRAY['laboratorio','Laboratorio VetLab','Perfil renal','8','5','recibida'],
    ARRAY['otro','Banco de sangre veterinario','Tipificación sanguínea','4','7','anulada']
  ];

  v_sede uuid;
  v_vet  uuid;
  v_pacientes uuid[];
  v_pac      uuid;
  v_dueno    uuid;
  v_consulta uuid;
  v_rem      uuid;
  v_solicitud date;
  v_i int;
  v_n int := 0;
BEGIN
  SELECT id INTO v_sede FROM sede WHERE activa ORDER BY created_at LIMIT 1;

  SELECT u.id INTO v_vet
    FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id AND ur.rol_codigo = 'veterinario'
   WHERE u.telegram_user_id BETWEEN c_tg_base AND c_tg_tope
   ORDER BY u.telegram_user_id LIMIT 1;

  IF v_vet IS NULL THEN
    RAISE EXCEPTION 'No hay veterinarios de simulación. Cargue antes db/demo/010_turnos_demo.sql.';
  END IF;

  -- Orden por nombre y no por created_at: db/demo/030 inserta los quince
  -- pacientes en la misma transacción, así que todos comparten el
  -- created_at y ordenar por él devuelve un orden distinto en cada
  -- carga. Se excluye al callejero sin dueño: una cita, un control o una
  -- remisión necesitan a quién avisar.
  SELECT array_agg(id ORDER BY nombre) INTO v_pacientes
    FROM paciente
   WHERE notas = 'DEMO' AND estado = 'activo' AND dueno_id IS NOT NULL;

  IF v_pacientes IS NULL OR array_length(v_pacientes, 1) < array_length(v_casos, 1) THEN
    RAISE EXCEPTION 'Faltan pacientes de simulación. Cargue antes db/demo/030_clinico_demo.sql.';
  END IF;

  -- ===================================================================
  -- BLOQUE 1 — Limpieza de la carga anterior.
  -- El resultado se va primero: cuelga de la remisión.
  -- ===================================================================
  DELETE FROM resultado_remision r
   USING remision m
   WHERE r.remision_id = m.id AND m.paciente_id = ANY (v_pacientes);

  DELETE FROM remision WHERE paciente_id = ANY (v_pacientes);

  -- ===================================================================
  -- BLOQUE 2 — Las remisiones.
  -- ===================================================================
  FOR v_i IN 1 .. array_length(v_casos, 1) LOOP
    -- Se empieza por el paciente 3 para no chocar con los que ya cargan
    -- control y cita: así la simulación reparte los casos entre fichas
    -- distintas y ninguna mascota concentra todo.
    v_pac := v_pacientes[1 + ((v_i + 1) % array_length(v_pacientes, 1))];

    SELECT dueno_id INTO v_dueno FROM paciente WHERE id = v_pac;

    SELECT c.id INTO v_consulta
      FROM consulta c
     WHERE c.paciente_id = v_pac AND c.estado = 'firmada'
     ORDER BY c.fecha DESC, c.firmada_at DESC
     LIMIT 1;

    v_solicitud := hoy_bogota() - v_casos[v_i][4]::int;

    INSERT INTO remision (paciente_id, dueno_id, consulta_id, sede_id, tipo, destino,
                          examenes, motivo, estado, fecha_solicitud, fecha_esperada,
                          recibida_at, recibida_por, anulada_at, anulada_por,
                          motivo_anulacion, aviso_dueno_at, solicitada_por,
                          canal_origen, created_at)
    VALUES (v_pac, v_dueno, v_consulta, v_sede,
            v_casos[v_i][1], v_casos[v_i][2], v_casos[v_i][3],
            'Solicitada durante la consulta.',
            v_casos[v_i][6],
            v_solicitud,
            v_solicitud + v_casos[v_i][5]::int,
            CASE WHEN v_casos[v_i][6] = 'recibida'
                 THEN now() - interval '20 hours' END,
            CASE WHEN v_casos[v_i][6] = 'recibida' THEN v_vet END,
            CASE WHEN v_casos[v_i][6] = 'anulada'
                 THEN now() - interval '2 days' END,
            CASE WHEN v_casos[v_i][6] = 'anulada' THEN v_vet END,
            CASE WHEN v_casos[v_i][6] = 'anulada'
                 THEN 'El dueño prefirió hacer los exámenes por su cuenta.' END,
            CASE WHEN v_casos[v_i][6] = 'recibida'
                 THEN now() - interval '19 hours' END,
            v_vet,
            CASE WHEN v_i % 2 = 0 THEN 'telegram' ELSE 'web' END,
            v_solicitud::timestamptz + interval '11 hours')
    RETURNING id INTO v_rem;

    IF v_casos[v_i][6] = 'recibida' THEN
      INSERT INTO resultado_remision (remision_id, texto, cargado_por, canal, created_at)
      VALUES (v_rem,
              'Creatinina 1.1 mg/dL y BUN 22 mg/dL, ambos dentro de rango. '
              'Densidad urinaria normal. No hay evidencia de falla renal; '
              'se sugiere repetir el perfil en tres meses.',
              v_vet, 'telegram', now() - interval '20 hours');
    END IF;

    v_n := v_n + 1;
  END LOOP;

  PERFORM auditar('simulacion', '120_remisiones', 'cargar', NULL, 'sistema', NULL,
                  jsonb_build_object('remisiones', v_n),
                  'Carga de simulación de remisiones externas');

  RAISE NOTICE 'Remisiones simuladas: % (% vencidas).',
    v_n,
    (SELECT count(*) FROM remision
      WHERE estado = 'pendiente' AND fecha_esperada < hoy_bogota());
END
$sim$;

COMMIT;
