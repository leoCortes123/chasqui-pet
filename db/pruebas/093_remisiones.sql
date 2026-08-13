-- =====================================================================
-- Invariantes de las remisiones externas (Fase B3).
--
-- Lo que se protege aquí:
--
--   · **Lo que se mandó afuera no se pierde**: una remisión sin resultado
--     sigue en la lista, y pasada su fecha esperada sale en la alerta.
--     Antes de esta fase eso no se podía ni preguntar.
--   · **El resultado es append-only**: no se edita ni se borra. Un
--     resultado corregido se agrega y quedan los dos, con su autor y su
--     fecha. Es registro clínico, igual que la consulta firmada.
--   · **Al dueño se le avisa una sola vez** y solo si autorizó el
--     contacto (Ley 1581, §12) — la segunda hoja del laboratorio no le
--     manda un segundo mensaje.
--   · **No se anula lo que ya volvió**: si el resultado llegó, la
--     remisión cumplió.
--   · **La alerta solo suena cuando hay vencidas**: una remisión dentro
--     de plazo es el curso normal de las cosas.
-- =====================================================================
BEGIN;
SELECT plan(33);

CREATE TEMP TABLE actor AS SELECT prueba.superadmin() AS id;

CREATE TEMP TABLE ctx AS
  SELECT prueba.sede()                       AS sede,
         prueba.dueno(true, 900900::bigint)  AS dueno_ok,
         prueba.dueno(false)                 AS dueno_sin_canal;

CREATE TEMP TABLE mascotas AS
  SELECT prueba.paciente((SELECT dueno_ok FROM ctx))        AS con_canal,
         prueba.paciente((SELECT dueno_sin_canal FROM ctx)) AS sin_canal;

-- --- Permisos ---------------------------------------------------------
SELECT throws_ok(
  format('SELECT crear_remision(%L, ''{}''::jsonb)', prueba.don_nadie()),
  '42501', NULL, 'crear_remision exige permiso antes de mirar los datos');
SELECT throws_ok(
  format('SELECT registrar_resultado(%L, %L)', prueba.don_nadie(),
         '00000000-0000-0000-0000-000000000001'),
  '42501', NULL, 'registrar_resultado exige permiso');
SELECT throws_ok(
  format('SELECT anular_remision(%L, %L)', prueba.don_nadie(),
         '00000000-0000-0000-0000-000000000001'),
  '42501', NULL, 'anular_remision exige permiso');
SELECT throws_ok(
  format('SELECT remisiones_pendientes(%L)', prueba.don_nadie()),
  '42501', NULL, 'remisiones_pendientes exige permiso');

-- --- Caso exitoso -----------------------------------------------------
CREATE TEMP TABLE rem_a AS
SELECT crear_remision(a.id, jsonb_build_object(
         'paciente_id', m.con_canal,
         'destino',     'Laboratorio del Norte',
         'examenes',    'Hemograma y química sanguínea',
         'tipo',        'laboratorio'), 'web') AS r
  FROM actor a, mascotas m;

SELECT ok((SELECT (r->>'ok')::boolean FROM rem_a), 'se registra la remisión');
SELECT is((SELECT r->'remision'->>'estado' FROM rem_a), 'pendiente',
          'nace pendiente: todavía no ha vuelto');
SELECT is((SELECT (r->'remision'->>'fecha_esperada')::date FROM rem_a),
          hoy_bogota() + 5,
          'con fecha esperada por configuración cuando nadie la dice');
SELECT is((SELECT r->'remision'->>'dueno_id' FROM rem_a),
          (SELECT dueno_ok::text FROM ctx),
          'y el dueño sale de la mascota, no hay que digitarlo');

SELECT isnt_empty(format($q$
  SELECT 1 FROM evento_auditoria
   WHERE entidad = 'remision' AND accion = 'crear' AND entidad_id = %L
$q$, (SELECT r->'remision'->>'remision_id' FROM rem_a)),
  'la remisión queda auditada');

-- --- Datos inválidos --------------------------------------------------
SELECT is((SELECT crear_remision(a.id, jsonb_build_object(
             'paciente_id', m.con_canal, 'examenes', 'Algo'), 'web')->>'motivo'
             FROM actor a, mascotas m),
          'sin_destino', 'sin destino no hay remisión');
SELECT is((SELECT crear_remision(a.id, jsonb_build_object(
             'paciente_id', m.con_canal, 'destino', 'Lab'), 'web')->>'motivo'
             FROM actor a, mascotas m),
          'sin_examenes', 'ni sin decir qué se pidió');
SELECT is((SELECT crear_remision(a.id, jsonb_build_object(
             'destino', 'Lab', 'examenes', 'Algo'), 'web')->>'motivo' FROM actor a),
          'sin_paciente', 'ni sin mascota');
SELECT is((SELECT crear_remision(a.id, jsonb_build_object(
             'paciente_id', '00000000-0000-0000-0000-000000000001',
             'destino', 'Lab', 'examenes', 'Algo'), 'web')->>'motivo' FROM actor a),
          'paciente_inexistente', 'una mascota que no existe se dice, no revienta');
SELECT is((SELECT crear_remision(a.id, jsonb_build_object(
             'paciente_id', m.con_canal, 'destino', 'Lab', 'examenes', 'X',
             'tipo', 'adivinacion'), 'web')->>'motivo'
             FROM actor a, mascotas m),
          'tipo_invalido', 'un tipo inventado se rechaza');

-- --- La lista de pendientes -------------------------------------------
SELECT is((SELECT (remisiones_pendientes(a.id, c.sede)->>'total')::int FROM actor a, ctx c),
          1, 'la remisión aparece como pendiente');

-- --- El resultado -----------------------------------------------------
CREATE TEMP TABLE resultado AS
SELECT registrar_resultado(a.id, (x.r->'remision'->>'remision_id')::uuid,
         jsonb_build_object('texto', 'Todo dentro de parámetros normales'), 'web') AS r
  FROM actor a, rem_a x;

SELECT ok((SELECT (r->>'ok')::boolean FROM resultado), 'se carga el resultado');
SELECT is((SELECT r->'remision'->>'estado' FROM resultado), 'recibida',
          'y la remisión queda recibida');
SELECT is((SELECT (r->>'aviso_dueno')::boolean FROM resultado), true,
          'al dueño que autorizó el contacto se le avisa');
SELECT isnt_empty($q$
  SELECT 1 FROM tarea_async
   WHERE tipo = 'enviar_aviso_dueno' AND clave_unicidad LIKE 'resultado_remision_%'
$q$, 'el aviso va por la cola, no en línea');

SELECT is((SELECT (remisiones_pendientes(a.id, c.sede)->>'total')::int FROM actor a, ctx c),
          0, 'lo que ya volvió deja de estar pendiente');

-- Un segundo resultado —la corrección que manda el laboratorio— se suma,
-- y NO vuelve a avisarle al dueño.
CREATE TEMP TABLE segundo AS
SELECT registrar_resultado(a.id, (x.r->'remision'->>'remision_id')::uuid,
         jsonb_build_object('texto', 'Corrección: leucocitos 12.500'), 'web') AS r
  FROM actor a, rem_a x;

SELECT is((SELECT jsonb_array_length(r->'remision'->'resultados') FROM segundo), 2,
          'un resultado corregido se agrega, no reemplaza al anterior');
SELECT is((SELECT (r->>'aviso_dueno')::boolean FROM segundo), false,
          'y no le manda un segundo mensaje al dueño');

-- Append-only de verdad: ni la aplicación puede editar un resultado.
SELECT is(
  (SELECT count(*)::int FROM information_schema.role_table_grants
    WHERE grantee = 'chasquipet_app' AND table_name = 'resultado_remision'
      AND privilege_type IN ('UPDATE','DELETE')),
  0, 'la aplicación no tiene UPDATE ni DELETE sobre los resultados');

-- --- Anular -----------------------------------------------------------
SELECT is((SELECT anular_remision(a.id, (x.r->'remision'->>'remision_id')::uuid,
                                  'Ya no', 'web')->>'motivo'
             FROM actor a, rem_a x),
          'remision_recibida', 'una remisión con resultado no se anula');

CREATE TEMP TABLE rem_b AS
SELECT (crear_remision(a.id, jsonb_build_object(
          'paciente_id', m.sin_canal, 'destino', 'Lab', 'examenes', 'Coprológico',
          'fecha_esperada', (hoy_bogota() - 3)::text), 'web')->'remision'->>'remision_id')::uuid AS id
  FROM actor a, mascotas m;

-- --- La alerta --------------------------------------------------------
SELECT ok(hay_alertas_remisiones(),
          'una remisión pasada de fecha enciende la alerta');
SELECT is((SELECT jsonb_array_length(alertas_remisiones()->'vencidas')), 1,
          'y aparece en la lista de vencidas');
SELECT matches(bot_texto_alertas_remisiones(), 'Coprológico',
               'el texto de la alerta lo arma la base, con lo que se pidió');

CREATE TEMP TABLE anulada AS
SELECT anular_remision(a.id, b.id, 'El dueño decidió no hacerlo', 'web') AS r
  FROM actor a, rem_b b;

SELECT ok((SELECT (r->>'ok')::boolean FROM anulada), 'una remisión pendiente sí se anula');
SELECT is((SELECT (anular_remision(a.id, b.id, NULL, 'web')->>'ya_estaba')::boolean
             FROM actor a, rem_b b),
          true, 'anular dos veces no es un error: es idempotente');
SELECT ok(NOT hay_alertas_remisiones(),
          'anulada la vencida, la alerta se apaga: no se avisa lo que no hay que perseguir');

-- --- El asistente propone, no ejecuta (C6.9) --------------------------
CREATE TEMP TABLE remisiones_antes AS SELECT count(*) AS n FROM remision;

CREATE TEMP TABLE propuesta AS
SELECT ia_remision_borrador(a.id, 900901, c.sede, jsonb_build_object(
         'paciente_id', m.con_canal,
         'destino',     'Imágenes Veterinarias',
         'examenes',    'Radiografía de tórax',
         'tipo',        'imagenes')) AS r
  FROM actor a, ctx c, mascotas m;

SELECT is((SELECT (r->>'requiere_confirmacion')::boolean FROM propuesta), true,
          'el asistente propone la remisión y pide confirmación');
SELECT is((SELECT count(*) FROM remision), (SELECT n FROM remisiones_antes),
          'y NO la registró: la propuesta no es una remisión (C6.9)');

SELECT is((SELECT (ia_confirmar((SELECT (r->>'accion_id')::uuid FROM propuesta), a.id)
                   ->'remision'->>'destino') FROM actor a),
          'Imágenes Veterinarias',
          'al confirmar sí se registra, con lo que decía la tarjeta');

SELECT * FROM finish();
ROLLBACK;
