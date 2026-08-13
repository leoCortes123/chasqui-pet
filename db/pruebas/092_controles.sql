-- =====================================================================
-- Invariantes del control y sus recordatorios (Fase B2).
--
-- Lo que se protege aquí:
--
--   · **`proxima_revision` deja de ser un dato muerto**: se convierte en
--     una cita por el mismo camino que todas las demás (`crear_cita`), no
--     por un segundo mecanismo de agenda.
--   · **Nunca dos citas para el mismo control**: `agendar_control` es
--     idempotente, porque dos personas pueden estar mirando la misma
--     lista de pendientes.
--   · **Un control agendado sale de la lista y NO recibe el aviso**: de
--     recordarlo se encarga `agenda_recordatorios` (B1b). Dos mensajes
--     por lo mismo es peor que ninguno.
--   · **Un control vencido no desaparece**: sigue en la lista, marcado,
--     porque es el que hay que perseguir.
--   · **Ley 1581 (§12)**: sin consentimiento y chat no se le escribe a
--     nadie, y el control se queda sin marcar para que el aviso siguiente
--     sí pueda salir si el dueño autoriza.
--   · **Idempotencia del job**: `aviso_control_enviado` es la reja.
-- =====================================================================
BEGIN;
SELECT plan(22);

CREATE TEMP TABLE actor AS SELECT prueba.superadmin() AS id;

CREATE TEMP TABLE ctx AS
  SELECT prueba.sede()                       AS sede,
         prueba.dueno(true, 900700::bigint)  AS dueno_ok,
         prueba.dueno(false)                 AS dueno_sin_canal;

CREATE TEMP TABLE mascotas AS
  SELECT prueba.paciente((SELECT dueno_ok FROM ctx))        AS con_canal,
         prueba.paciente((SELECT dueno_sin_canal FROM ctx)) AS sin_canal;

-- Una consulta firmada con revisión anotada es el punto de partida de
-- toda la fase. Se construye por la puerta de negocio —abrir, guardar,
-- firmar— para que la prueba se entere si alguna de ellas cambia.
CREATE OR REPLACE FUNCTION pg_temp.consulta_con_control(p_paciente uuid, p_dias int)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_actor uuid := prueba.superadmin();
BEGIN
  v_id := (abrir_consulta(v_actor, p_paciente, NULL, 'web')->'consulta'->>'consulta_id')::uuid;
  PERFORM guardar_consulta(v_actor, v_id, 'motivo_consulta', 'Control de prueba B2');
  PERFORM guardar_consulta(v_actor, v_id, 'diagnostico_definitivo', 'Sano');
  PERFORM guardar_consulta(v_actor, v_id, 'plan_tratamiento', 'Reposo');
  PERFORM guardar_consulta(v_actor, v_id, 'proxima_revision',
                           (hoy_bogota() + p_dias)::text);
  PERFORM firmar_consulta(v_actor, v_id);
  RETURN v_id;
END;
$$;

CREATE TEMP TABLE consultas AS
  SELECT pg_temp.consulta_con_control((SELECT con_canal FROM mascotas), 3)  AS en_3_dias,
         pg_temp.consulta_con_control((SELECT sin_canal FROM mascotas), 3)  AS sin_canal,
         pg_temp.consulta_con_control((SELECT con_canal FROM mascotas), -5) AS vencida;

-- --- La lista de pendientes -------------------------------------------
SELECT is((SELECT (controles_pendientes(a.id, c.sede, 15)->>'total')::int FROM actor a, ctx c),
          3, 'las tres consultas con revisión anotada aparecen como pendientes');
SELECT is((SELECT (controles_pendientes(a.id, c.sede, 15)->>'vencidos')::int FROM actor a, ctx c),
          1, 'y la que ya se pasó de fecha se cuenta como vencida, no se pierde');

SELECT throws_ok(
  format('SELECT controles_pendientes(%L)', prueba.don_nadie()),
  '42501', NULL, 'controles_pendientes exige permiso');
SELECT throws_ok(
  format('SELECT agendar_control(%L, %L)', prueba.don_nadie(),
         (SELECT en_3_dias FROM consultas)),
  '42501', NULL, 'agendar_control exige permiso antes de mirar los datos');

-- --- El control se vuelve cita ----------------------------------------
CREATE TEMP TABLE agendado AS
SELECT agendar_control(a.id, c.en_3_dias, '{}'::jsonb, 'web') AS r
  FROM actor a, consultas c;

SELECT ok((SELECT (r->>'ok')::boolean FROM agendado), 'el control se agenda');
SELECT is((SELECT r->'cita'->>'tipo' FROM agendado), 'control',
          'como cita de tipo control');
SELECT is((SELECT (r->'cita'->>'fecha')::date FROM agendado), hoy_bogota() + 3,
          'el día que anotó el veterinario, sin que nadie lo reescriba');
SELECT is((SELECT consulta_origen_id FROM cita
            WHERE id = (SELECT (r->'cita'->>'cita_id')::uuid FROM agendado)),
          (SELECT en_3_dias FROM consultas),
          'y la cita sabe de qué consulta salió');

SELECT isnt_empty(format($q$
  SELECT 1 FROM evento_auditoria
   WHERE entidad = 'consulta' AND accion = 'agendar_control' AND entidad_id = %L
$q$, (SELECT en_3_dias FROM consultas)),
  'el vínculo queda auditado');

-- --- Idempotencia -----------------------------------------------------
CREATE TEMP TABLE citas_antes AS SELECT count(*) AS n FROM cita;

SELECT is((SELECT (agendar_control(a.id, c.en_3_dias, '{}'::jsonb, 'web')->>'ya_estaba')::boolean
             FROM actor a, consultas c),
          true, 'agendar dos veces el mismo control no crea una segunda cita');
SELECT is((SELECT count(*) FROM cita), (SELECT n FROM citas_antes),
          'y el número de citas no se mueve');

-- --- Lo agendado sale de la lista -------------------------------------
SELECT is((SELECT (controles_pendientes(a.id, c.sede, 15)->>'total')::int FROM actor a, ctx c),
          2, 'el control ya agendado deja de estar pendiente');

-- Una cita cancelada devuelve el control a la lista: es exactamente el
-- caso en el que hay que volver a llamar al dueño. La cancelación va en su
-- propia sentencia porque `controles_pendientes` es STABLE y no vería, en
-- la misma sentencia, un cambio hecho por ella.
CREATE TEMP TABLE cancelada AS
SELECT cancelar_cita(a.id, (SELECT (r->'cita'->>'cita_id')::uuid FROM agendado),
                     'Prueba', 'web') AS r
  FROM actor a;

SELECT is((SELECT (controles_pendientes(a.id, c.sede, 15)->>'total')::int FROM actor a, ctx c),
          3, 'si la cita se cancela, el control vuelve a estar pendiente');

-- --- Datos que no dan para agendar ------------------------------------
CREATE TEMP TABLE sin_revision AS
SELECT (abrir_consulta((SELECT id FROM actor), (SELECT con_canal FROM mascotas), NULL, 'web')
        ->'consulta'->>'consulta_id')::uuid AS id;

SELECT is((SELECT agendar_control(a.id, s.id, '{}'::jsonb, 'web')->>'motivo'
             FROM actor a, sin_revision s),
          'sin_fecha', 'una consulta sin revisión anotada no genera control');

SELECT is((SELECT agendar_control(a.id, '00000000-0000-0000-0000-000000000001'::uuid,
                                  '{}'::jsonb, 'web')->>'motivo' FROM actor a),
          'sin_consulta', 'una consulta que no existe se dice, no revienta');

-- --- El job de avisos -------------------------------------------------
-- La cita del control en 3 días quedó cancelada arriba, así que las dos
-- consultas de esa fecha están sin agendar: una con canal y otra sin él.
CREATE TEMP TABLE aviso AS SELECT controles_avisar(3) AS r;

SELECT is((SELECT (r->>'encolados')::int FROM aviso), 1,
          'se avisa al dueño que autorizó el contacto');
SELECT is((SELECT (r->>'sin_canal')::int FROM aviso), 1,
          'y el que no autorizó se cuenta, no se le escribe (Ley 1581)');

SELECT isnt_empty($q$
  SELECT 1 FROM tarea_async
   WHERE tipo = 'enviar_aviso_dueno' AND clave_unicidad LIKE 'control_%'
$q$, 'el aviso va por la cola, no en línea');

SELECT is((SELECT (controles_avisar(3)->>'encolados')::int), 0,
          'correr el job dos veces no manda el aviso dos veces');

SELECT is((SELECT count(*) FROM aviso_control_enviado
            WHERE consulta_id = (SELECT sin_canal FROM consultas)),
          0::bigint, 'el control sin canal NO se marca: mañana podrá avisarse');

-- --- El bot ofrece agendar donde se anota la revisión ------------------
SELECT matches(
  (SELECT bot_cli_resumen(c.vencida)::text FROM consultas c),
  'ctl:agendar', 'el resumen de la consulta ofrece agendar el control');

SELECT doesnt_match(
  (SELECT bot_cli_resumen(s.id)::text FROM sin_revision s),
  'ctl:agendar', 'y no lo ofrece cuando no hay revisión anotada');

SELECT * FROM finish();
ROLLBACK;
