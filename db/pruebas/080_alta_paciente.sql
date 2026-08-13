-- =====================================================================
-- Invariantes del alta de paciente (Fase A6): una sola transacción de
-- negocio, `alta_paciente`, para los dos canales.
--
-- Lo que se protege aquí no es «crear una fila»: es la regla que estaba
-- escrita dos veces —dueño nuevo o dueño ya registrado, no duplicar al
-- dueño, avisar del posible duplicado antes de crear (§8.1)— y la
-- promesa de que el bot y el asistente pasan por ella y no por una copia
-- propia.
--
-- El permiso lo cubre 010_permisos.sql, que recorre todas las funciones
-- de escritura con el mismo contrato.
-- =====================================================================
BEGIN;
SELECT plan(17);

CREATE TEMP TABLE actor AS SELECT prueba.superadmin() AS id;

-- --- Caso exitoso: dueño nuevo + mascota ------------------------------
CREATE TEMP TABLE alta1 AS
SELECT alta_paciente(a.id, jsonb_build_object(
         'mascota_nombre', 'Nube', 'especie', 'gato', 'sexo', 'hembra',
         'dueno_nombre', 'Marta Quiroga A6', 'dueno_telefono', '3105550101'), 'sistema') AS r
  FROM actor a;

SELECT ok((SELECT (r->>'ok')::boolean FROM alta1), 'el alta con dueño nuevo sale bien');
SELECT is((SELECT r->'paciente'->>'nombre' FROM alta1), 'Nube',
          'devuelve el paciente creado');
SELECT isnt((SELECT r->'dueno'->>'dueno_id' FROM alta1), NULL,
            'y el dueño queda enlazado a la mascota');
SELECT is((SELECT (r->>'dueno_reutilizado')::boolean FROM alta1), false,
          'el dueño se creó en este acto, no se reutilizó');

-- --- Segunda mascota del mismo teléfono: NO se duplica el dueño -------
-- Es la regla que el flujo de botones no tenía y el asistente sí. Ahora
-- la tienen los dos porque es una sola.
CREATE TEMP TABLE duenos_antes AS SELECT count(*) AS n FROM dueno;

CREATE TEMP TABLE alta2 AS
SELECT alta_paciente(a.id, jsonb_build_object(
         'mascota_nombre', 'Copo', 'especie', 'perro',
         'dueno_nombre', 'Marta Quiroga (mal escrito)', 'dueno_telefono', '310 555 0101'), 'sistema') AS r
  FROM actor a;

SELECT is((SELECT (r->>'dueno_reutilizado')::boolean FROM alta2), true,
          'un teléfono ya registrado reutiliza al dueño');
SELECT is((SELECT count(*) FROM dueno), (SELECT n FROM duenos_antes),
          'y no se creó ningún dueño nuevo');
SELECT is((SELECT r->'dueno'->>'dueno_id' FROM alta2),
          (SELECT r->'dueno'->>'dueno_id' FROM alta1),
          'las dos mascotas quedaron del mismo dueño');

-- --- Duplicados: se avisan, no se bloquean ----------------------------
CREATE TEMP TABLE alta3 AS
SELECT alta_paciente(a.id, jsonb_build_object(
         'mascota_nombre', 'Nube', 'especie', 'gato',
         'dueno_nombre', 'Marta Quiroga A6', 'dueno_telefono', '3105550101'), 'sistema') AS r
  FROM actor a;

SELECT ok((SELECT (r->>'ok')::boolean FROM alta3),
          'repetir mascota y dueño no bloquea el alta');
SELECT cmp_ok((SELECT jsonb_array_length(r->'duplicados') FROM alta3), '>', 0,
              'pero devuelve el posible duplicado para que el canal lo diga');

-- --- Mascota sin dueño ------------------------------------------------
SELECT is((SELECT p.dueno_id
             FROM paciente p
            WHERE p.id = (alta_paciente((SELECT id FROM actor), jsonb_build_object(
                            'mascota_nombre', 'Callejero A6', 'especie', 'perro',
                            'sin_dueno', true), 'sistema')->'paciente'->>'paciente_id')::uuid),
          NULL, 'una mascota sin dueño se crea sin dueño, no con uno inventado');

-- --- Datos inválidos --------------------------------------------------
CREATE TEMP TABLE pacientes_antes AS SELECT count(*) AS n FROM paciente;

SELECT is((SELECT alta_paciente(id, '{"dueno_nombre":"Quien Sea"}'::jsonb, 'sistema')->>'motivo'
             FROM actor),
          'sin_nombre', 'sin nombre de mascota no hay alta');
SELECT is((SELECT count(*) FROM paciente), (SELECT n FROM pacientes_antes),
          'y no quedó nada creado a medias');

SELECT is((SELECT alta_paciente(id, jsonb_build_object(
             'mascota_nombre', 'Fantasma',
             'dueno_id', '00000000-0000-0000-0000-000000000001')::jsonb, 'sistema')->>'motivo'
             FROM actor),
          'dueno_inexistente', 'un dueño que ya no existe corta el alta');

SELECT is((SELECT alta_paciente(id, '{"mascota_nombre":"Anonimo A6"}'::jsonb, 'sistema')->>'motivo'
             FROM actor),
          'sin_dueno', 'sin datos de dueño y sin sin_dueno tampoco hay alta');

-- --- Auditoría del acto completo --------------------------------------
SELECT isnt_empty(format($q$
  SELECT 1 FROM evento_auditoria
   WHERE entidad = 'paciente' AND accion = 'alta'
     AND entidad_id = %L
     AND datos_despues ? 'dueno_reutilizado'
$q$, (SELECT r->'paciente'->>'paciente_id' FROM alta1)),
  'el alta completa queda auditada, con dueño y duplicados advertidos');

-- --- Los dos canales delegan en la misma función ----------------------
-- Si alguno volviera a tener su propia copia, esto seguiría pasando; lo
-- que se comprueba es el contrato de salida que cada canal consume, que
-- es lo que se rompería al delegar mal.
SELECT is(
  ia_alta_paciente_ejecutar((SELECT id FROM actor), jsonb_build_object(
    'mascota_nombre', 'Tuna A6', 'especie', 'gato',
    'dueno_nombre', 'Dueño IA A6', 'dueno_telefono', '3105550202'))->'paciente'->>'nombre',
  'Tuna A6', 'el asistente sigue devolviendo el paciente que espera ia_texto_resultado');

SELECT matches(
  bot_cli_crear_paciente((SELECT id FROM actor), 700200, jsonb_build_object(
    'mascota_nombre', 'Rocco A6', 'especie', 'perro', 'sexo', 'macho',
    'dueno_nombre', 'Dueño Bot A6', 'dueno_telefono', '3105550303'), 700201)->>'texto',
  'Rocco A6', 'el flujo de botones sigue terminando en la ficha de la mascota');

SELECT * FROM finish();
ROLLBACK;
