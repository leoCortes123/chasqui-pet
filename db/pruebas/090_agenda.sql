-- =====================================================================
-- Invariantes de la agenda de citas (Fase B1).
--
-- Lo que se protege aquí:
--
--   · **Nadie se sienta dos veces en la misma silla.** El solapamiento lo
--     impide una restricción EXCLUDE, no una consulta previa, y la
--     función lo traduce a {ok:false, motivo:'ocupado'} en vez de reventar.
--   · **Lo que se ofrece es lo que se puede reservar**: si un cupo está
--     tomado o bloqueado, `horarios_disponibles` no lo muestra. Las dos
--     definiciones de «choque» —la del EXCLUDE y la de la consulta de
--     cupos— tienen que ser la misma.
--   · **La cita se junta con la cola**: `confirmar_asistencia` genera el
--     turno del día, y la consulta que nace de ese turno hereda
--     `cita_id`. Es el círculo agenda → cola → historia clínica, que
--     antes de B1 no existía (`consulta.cita_id` era una columna muerta).
--   · **Idempotencia donde el mostrador presiona dos veces**: confirmar
--     una llegada ya registrada y cancelar lo ya cancelado.
--   · Auditoría de crear y cancelar.
--
-- El permiso lo cubre 010_permisos.sql, que recorre todas las funciones
-- de escritura con el mismo contrato.
-- =====================================================================
BEGIN;
SELECT plan(34);

CREATE TEMP TABLE actor AS SELECT prueba.superadmin() AS id;

CREATE TEMP TABLE ctx AS
  SELECT prueba.sede()                                        AS sede,
         prueba.usuario(ARRAY['veterinario'], 'Vet Agenda B1') AS vet,
         prueba.paciente()                                    AS paciente,
         (hoy_bogota() + 1)                                   AS manana,
         '00000000-0000-0000-0000-000000000001'::uuid         AS fantasma;

-- Atajo para no repetir la construcción del texto de fecha y hora. La
-- función de negocio interpreta «sin zona» como hora de Bogotá, que es
-- como la escribe una persona en el mostrador.
CREATE OR REPLACE FUNCTION pg_temp.cuando(p_hora text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT to_char((SELECT manana FROM ctx), 'YYYY-MM-DD') || ' ' || p_hora;
$$;

-- --- Caso exitoso -----------------------------------------------------
CREATE TEMP TABLE cita_a AS
SELECT crear_cita(a.id, jsonb_build_object(
         'paciente_id',    c.paciente,
         'veterinario_id', c.vet,
         'sede_id',        c.sede,
         'tipo',           'general',
         'inicio',         pg_temp.cuando('09:00'),
         'notas',          'Cita de prueba B1'), 'sistema') AS r
  FROM actor a, ctx c;

SELECT ok((SELECT (r->>'ok')::boolean FROM cita_a), 'se agenda una cita');
SELECT is((SELECT r->'cita'->>'estado' FROM cita_a), 'programada',
          'la cita nace programada');
SELECT is((SELECT (r->'cita'->>'duracion_min')::int FROM cita_a), 15,
          'la duración sale del tipo de servicio, no del que agenda');

-- --- Doble reserva: imposible ----------------------------------------
CREATE TEMP TABLE choque AS
SELECT crear_cita(a.id, jsonb_build_object(
         'paciente_id',    c.paciente,
         'veterinario_id', c.vet,
         'sede_id',        c.sede,
         'inicio',         pg_temp.cuando('09:05')), 'sistema') AS r
  FROM actor a, ctx c;

SELECT is((SELECT r->>'motivo' FROM choque), 'ocupado',
          'un horario que se solapa con otra cita del mismo veterinario se rechaza');
SELECT is((SELECT count(*) FROM cita WHERE veterinario_id = (SELECT vet FROM ctx)),
          1::bigint, 'y no quedó una segunda cita creada a medias');

-- --- Datos inválidos --------------------------------------------------
SELECT is((SELECT crear_cita(a.id, jsonb_build_object(
             'paciente_id', c.paciente, 'sede_id', c.sede,
             'inicio', '2020-01-01 09:00'), 'sistema')->>'motivo'
             FROM actor a, ctx c),
          'inicio_pasado', 'no se agenda en el pasado');

SELECT is((SELECT crear_cita(a.id, jsonb_build_object(
             'paciente_id', c.fantasma, 'sede_id', c.sede,
             'inicio', pg_temp.cuando('15:00')), 'sistema')->>'motivo'
             FROM actor a, ctx c),
          'paciente_inexistente', 'una mascota que no existe no tiene cita');

SELECT is((SELECT crear_cita(a.id, jsonb_build_object(
             'paciente_id', c.paciente, 'sede_id', c.sede), 'sistema')->>'motivo'
             FROM actor a, ctx c),
          'sin_inicio', 'sin fecha y hora no hay cita');

SELECT is((SELECT crear_cita(a.id, jsonb_build_object(
             'paciente_id', c.paciente, 'sede_id', c.sede, 'tipo', 'peluqueria_canina',
             'inicio', pg_temp.cuando('15:00')), 'sistema')->>'motivo'
             FROM actor a, ctx c),
          'tipo_desconocido', 'un tipo de servicio inventado se rechaza');

SELECT is((SELECT crear_cita(a.id, jsonb_build_object(
             'paciente_id', c.paciente, 'sede_id', c.sede,
             'inicio', to_char(hoy_bogota() + 400, 'YYYY-MM-DD') || ' 09:00'), 'sistema')->>'motivo'
             FROM actor a, ctx c),
          'fuera_de_horizonte', 'agendar a un año se rechaza por el horizonte configurado');

-- --- Auditoría de la creación ----------------------------------------
SELECT isnt_empty(format($q$
  SELECT 1 FROM evento_auditoria
   WHERE entidad = 'cita' AND accion = 'crear' AND entidad_id = %L
$q$, (SELECT r->'cita'->>'cita_id' FROM cita_a)),
  'la cita creada queda auditada');

-- --- Horarios disponibles --------------------------------------------
-- Sin franja declarada no hay nada que ofrecer, y eso es una respuesta
-- válida, no un error.
SELECT is((SELECT (horarios_disponibles(a.id, c.sede, c.manana, 'general', c.vet)->>'total')::int
             FROM actor a, ctx c),
          0, 'sin disponibilidad declarada no se ofrece ningún cupo');

SELECT ok((SELECT (definir_disponibilidad(a.id, jsonb_build_object(
             'veterinario_id', c.vet,
             'sede_id',        c.sede,
             'dia_semana',     EXTRACT(dow FROM c.manana)::int,
             'hora_inicio',    '08:00',
             'hora_fin',       '12:00'), 'sistema')->>'ok')::boolean
             FROM actor a, ctx c),
          'se declara la franja de atención del veterinario');

-- 08:00 a 11:45 de a 15 minutos son 16 cupos; el de las 09:00 lo tiene la
-- cita ya agendada, así que quedan 15.
SELECT is((SELECT (horarios_disponibles(a.id, c.sede, c.manana, 'general', c.vet)->>'total')::int
             FROM actor a, ctx c),
          15, 'la franja se parte en cupos y se descuenta el que ya está tomado');

SELECT ok((SELECT NOT EXISTS (
             SELECT 1
               FROM actor a, ctx c,
                    jsonb_array_elements(
                      horarios_disponibles(a.id, c.sede, c.manana, 'general', c.vet)->'slots') s
              WHERE s->>'hora' = '09:00')),
          'el cupo ocupado no se ofrece: lo que se muestra es lo que se puede reservar');

-- --- Bloqueos ---------------------------------------------------------
CREATE TEMP TABLE bloqueo AS
SELECT bloquear_agenda(a.id, jsonb_build_object(
         'sede_id',        c.sede,
         'veterinario_id', c.vet,
         'inicio',         pg_temp.cuando('08:00'),
         'fin',            pg_temp.cuando('12:00'),
         'motivo',         'Cirugía programada'), 'sistema') AS r
  FROM actor a, ctx c;

SELECT is((SELECT (r->>'citas_afectadas')::int FROM bloqueo), 1,
          'bloquear informa las citas ya agendadas que quedan dentro, sin cancelarlas');

SELECT is((SELECT crear_cita(a.id, jsonb_build_object(
             'paciente_id', c.paciente, 'veterinario_id', c.vet, 'sede_id', c.sede,
             'inicio', pg_temp.cuando('10:30')), 'sistema')->>'motivo'
             FROM actor a, ctx c),
          'agenda_bloqueada', 'dentro de un bloqueo no se agenda');

SELECT ok((SELECT (liberar_bloqueo(a.id, (r->>'bloqueo_id')::uuid, 'sistema')->>'ok')::boolean
             FROM actor a, bloqueo),
          'el bloqueo se libera');

-- --- Reprogramar ------------------------------------------------------
CREATE TEMP TABLE cita_b AS
SELECT crear_cita(a.id, jsonb_build_object(
         'paciente_id', c.paciente, 'veterinario_id', c.vet, 'sede_id', c.sede,
         'inicio', pg_temp.cuando('10:30')), 'sistema') AS r
  FROM actor a, ctx c;

SELECT ok((SELECT (r->>'ok')::boolean FROM cita_b),
          'liberado el bloqueo, la misma franja vuelve a estar disponible');

CREATE TEMP TABLE reprog AS
SELECT reprogramar_cita(a.id, (b.r->'cita'->>'cita_id')::uuid,
                        pg_temp.cuando('11:30'), NULL, 'El dueño pidió más tarde', 'sistema') AS r
  FROM actor a, cita_b b;

SELECT is((SELECT r->'cita'->>'hora' FROM reprog), '11:30',
          'reprogramar mueve la misma cita a la hora nueva');
SELECT is((SELECT recordatorio_enviado_at FROM cita
            WHERE id = (SELECT (r->'cita'->>'cita_id')::uuid FROM cita_b)),
          NULL, 'y reinicia el recordatorio: cambió la hora, hay que volver a avisar');

SELECT is((SELECT reprogramar_cita(a.id, (b.r->'cita'->>'cita_id')::uuid,
                                   pg_temp.cuando('09:00'), NULL, NULL, 'sistema')->>'motivo'
             FROM actor a, cita_b b),
          'ocupado', 'reprogramar encima de otra cita del mismo veterinario se rechaza');

-- --- Cancelar ---------------------------------------------------------
SELECT ok((SELECT (cancelar_cita(a.id, (b.r->'cita'->>'cita_id')::uuid,
                                 'El dueño no puede venir', 'sistema')->>'ok')::boolean
             FROM actor a, cita_b b),
          'la cita se cancela');

SELECT is((SELECT motivo_cancelacion FROM cita
            WHERE id = (SELECT (r->'cita'->>'cita_id')::uuid FROM cita_b)),
          'El dueño no puede venir', 'con el motivo guardado, no borrada');

SELECT is((SELECT (cancelar_cita(a.id, (b.r->'cita'->>'cita_id')::uuid, NULL, 'sistema')
                   ->>'ya_estaba')::boolean
             FROM actor a, cita_b b),
          true, 'cancelar dos veces no es un error: es idempotente');

SELECT is((SELECT reprogramar_cita(a.id, (b.r->'cita'->>'cita_id')::uuid,
                                   pg_temp.cuando('16:00'), NULL, NULL, 'sistema')->>'motivo'
             FROM actor a, cita_b b),
          'estado_no_reprogramable', 'una cita cancelada no se reprograma');

SELECT isnt_empty(format($q$
  SELECT 1 FROM evento_auditoria
   WHERE entidad = 'cita' AND accion = 'cancelar' AND entidad_id = %L
$q$, (SELECT r->'cita'->>'cita_id' FROM cita_b)),
  'la cancelación queda auditada');

-- --- La llegada: la cita se junta con la cola -------------------------
CREATE TEMP TABLE llegada AS
SELECT confirmar_asistencia(a.id, (ca.r->'cita'->>'cita_id')::uuid, 'sistema') AS r
  FROM actor a, cita_a ca;

SELECT isnt((SELECT r->'turno'->>'turno_id' FROM llegada), NULL,
            'confirmar la llegada genera el turno del día');
SELECT is((SELECT estado FROM cita WHERE id = (SELECT (r->'cita'->>'cita_id')::uuid FROM cita_a)),
          'cumplida', 'y la cita queda cumplida');

SELECT is((SELECT confirmar_asistencia(a.id, (ca.r->'cita'->>'cita_id')::uuid, 'sistema')
                  ->'turno'->>'turno_id'
             FROM actor a, cita_a ca),
          (SELECT r->'turno'->>'turno_id' FROM llegada),
          'confirmar dos veces devuelve el mismo turno, no crea otro');

-- --- consulta.cita_id deja de ser una columna muerta ------------------
-- La consulta se abre en su propia sentencia: una función volátil dentro
-- del WHERE no vería la fila que ella misma acaba de insertar (el
-- snapshot de la sentencia es anterior).
CREATE TEMP TABLE consulta_de_cita AS
SELECT (abrir_consulta((SELECT id FROM actor),
                       (SELECT paciente FROM ctx),
                       (SELECT (r->'turno'->>'turno_id')::uuid FROM llegada),
                       'web')->'consulta'->>'consulta_id')::uuid AS id;

SELECT is((SELECT c.cita_id FROM consulta c WHERE c.id = (SELECT id FROM consulta_de_cita)),
          (SELECT (r->'cita'->>'cita_id')::uuid FROM cita_a),
          'la consulta que nace del turno de una cita hereda cita_id');

-- --- Agenda del día ---------------------------------------------------
CREATE TEMP TABLE agenda AS
SELECT agenda_del_dia(a.id, c.sede, c.manana) AS r FROM actor a, ctx c;

SELECT is((SELECT (r->>'total')::int FROM agenda), 2,
          'la agenda del día lista todas las citas, también las canceladas');
SELECT is((SELECT r->'por_estado'->>'cumplida' FROM agenda), '1',
          'y las resume por estado');

-- --- Ausencia de datos ------------------------------------------------
SELECT is((SELECT cancelar_cita(a.id, c.fantasma, NULL, 'sistema')->>'motivo'
             FROM actor a, ctx c),
          'sin_cita', 'una cita que no existe se dice, no revienta');

SELECT * FROM finish();
ROLLBACK;
