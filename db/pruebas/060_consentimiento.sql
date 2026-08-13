-- =====================================================================
-- Invariante: no sale un mensaje al dueño sin consentimiento y sin chat
-- vinculado (Ley 1581 de 2012, §12).
--
-- La protección es de tres capas —borrador, ejecución y worker— y aquí
-- se prueban las dos que viven en la base. La tercera es
-- `worker/src/tareas/enviar_aviso_dueno.js` y se verifica aparte: esta
-- batería no ejecuta JavaScript.
--
-- La capa de ejecución importa tanto como la del borrador: entre que se
-- arma la propuesta y alguien toca el botón, el consentimiento pudo
-- retirarse. Se prueba exactamente ese caso.
--
-- Y se prueba el mecanismo de supresión: retirar el consentimiento
-- desvincula el chat, que es lo que la ley exige.
-- =====================================================================
BEGIN;
SELECT plan(11);

CREATE TEMP TABLE gente AS
SELECT prueba.dueno(false)                    AS sin_permiso,
       prueba.dueno(true, 900123456::bigint)  AS con_permiso,
       prueba.dueno(true)                     AS sin_chat,
       prueba.usuario(ARRAY['admin'], 'Administradora de prueba') AS actor,
       prueba.sede() AS sede;

SELECT is((SELECT consentimiento_datos FROM dueno WHERE id = (SELECT con_permiso FROM gente)),
          true, 'fixture: el dueño que consintió quedó marcado');
SELECT is((SELECT telegram_chat_id FROM dueno WHERE id = (SELECT con_permiso FROM gente)),
          900123456::bigint, 'fixture: y con su chat vinculado');

-- --- Capa 1: el borrador no se arma ----------------------------------
SELECT is((ia_aviso_dueno_borrador((SELECT actor FROM gente), 700001, (SELECT sede FROM gente),
            jsonb_build_object('dueno_id', (SELECT sin_permiso FROM gente),
                               'mensaje', 'Su mascota ya puede salir'))->>'ok')::boolean,
          false, 'sin consentimiento no se arma ni el borrador');
SELECT is((ia_aviso_dueno_borrador((SELECT actor FROM gente), 700002, (SELECT sede FROM gente),
            jsonb_build_object('dueno_id', (SELECT sin_chat FROM gente),
                               'mensaje', 'Su mascota ya puede salir'))->>'ok')::boolean,
          false, 'con consentimiento pero sin chat vinculado, tampoco');
SELECT is((SELECT count(*)::int FROM ia_accion_pendiente WHERE chat_id IN (700001, 700002)), 0,
          'los rechazos no dejan propuesta pendiente');

-- --- El camino legítimo sí funciona ----------------------------------
CREATE TEMP TABLE ok_borrador AS
SELECT ia_aviso_dueno_borrador((SELECT actor FROM gente), 700003, (SELECT sede FROM gente),
         jsonb_build_object('dueno_id', (SELECT con_permiso FROM gente),
                            'mensaje', 'Su mascota ya puede salir')) AS r;
SELECT ok((SELECT (r->>'ok')::boolean FROM ok_borrador), 'con consentimiento y chat, se propone');
SELECT ok((SELECT (r->>'requiere_confirmacion')::boolean FROM ok_borrador),
          'y queda esperando confirmación humana, no se envía');
SELECT is((SELECT count(*)::int FROM tarea_async WHERE tipo = 'enviar_aviso_dueno'), 0,
          'proponer no encola ningún envío');

-- --- Capa 2: el consentimiento se revalida al confirmar --------------
-- Se retira el consentimiento DESPUÉS de armar la propuesta.
SELECT ok((registrar_consentimiento(prueba.superadmin(), (SELECT con_permiso FROM gente),
                                    false)->>'ok')::boolean,
          'el dueño retira su consentimiento');
SELECT is((SELECT telegram_chat_id FROM dueno WHERE id = (SELECT con_permiso FROM gente)), NULL,
          'retirar el consentimiento desvincula el chat (supresión, Ley 1581)');

SELECT is((SELECT (ia_confirmar((SELECT id FROM ia_accion_pendiente WHERE chat_id = 700003),
                                (SELECT actor FROM gente))->>'ok')::boolean),
          false, 'al confirmar se revalida: la propuesta ya no se ejecuta');

SELECT * FROM finish();
ROLLBACK;
