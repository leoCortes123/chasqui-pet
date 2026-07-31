-- =====================================================================
-- Chasqui Pet — db/demo/030_clinico_demo.sql
-- Datos de demostración del módulo clínico (entregable §13.9). Se carga
-- con:
--
--     bash scripts/cargar-demo.sh
--
-- Qué produce:
--   · 12 dueños y 15 pacientes con historias verosímiles: alergias, un
--     paciente fallecido, uno callejero sin dueño y dos familias con
--     varias mascotas (que es lo que rompe una deduplicación ingenua).
--   · Historia clínica de meses anteriores: ~35 consultas firmadas.
--   · Las consultas de HOY, atadas a los turnos que 010 ya creó: firmadas
--     las de los turnos finalizados, y dos borradores a medio escribir
--     para que la bandeja del portal y el «Seguir consulta» del bot se
--     vean con algo desde el primer minuto.
--
-- Se apoya en 010_turnos_demo.sql (personal y turnos del día). La
-- limpieza de la carga anterior también vive allí, porque hay que soltar
-- las consultas antes de poder borrar los turnos y el personal.
-- Todo lo de aquí lleva `notas = 'DEMO'` en dueño y paciente.
--
-- No ejecute esto sobre una base con historia clínica real.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

DO $demo$
DECLARE
  c_tg_base   constant bigint := 900000000;
  c_tg_tope   constant bigint := 900999999;

  v_sede  uuid;
  v_vets  uuid[];
  v_vet   uuid;

  v_dueno uuid;
  v_pac   uuid;
  v_cons  uuid;
  v_turno record;

  v_pacientes uuid[] := ARRAY[]::uuid[];
  v_total_hist int := 0;
  v_total_hoy  int := 0;
  v_borradores int := 0;

  i int;
  j int;
  v_idx_pac int;
  v_fecha date;
  v_motivo text;
  v_dx text;
  v_plan text;
  v_idx int;

  -- Cuadros clínicos de rutina en una clínica de barrio: motivo,
  -- diagnóstico y plan que se corresponden entre sí.
  v_casos constant text[][] := ARRAY[
    ARRAY['Vómito desde ayer, no come',
          'Gastritis aguda',
          'Dieta blanda 3 días, omeprazol 1 mg/kg cada 24 h por 5 días'],
    ARRAY['Se rasca mucho, pierde pelo en el lomo',
          'Dermatitis alérgica por pulgas',
          'Antipulgas tópico, baño medicado semanal, revisión en 15 días'],
    ARRAY['Cojea de la pata trasera derecha',
          'Esguince de rodilla derecha',
          'Reposo estricto 10 días, antiinflamatorio cada 24 h'],
    ARRAY['Vacunación anual',
          'Paciente sano',
          'Refuerzo de triple felina, desparasitación'],
    ARRAY['Control de peso',
          'Sobrepeso',
          'Cambio a alimento light, medir raciones, control en 30 días'],
    ARRAY['Tose en la noche',
          'Traqueobronquitis infecciosa',
          'Antitusivo 7 días, aislar de otros perros'],
    ARRAY['No quiere caminar, decaído',
          'Fiebre de origen no determinado',
          'Antipirético, hidratación, hemograma solicitado'],
    ARRAY['Le huele mucho el oído',
          'Otitis externa bilateral',
          'Limpieza ótica y gotas cada 12 h por 10 días'],
    ARRAY['Revisión de herida',
          'Herida en cicatrización, sin infección',
          'Curación diaria, retirar puntos en 5 días'],
    ARRAY['Diarrea hace dos días',
          'Enteritis parasitaria',
          'Desparasitante, probiótico 5 días, dieta blanda']
  ];

  -- nombre, especie, raza, sexo, meses de edad, alergias, señas, peso kg.
  -- El peso va aquí y no calculado: un periquito de 22 kg arruina la
  -- credibilidad de una demostración más rápido que cualquier error de
  -- programación.
  v_animales constant text[][] := ARRAY[
    ARRAY['Firulais','perro','Criollo','macho','84','','Manchas cafés en el lomo','18.4'],
    ARRAY['Luna','perro','Labrador','hembra','36','','Collar rojo','28.7'],
    ARRAY['Michifú','gato','Criollo','macho','60','Penicilina','Blanco con gris','4.6'],
    ARRAY['Rocky','perro','Pitbull','macho','48','','Cicatriz en la oreja izquierda','26.2'],
    ARRAY['Nala','gato','Siamés','hembra','24','','Ojos azules','3.8'],
    ARRAY['Bruno','perro','Golden Retriever','macho','96','Ivermectina','Dorado claro','32.5'],
    ARRAY['Pelusa','conejo','Angora','hembra','18','','Blanco','2.1'],
    ARRAY['Toby','perro','Schnauzer','macho','120','','Barba canosa','8.3'],
    ARRAY['Kira','perro','Pastor alemán','hembra','30','','Negra y fuego','30.1'],
    ARRAY['Simba','gato','Naranja atigrado','macho','12','','Cola corta','4.1'],
    ARRAY['Coco','ave','Periquito','macho','9','','Verde y amarillo','0.06'],
    ARRAY['Maya','gato','Criollo','hembra','72','','Tricolor','5.2'],
    ARRAY['Duque','perro','Beagle','macho','54','','Orejas largas','12.8'],
    ARRAY['Canela','perro','Criollo','hembra','108','','Café, cojea de nacimiento','16.9'],
    ARRAY['Tommy','perro','Criollo','macho','6','','Callejero, sin dueño conocido','9.4']
  ];

  -- nombre, teléfono, barrio. El paciente i pertenece al dueño de la
  -- posición v_asignacion[i]; hay dos familias con dos mascotas cada una.
  v_duenos constant text[][] := ARRAY[
    ARRAY['María Fernanda Gómez Ruiz','300 412 7788','Kennedy'],
    ARRAY['Jorge Enrique Salazar','311 289 4410','Suba'],
    ARRAY['Diana Carolina Peña','320 776 1123','Engativá'],
    ARRAY['Luis Alberto Mendoza','313 902 5567','Bosa'],
    ARRAY['Sandra Milena Torres','301 445 8899','Fontibón'],
    ARRAY['Óscar Iván Betancur','315 220 3341','Chapinero'],
    ARRAY['Claudia Patricia Rojas','318 667 2290','Usaquén'],
    ARRAY['Andrés Felipe Cárdenas','312 558 7734','Teusaquillo'],
    ARRAY['Martha Lucía Vargas','304 331 9987','Puente Aranda'],
    ARRAY['Julián Esteban Ramírez','316 774 5520','Barrios Unidos'],
    ARRAY['Nubia Esperanza Castro','305 118 6674','Ciudad Bolívar'],
    ARRAY['Camilo Alberto Duarte','319 445 2201','San Cristóbal']
  ];

  -- 15 pacientes repartidos entre 12 dueños (0 = sin dueño).
  v_asignacion constant int[] := ARRAY[1,1,2,3,4,5,6,7,8,9,10,11,12,2,0];
  v_duenos_id uuid[] := ARRAY[]::uuid[];
BEGIN
  SELECT id INTO v_sede FROM sede WHERE activa ORDER BY created_at LIMIT 1;
  IF v_sede IS NULL THEN
    RAISE EXCEPTION 'No hay sede activa. Ejecute primero las migraciones.';
  END IF;

  SELECT array_agg(u.id ORDER BY u.created_at) INTO v_vets
    FROM usuario u
    JOIN usuario_rol ur ON ur.usuario_id = u.id AND ur.rol_codigo = 'veterinario'
   WHERE u.telegram_user_id BETWEEN c_tg_base AND c_tg_tope;

  IF v_vets IS NULL THEN
    RAISE EXCEPTION 'No hay veterinarios de demo. Cargue primero 010_turnos_demo.sql.';
  END IF;

  -- ===================================================================
  -- BLOQUE 1 — Dueños
  --
  -- Sólo el nombre es obligatorio (§8.1). Aquí todos tienen teléfono
  -- porque es lo normal, pero el sistema no lo exige.
  -- ===================================================================
  FOR i IN 1 .. array_length(v_duenos, 1) LOOP
    INSERT INTO dueno (nombre_completo, telefono, barrio, notas,
                       consentimiento_datos, consentimiento_fecha)
    VALUES (v_duenos[i][1], v_duenos[i][2], v_duenos[i][3], 'DEMO',
            -- Dos de cada tres autorizan el uso de su Telegram; el resto
            -- queda sin canal, que es lo que pasa en la vida real y lo
            -- que el worker tiene que saber respetar (§12).
            i % 3 <> 0,
            CASE WHEN i % 3 <> 0 THEN now() - make_interval(days => i * 3) END)
    RETURNING id INTO v_dueno;

    v_duenos_id := v_duenos_id || v_dueno;
  END LOOP;

  -- ===================================================================
  -- BLOQUE 2 — Pacientes
  -- ===================================================================
  FOR i IN 1 .. array_length(v_animales, 1) LOOP
    INSERT INTO paciente (dueno_id, nombre, especie, raza, sexo, esterilizado,
                          fecha_nacimiento_aprox, color_senas, alergias, estado, notas)
    VALUES (CASE WHEN v_asignacion[i] = 0 THEN NULL
                 ELSE v_duenos_id[v_asignacion[i]] END,
            v_animales[i][1], v_animales[i][2], v_animales[i][3], v_animales[i][4],
            i % 2 = 0,
            hoy_bogota() - (v_animales[i][5]::int * 30) - (i * 7),
            NULLIF(v_animales[i][7], ''),
            NULLIF(v_animales[i][6], ''),
            -- Un paciente fallecido: la historia clínica no desaparece
            -- cuando el animal muere, y la ficha tiene que decirlo.
            CASE WHEN i = 8 THEN 'fallecido' ELSE 'activo' END,
            'DEMO')
    RETURNING id INTO v_pac;

    v_pacientes := v_pacientes || v_pac;
  END LOOP;

  UPDATE paciente SET fecha_fallecimiento = hoy_bogota() - 45
   WHERE id = v_pacientes[8];

  -- ===================================================================
  -- BLOQUE 3 — Historia clínica anterior
  --
  -- Consultas firmadas de meses pasados, sin turno: en la vida real esa
  -- historia viene de antes del sistema. Se insertan directo y se firman
  -- con fecha propia, porque firmar_consulta() sella con now() y aquí
  -- hace falta que el pasado parezca pasado.
  -- ===================================================================
  FOR i IN 1 .. array_length(v_pacientes, 1) LOOP
    -- Entre 1 y 4 consultas por paciente; el callejero no tiene historia.
    FOR j IN 1 .. CASE WHEN i = 15 THEN 0 ELSE 1 + (i % 4) END LOOP
      v_idx  := 1 + ((i + j) % array_length(v_casos, 1));
      v_motivo := v_casos[v_idx][1];
      v_dx     := v_casos[v_idx][2];
      v_plan   := v_casos[v_idx][3];
      v_fecha  := hoy_bogota() - (j * 45) - (i * 3);
      v_vet    := v_vets[1 + ((i + j) % array_length(v_vets, 1))];

      INSERT INTO consulta (paciente_id, dueno_id, veterinario_id, sede_id, fecha,
                            motivo_consulta, anamnesis, examen_fisico,
                            diagnostico_presuntivo, plan_tratamiento, recomendaciones,
                            estado, canal_origen, created_at, updated_at,
                            firmada_at, firmada_por)
      VALUES (v_pacientes[i],
              (SELECT dueno_id FROM paciente WHERE id = v_pacientes[i]),
              v_vet, v_sede, v_fecha,
              v_motivo,
              CASE WHEN j = 1 THEN 'El dueño refiere que empezó hace dos días.' END,
              jsonb_build_object(
                -- Alrededor del peso propio del animal, no de su índice.
                'peso_kg', round((v_animales[i][8]::numeric * (1 + ((j % 3) - 1) * 0.04))::numeric, 2),
                'temperatura_c', round((38.0 + ((i + j) % 12) * 0.1)::numeric, 1),
                'fc', 80 + ((i * 7 + j) % 60),
                'fr', 18 + ((i + j) % 14),
                'mucosas', (ARRAY['rosadas','rosadas','rosadas','palidas'])[1 + ((i + j) % 4)],
                'hidratacion', (ARRAY['normal','normal','leve'])[1 + ((i + j) % 3)],
                'cc', (ARRAY['ideal','ideal','delgado','sobrepeso'])[1 + ((i + j) % 4)]),
              v_dx, v_plan,
              CASE WHEN j % 2 = 0 THEN 'Volver si no mejora en 48 horas.' END,
              'firmada', 'telegram',
              v_fecha + interval '10 hours',
              v_fecha + interval '10 hours 20 minutes',
              v_fecha + interval '10 hours 20 minutes',
              v_vet);

      v_total_hist := v_total_hist + 1;
    END LOOP;
  END LOOP;

  -- El peso de la ficha es el de la última consulta firmada (§8.1).
  UPDATE paciente p
     SET peso_ultimo_kg = x.peso, peso_ultimo_at = x.cuando
    FROM (SELECT DISTINCT ON (c.paciente_id)
                 c.paciente_id, (c.examen_fisico->>'peso_kg')::numeric AS peso,
                 c.firmada_at AS cuando
            FROM consulta c
           WHERE c.estado = 'firmada' AND c.examen_fisico ? 'peso_kg'
           ORDER BY c.paciente_id, c.fecha DESC) x
   WHERE p.id = x.paciente_id;

  -- ===================================================================
  -- BLOQUE 4 — La jornada de hoy: turnos con paciente y consulta
  --
  -- Se recorren los turnos que creó 010 y se les pone dueño y paciente.
  -- Los finalizados quedan con consulta firmada; el que está en atención
  -- y uno de los llamados quedan en borrador, que es justo lo que hay
  -- que poder enseñar: el sistema guarda a medias sin perder nada.
  -- ===================================================================
  i := 0;
  FOR v_turno IN
    -- De atrás hacia adelante: los turnos vivos y los últimos atendidos
    -- son los que se van a ver en la demostración, y son los que reciben
    -- ficha. Los de primera hora quedan sin paciente, que es lo que pasa
    -- en una clínica que está adoptando el sistema.
    SELECT t.id, t.estado, t.veterinario_id, t.consultorio_id, t.created_at,
           t.en_atencion_at, t.finalizado_at, t.telegram_chat_id
      FROM turno t
     WHERE t.fecha = hoy_bogota()
       -- Sólo los que alguien atendió: un turno en espera todavía no
       -- tiene consulta ni tiene por qué tener ficha abierta.
       AND t.estado IN ('finalizado','en_atencion','llamado')
       AND t.veterinario_id IS NOT NULL
     ORDER BY t.numero_secuencial DESC
  LOOP
    i := i + 1;

    -- Un paciente atiende como mucho un turno al día. Cuando se acaba el
    -- listado, los turnos restantes se quedan sin ficha.
    EXIT WHEN i > array_length(v_pacientes, 1);

    v_idx_pac := i;
    -- Ni el paciente fallecido ni el callejero sin dueño entran en la
    -- jornada de hoy por esta vía.
    CONTINUE WHEN v_idx_pac = 8;
    v_pac := v_pacientes[v_idx_pac];

    SELECT dueno_id INTO v_dueno FROM paciente WHERE id = v_pac;

    UPDATE turno SET paciente_id = v_pac, dueno_id = v_dueno WHERE id = v_turno.id;

    -- El turno que pidió el dueño por QR trae su chat: si consintió, ese
    -- es el canal por el que recibirá el resumen de la consulta (§12).
    IF v_turno.telegram_chat_id IS NOT NULL AND v_dueno IS NOT NULL THEN
      UPDATE dueno SET telegram_chat_id = v_turno.telegram_chat_id
       WHERE id = v_dueno AND consentimiento_datos AND telegram_chat_id IS NULL;
    END IF;

    v_idx := 1 + (i % array_length(v_casos, 1));

    INSERT INTO consulta (turno_id, paciente_id, dueno_id, veterinario_id,
                          consultorio_id, sede_id, fecha,
                          motivo_consulta, examen_fisico,
                          diagnostico_presuntivo, plan_tratamiento, recomendaciones,
                          proxima_revision, estado, canal_origen,
                          created_at, updated_at, firmada_at, firmada_por)
    VALUES (v_turno.id, v_pac, v_dueno, v_turno.veterinario_id,
            v_turno.consultorio_id, v_sede, hoy_bogota(),
            v_casos[v_idx][1],
            jsonb_build_object(
              'peso_kg', round((v_animales[v_idx_pac][8]::numeric)::numeric, 2),
              'temperatura_c', round((38.2 + (i % 9) * 0.1)::numeric, 1),
              'mucosas', 'rosadas',
              'hidratacion', 'normal'),
            -- Los borradores se dejan a medias a propósito: sin
            -- diagnóstico ni plan no se pueden firmar, y eso es lo que
            -- hay que ver en la demostración.
            CASE WHEN v_turno.estado = 'finalizado' THEN v_casos[v_idx][2] END,
            CASE WHEN v_turno.estado = 'finalizado' THEN v_casos[v_idx][3] END,
            CASE WHEN v_turno.estado = 'finalizado' AND i % 3 = 0
                 THEN 'Volver si no mejora en 48 horas.' END,
            CASE WHEN v_turno.estado = 'finalizado' AND i % 5 = 0
                 THEN hoy_bogota() + 15 END,
            CASE WHEN v_turno.estado = 'finalizado' THEN 'firmada' ELSE 'borrador' END,
            'telegram',
            COALESCE(v_turno.en_atencion_at, v_turno.created_at),
            COALESCE(v_turno.finalizado_at, v_turno.en_atencion_at, v_turno.created_at),
            CASE WHEN v_turno.estado = 'finalizado' THEN v_turno.finalizado_at END,
            CASE WHEN v_turno.estado = 'finalizado' THEN v_turno.veterinario_id END)
    RETURNING id INTO v_cons;

    UPDATE turno SET consulta_id = v_cons WHERE id = v_turno.id;

    IF v_turno.estado = 'finalizado' THEN
      v_total_hoy := v_total_hoy + 1;
    ELSE
      v_borradores := v_borradores + 1;
    END IF;
  END LOOP;

  -- Una adenda sobre una consulta ya firmada: lo firmado no se edita
  -- (§8.2.4) y la demostración tiene que mostrar cómo se corrige.
  SELECT id INTO v_cons FROM consulta
   WHERE estado = 'firmada' AND fecha = hoy_bogota()
   ORDER BY firmada_at LIMIT 1;

  IF v_cons IS NOT NULL THEN
    INSERT INTO consulta_adenda (consulta_id, texto, usuario_id, canal, created_at)
    SELECT v_cons,
           'Se omitió anotar que el dueño reporta un episodio similar el mes pasado.',
           c.veterinario_id, 'telegram', c.firmada_at + interval '25 minutes'
      FROM consulta c WHERE c.id = v_cons;
  END IF;

  -- Las salidas de medicamento las creó 020_inventario_demo, que corre
  -- antes: en ese momento los turnos todavía no tenían paciente ni
  -- consulta. Se les completa ahora el vínculo, que es lo que en
  -- operación real hace `salida_medicamento()` sola al despachar. Sin
  -- esto, la trazabilidad de lote (§10.9) y el reporte de consumo por
  -- paciente saldrían vacíos en la presentación, que es justo lo que hay
  -- que enseñar.
  ALTER TABLE movimiento_inventario DISABLE TRIGGER movimiento_inmutable;

  UPDATE movimiento_inventario mi
     SET paciente_id = t.paciente_id,
         consulta_id = COALESCE(mi.consulta_id, t.consulta_id)
    FROM turno t
   WHERE t.id = mi.turno_id
     AND mi.tipo = 'salida'
     AND mi.paciente_id IS NULL
     AND t.paciente_id IS NOT NULL;

  ALTER TABLE movimiento_inventario ENABLE TRIGGER movimiento_inmutable;

  PERFORM auditar('demo', '030_clinico_demo', 'cargar', NULL, 'sistema', NULL,
                  jsonb_build_object('duenos', array_length(v_duenos_id, 1),
                                     'pacientes', array_length(v_pacientes, 1),
                                     'consultas_historicas', v_total_hist,
                                     'consultas_hoy', v_total_hoy,
                                     'borradores', v_borradores),
                  'Carga de datos de demostración del módulo clínico');

  RAISE NOTICE 'Demo clínica: % dueños, % pacientes, % consultas históricas, % de hoy (% en borrador).',
               array_length(v_duenos_id, 1), array_length(v_pacientes, 1),
               v_total_hist, v_total_hoy + v_borradores, v_borradores;
END
$demo$;

COMMIT;
