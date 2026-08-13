-- =====================================================================
-- Invariantes de los canales de la agenda (Fase B1b).
--
-- El núcleo ya está probado en 090_agenda.sql. Lo que se protege aquí es
-- lo que cada canal promete:
--
--   · **El bot no secuestra el enrutador**: `bot_age_callback` y
--     `bot_age_texto` devuelven NULL cuando lo que llega no es suyo. Si
--     alguna devolviera un objeto, se comería los botones de los otros
--     módulos —el COALESCE de `bot_modulo_callback` para en el primero
--     que responde—.
--   · **El asistente propone, no ejecuta** (C6.9): el borrador deja una
--     fila en `ia_accion_pendiente` y ni una cita. La cita aparece
--     cuando —y solo cuando— alguien confirma.
--   · **El recordatorio se manda una vez y solo a quien lo autorizó**
--     (Ley 1581, §12): `recordatorio_enviado_at` es la reja y el
--     consentimiento es la puerta.
--   · **La inasistencia se marca sola**, sin tocar lo que sí se atendió
--     ni lo que todavía no ha pasado.
-- =====================================================================
BEGIN;
SELECT plan(26);

CREATE TEMP TABLE actor AS SELECT prueba.superadmin() AS id;

-- El dueño autoriza el contacto y tiene chat: es el único caso en el que
-- se le puede escribir.
CREATE TEMP TABLE ctx AS
  SELECT prueba.sede()                        AS sede,
         prueba.dueno(true, 900500::bigint)   AS dueno_ok,
         (hoy_bogota() + 1)                   AS manana;

CREATE TEMP TABLE mascotas AS
  SELECT prueba.paciente((SELECT dueno_ok FROM ctx)) AS con_canal,
         prueba.paciente(prueba.dueno(false))        AS sin_canal;

CREATE OR REPLACE FUNCTION pg_temp.cuando(p_hora text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT to_char((SELECT manana FROM ctx), 'YYYY-MM-DD') || ' ' || p_hora;
$$;

-- =====================================================================
-- 1. El bot
-- =====================================================================
SELECT ok((SELECT jsonb_array_length(bot_age_menu(id)) > 0 FROM actor),
          'quien puede ver la agenda tiene su botón en el menú');
SELECT is(bot_age_menu(prueba.don_nadie()), '[]'::jsonb,
          'quien no puede verla no lo tiene');

CREATE TEMP TABLE cita_a AS
SELECT crear_cita(a.id, jsonb_build_object(
         'paciente_id', m.con_canal, 'sede_id', c.sede,
         'inicio', pg_temp.cuando('09:00')), 'sistema') AS r
  FROM actor a, ctx c, mascotas m;

SELECT matches((SELECT bot_age_dia(a.id, c.sede, c.manana)->>'texto' FROM actor a, ctx c),
               'Mascota de prueba', 'la agenda del día del bot lista la cita');

SELECT matches(
  (SELECT bot_age_texto(a.id, 900501, '/agenda', c.sede)->'acciones'->0->>'texto'
     FROM actor a, ctx c),
  'Agenda', 'el comando /agenda responde con la agenda de hoy');

-- Lo que no es del módulo tiene que devolver NULL, no una respuesta vacía.
SELECT is((SELECT bot_age_callback(a.id, 900501, 1, 'turno:cola', c.sede) FROM actor a, ctx c),
          NULL, 'un callback de otro módulo no lo atiende la agenda');
SELECT is((SELECT bot_age_texto(a.id, 900502, 'hola qué tal', c.sede) FROM actor a, ctx c),
          NULL, 'un texto suelto sin flujo de agenda tampoco');

CREATE TEMP TABLE llegada AS
SELECT bot_age_callback(a.id, 900501, 1,
         'age:llego:' || (ca.r->'cita'->>'cita_id'), c.sede) AS r
  FROM actor a, ctx c, cita_a ca;

SELECT matches((SELECT r->>'alerta' FROM llegada), 'Turno',
               'el botón «Llegó» del bot genera el turno y lo dice');
SELECT is((SELECT estado FROM cita WHERE id = (SELECT (r->'cita'->>'cita_id')::uuid FROM cita_a)),
          'cumplida', 'y la cita queda cumplida');

-- =====================================================================
-- 2. El asistente
-- =====================================================================
SELECT throws_ok(
  format('SELECT ia_agenda_borrador(%L, 900503, %L, ''{}''::jsonb)',
         prueba.don_nadie(), (SELECT sede FROM ctx)),
  '42501', NULL, 'ia_agenda_borrador exige permiso antes de mirar los datos');

SELECT is((SELECT ia_agenda_borrador(a.id, 900503, c.sede,
             jsonb_build_object('inicio', pg_temp.cuando('11:00')))->>'ok'
             FROM actor a, ctx c),
          'false', 'sin paciente_id el borrador no se arma');

SELECT is((SELECT (ia_agenda_borrador(a.id, 900503, c.sede, jsonb_build_object(
             'paciente_id', m.sin_canal, 'inicio', '2020-01-01 09:00'))->>'ok')::boolean
             FROM actor a, ctx c, mascotas m),
          false, 'ni con una fecha que ya pasó');

CREATE TEMP TABLE citas_antes AS SELECT count(*) AS n FROM cita;

CREATE TEMP TABLE propuesta AS
SELECT ia_agenda_borrador(a.id, 900503, c.sede, jsonb_build_object(
         'paciente_id', m.sin_canal,
         'inicio',      pg_temp.cuando('16:00'),
         'notas',       'Control posoperatorio')) AS r
  FROM actor a, ctx c, mascotas m;

SELECT is((SELECT (r->>'requiere_confirmacion')::boolean FROM propuesta), true,
          'el asistente propone la cita y pide confirmación');
SELECT is((SELECT count(*) FROM cita), (SELECT n FROM citas_antes),
          'y NO agendó nada: la propuesta no es una cita (C6.9)');
SELECT matches((SELECT r->>'resumen' FROM propuesta), 'Control posoperatorio',
               'la tarjeta muestra lo que se va a hacer, con datos frescos de la base');

CREATE TEMP TABLE confirmada AS
SELECT ia_confirmar((SELECT (r->>'accion_id')::uuid FROM propuesta),
                    (SELECT id FROM actor)) AS r;

SELECT is((SELECT (r->>'ok')::boolean FROM confirmada), true,
          'al confirmar, la cita sí se agenda');
SELECT is((SELECT count(*) FROM cita), (SELECT n + 1 FROM citas_antes),
          'y aparece exactamente una cita nueva');

SELECT matches(ia_texto_resultado('agendar_cita', (SELECT r FROM confirmada)),
               'Mascota de prueba',
               'el asistente responde diciendo para quién quedó la cita');

SELECT is((SELECT (op_agenda_del_dia(a.id, c.sede,
             jsonb_build_object('fecha', c.manana))->'datos'->>'total')::int
             FROM actor a, ctx c),
          2, 'la lectura del asistente ve las dos citas del día');

-- =====================================================================
-- 3. El job diario
-- =====================================================================
-- La cita del bloque anterior ya se atendió (quedó «cumplida»), así que el
-- recordatorio no la mira: se agenda otra que siga viva mañana. La otra
-- cita de mañana —la que agendó el asistente— es de un dueño sin
-- consentimiento, y ese es justamente el caso que no debe recibir nada.
CREATE TEMP TABLE cita_b AS
SELECT (crear_cita(a.id, jsonb_build_object(
          'paciente_id', m.con_canal, 'sede_id', c.sede,
          'inicio', pg_temp.cuando('10:00')), 'sistema')->'cita'->>'cita_id')::uuid AS id
  FROM actor a, ctx c, mascotas m;

CREATE TEMP TABLE aviso AS SELECT agenda_recordatorios(1) AS r;

SELECT is((SELECT (r->>'encolados')::int FROM aviso), 1,
          'se encola el recordatorio de la cita cuyo dueño autorizó el contacto');
SELECT is((SELECT (r->>'sin_canal')::int FROM aviso), 1,
          'y se cuenta —sin marcarla— la del dueño sin consentimiento (Ley 1581)');

SELECT isnt_empty($q$
  SELECT 1 FROM tarea_async
   WHERE tipo = 'enviar_aviso_dueno' AND clave_unicidad LIKE 'recordatorio_cita_%'
$q$, 'el aviso queda en la cola, no se envía en línea');

SELECT isnt((SELECT recordatorio_enviado_at FROM cita WHERE id = (SELECT id FROM cita_b)),
            NULL, 'la cita avisada queda sellada');

SELECT is((SELECT (agenda_recordatorios(1)->>'encolados')::int), 0,
          'correr el job dos veces no manda el aviso dos veces');

-- --- Inasistencias ----------------------------------------------------
-- La cita se mueve al pasado con un UPDATE directo a propósito: la
-- función de negocio se niega —y hace bien— a agendar hacia atrás, así
-- que es la única forma de construir el caso.
CREATE TEMP TABLE vencida AS
SELECT (crear_cita((SELECT id FROM actor), jsonb_build_object(
          'paciente_id', (SELECT sin_canal FROM mascotas),
          'sede_id',     (SELECT sede FROM ctx),
          'inicio',      pg_temp.cuando('19:00')), 'sistema')->'cita'->>'cita_id')::uuid AS id;

UPDATE cita SET inicio_at = now() - interval '5 hours',
                fin_at    = now() - interval '4 hours'
 WHERE id = (SELECT id FROM vencida);

CREATE TEMP TABLE cierre AS SELECT agenda_marcar_no_asistio() AS r;

SELECT is((SELECT estado FROM cita WHERE id = (SELECT id FROM vencida)), 'no_asistio',
          'la cita que pasó sin generar turno queda como no asistió');
SELECT is((SELECT estado FROM cita WHERE id = (SELECT (r->'cita'->>'cita_id')::uuid FROM cita_a)),
          'cumplida', 'la que sí se atendió no se toca');
SELECT is((SELECT count(*) FROM cita
            WHERE estado = 'no_asistio' AND inicio_at > now()), 0::bigint,
          'y ninguna cita futura se marca');

SELECT * FROM finish();
ROLLBACK;
