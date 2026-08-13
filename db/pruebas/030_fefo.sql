-- =====================================================================
-- Invariante: FEFO con justificación (§6.3, `045_inventario.sql:530-555`).
--
-- Sacar de un lote que no es el que vence primero no está prohibido —a
-- veces el frasco abierto es otro— pero no puede pasar en silencio: sin
-- motivo escrito, la salida se rechaza con `fefo_sin_justificacion` y
-- devuelve cuál era el lote correcto. Con motivo, procede y el motivo
-- queda en el movimiento.
--
-- Se comprueba además que el rechazo NO descuente nada: un error que
-- deja el inventario tocado es peor que el error.
-- =====================================================================
BEGIN;
SELECT plan(9);

CREATE TEMP TABLE inv AS
WITH med AS (SELECT prueba.medicamento('Dipirona de prueba') AS id)
SELECT (SELECT id FROM med) AS medicamento_id,
       prueba.lote((SELECT id FROM med), (hoy_bogota() + 30)::date,  50) AS lote_pronto,
       prueba.lote((SELECT id FROM med), (hoy_bogota() + 365)::date, 80) AS lote_lejano;

SELECT is((SELECT lote_fefo(medicamento_id) FROM inv), (SELECT lote_pronto FROM inv),
          'el lote FEFO es el que vence primero');

-- --- Sin justificación: rechazo tipado -------------------------------
CREATE TEMP TABLE intento AS
SELECT salida_medicamento(prueba.superadmin(), (SELECT lote_lejano FROM inv), 3) AS r;

SELECT is((SELECT (r->>'ok')::boolean FROM intento), false,
          'salida del lote equivocado sin motivo: rechazada');
SELECT is((SELECT r->>'motivo' FROM intento), 'fefo_sin_justificacion',
          'el motivo del rechazo es tipado, legible por máquina');
SELECT is((SELECT (r->>'lote_sugerido')::uuid FROM intento), (SELECT lote_pronto FROM inv),
          'el rechazo dice cuál era el lote correcto');
SELECT is((SELECT cantidad_actual FROM lote WHERE id = (SELECT lote_lejano FROM inv)), 80::numeric,
          'el rechazo no descontó nada del lote equivocado');
SELECT is((SELECT cantidad_actual FROM lote WHERE id = (SELECT lote_pronto FROM inv)), 50::numeric,
          'el rechazo no descontó nada del lote correcto');

-- --- Con justificación: procede y queda escrita -----------------------
CREATE TEMP TABLE justificada AS
SELECT salida_medicamento(prueba.superadmin(), (SELECT lote_lejano FROM inv), 3,
                          'El frasco abierto es de este lote') AS r;

SELECT is((SELECT (r->>'ok')::boolean FROM justificada), true,
          'con motivo escrito, la salida procede');
SELECT is((SELECT cantidad_actual FROM lote WHERE id = (SELECT lote_lejano FROM inv)), 77::numeric,
          'la salida justificada sí descuenta');
SELECT is((SELECT motivo FROM movimiento_inventario
            WHERE lote_id = (SELECT lote_lejano FROM inv) AND tipo = 'salida'
            ORDER BY created_at DESC LIMIT 1),
          'El frasco abierto es de este lote',
          'el motivo queda escrito en el movimiento');

SELECT * FROM finish();
ROLLBACK;
