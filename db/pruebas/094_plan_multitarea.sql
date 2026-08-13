-- =====================================================================
-- Fase B4 — plan multi-tarea con confirmación mixta.
--
-- Lo que se protege aquí:
--
--   · C6.9 sigue en pie DENTRO del plan: anotar pasos no ejecuta nada.
--     Es el riesgo nuevo de la fase —antes cada escritura era una
--     propuesta suelta y ahora son varias— y por eso se comprueba
--     contando filas de negocio, no leyendo el código.
--   · el encadenamiento: el `paciente_id` que produce el paso 1 llega al
--     paso 2 sin que nadie lo escriba. Es el trabajo técnico central de
--     la fase.
--   · la confirmación mixta: el botón del bloque NO arrastra un paso
--     crítico. Un despacho de inventario no se ejecuta nunca «de paso».
--   · un plan a medias es un estado normal: saltar un paso deja el plan
--     coherente y cerrado.
-- =====================================================================
BEGIN;
SELECT plan(22);

-- --- Un plan de tres pasos, anotado como lo haría el modelo ------------
CREATE TEMP TABLE p1 AS
SELECT ia_llamar_plan(prueba.superadmin(), 700400, prueba.sede(),
         'preparar_alta_paciente',
         '{"mascota_nombre":"Rocky Plan","especie":"perro","dueno_nombre":"Ana Plan","dueno_telefono":"3009998877"}'::jsonb,
         NULL) AS r;

SELECT ok((SELECT (r->>'ok')::boolean FROM p1), 'el paso 1 se anota sin ejecutar nada');
SELECT is((SELECT (r->>'paso')::int FROM p1), 1, 'y queda en la posición 1 del plan');

CREATE TEMP TABLE plan_id AS SELECT ((SELECT r FROM p1)->>'plan_id')::uuid AS id;

-- El paso 2 usa un dato que todavía no existe: el de la mascota que crea
-- el paso 1. El modelo no lo inventa, lo referencia.
CREATE TEMP TABLE p2 AS
SELECT ia_llamar_plan(prueba.superadmin(), 700400, prueba.sede(),
         'preparar_consulta_clinica',
         '{"paciente_id":"@paso1.paciente_id","motivo_consulta":"Vomito de dos dias","diagnostico_presuntivo":"Gastroenteritis"}'::jsonb,
         (SELECT id FROM plan_id)) AS r;

SELECT is((SELECT (r->>'paso')::int FROM p2), 2, 'el paso 2 se anota con su referencia al paso 1');
SELECT is((SELECT estado FROM ia_accion_pendiente
            WHERE plan_id = (SELECT id FROM plan_id) AND orden = 2),
          'planeada',
          'y queda «planeada»: no se prepara hasta que le toque el turno');

-- El paso 3 toca inventario: es crítico y no puede confirmarse en bloque.
CREATE TEMP TABLE t_lote AS
SELECT prueba.lote(prueba.medicamento('Medicamento del plan'),
                   hoy_bogota() + 180, 50) AS id;

SELECT is((ia_llamar_plan(prueba.superadmin(), 700400, prueba.sede(),
            'registrar_salida_medicamento',
            jsonb_build_object('lote_id', (SELECT id FROM t_lote), 'cantidad', 2),
            (SELECT id FROM plan_id))->>'paso')::int, 3,
          'el paso 3, que toca inventario, se anota igual que los demás');

-- --- C6.9 dentro del plan: nada se ejecutó todavía ---------------------
SELECT is((SELECT count(*)::int FROM paciente WHERE nombre = 'Rocky Plan'), 0,
          'anotar el plan no creó ninguna mascota');
SELECT is((SELECT count(*)::int FROM movimiento_inventario
            WHERE lote_id = (SELECT id FROM t_lote) AND tipo = 'salida'), 0,
          'anotar el plan no movió el inventario');

-- Una llamada repetida no duplica el paso: el modelo insiste más de lo
-- que uno quisiera, y dos pasos iguales serían dos escrituras.
SELECT ok((ia_llamar_plan(prueba.superadmin(), 700400, prueba.sede(),
            'registrar_salida_medicamento',
            jsonb_build_object('lote_id', (SELECT id FROM t_lote), 'cantidad', 2),
            (SELECT id FROM plan_id))->>'repetida')::boolean,
          'un paso idéntico no se anota dos veces');

-- Permisos: la segunda reja está antes de anotar, no después.
SELECT is(ia_llamar_plan(prueba.don_nadie(), 700401, prueba.sede(),
            'registrar_salida_medicamento', '{}'::jsonb, NULL)->>'ok', 'false',
          'quien no tiene el permiso no puede ni anotar el paso');

-- --- La tarjeta del plan ----------------------------------------------
CREATE TEMP TABLE cierre AS SELECT ia_plan_cerrar((SELECT id FROM plan_id)) AS r;

SELECT is((SELECT (r->>'pasos')::int FROM cierre), 3,
          'el plan se cierra con sus tres pasos');
SELECT ok((SELECT r->'tarjeta'->>'botones' FROM cierre) LIKE '%ia:pblo:%',
          'y la tarjeta ofrece el botón del bloque, no una confirmación suelta');

-- --- Confirmar el bloque: se encadena y se detiene en el crítico -------
CREATE TEMP TABLE bloque AS
SELECT ia_plan_confirmar_bloque((SELECT id FROM plan_id), prueba.superadmin()) AS r;

SELECT is((SELECT (r->>'pasos_hechos')::int FROM bloque), 2,
          'el bloque ejecuta los dos pasos no críticos y se detiene');

SELECT is((SELECT count(*)::int FROM paciente WHERE nombre = 'Rocky Plan'), 1,
          'la mascota del paso 1 quedó creada');

-- El corazón de la fase: el paso 2 abrió la consulta de la mascota que
-- creó el paso 1, sin que nadie escribiera ese identificador.
SELECT is((SELECT count(*)::int FROM consulta c
            JOIN paciente p ON p.id = c.paciente_id
           WHERE p.nombre = 'Rocky Plan'), 1,
          'el paso 2 usó el paciente_id que produjo el paso 1');

SELECT is((SELECT count(*)::int FROM movimiento_inventario
            WHERE lote_id = (SELECT id FROM t_lote) AND tipo = 'salida'), 0,
          'el paso crítico NO se ejecutó con el botón del bloque');

-- Al pintar la tarjeta le llega el turno al paso crítico: recién ahí se
-- prepara —con las cifras de este instante, no las de hace cinco
-- minutos— y pide su propio botón.
CREATE TEMP TABLE tarjeta2 AS
SELECT bot_ia_tarjeta_plan((SELECT id FROM plan_id)) AS r;

SELECT ok((SELECT r->>'botones' FROM tarjeta2) LIKE '%ia:pok:%'
          AND (SELECT estado FROM ia_accion_pendiente
                WHERE id = ia_plan_paso_actual((SELECT id FROM plan_id))) = 'pendiente',
          'el paso crítico se prepara al llegarle el turno y pide su propio botón');

-- Un plan ajeno no se confirma aunque se conozca su identificador.
SELECT is(ia_plan_confirmar_bloque((SELECT id FROM plan_id), prueba.don_nadie())->>'mensaje',
          'Ese plan no es tuyo.',
          'el plan solo lo confirma quien lo pidió');

-- --- Saltar deja el plan cerrado y coherente ---------------------------
SELECT ok((ia_plan_saltar(ia_plan_paso_actual((SELECT id FROM plan_id)),
                          prueba.superadmin())->>'ok')::boolean,
          'un paso crítico se puede saltar sin cancelar el resto del plan');

SELECT is((SELECT estado FROM ia_plan WHERE id = (SELECT id FROM plan_id)),
          'completado',
          'y el plan se cierra solo cuando no le queda ningún paso');

-- --- La auditoría lo cuenta -------------------------------------------
SELECT isnt_empty(
  format($$SELECT 1 FROM evento_auditoria
            WHERE entidad = 'ia_plan' AND accion = 'confirmar_bloque'
              AND entidad_id = %L$$, (SELECT id::text FROM plan_id)),
  'la confirmación del bloque queda auditada');

-- --- Un plan de un solo paso se desarma --------------------------------
-- El caso común —una sola escritura— tiene que seguir recorriendo el
-- camino de siempre: propuesta suelta y tarjeta de confirmación de 078.
CREATE TEMP TABLE solo AS
SELECT ia_llamar_plan(prueba.superadmin(), 700402, prueba.sede(),
         'llamar_siguiente', '{}'::jsonb, NULL) AS r;

CREATE TEMP TABLE solo_cierre AS
SELECT ia_plan_cerrar(((SELECT r FROM solo)->>'plan_id')::uuid) AS r;

SELECT is((SELECT (r->>'pasos')::int FROM solo_cierre), 1,
          'un plan de un paso se cierra como un paso');
SELECT is((SELECT count(*)::int FROM ia_plan
            WHERE id = ((SELECT r FROM solo)->>'plan_id')::uuid), 0,
          'y la cabecera desaparece: vuelve a ser una propuesta suelta');

SELECT * FROM finish();
ROLLBACK;
