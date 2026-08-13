-- =====================================================================
-- Invariante: el dinero y el rastro no se editan (§2.2.8).
--
-- Hay dos cerraduras distintas y se prueban por separado, porque
-- protegen de cosas distintas:
--
--   · Triggers (`dinero_inmutable`, `movimiento_inmutable`,
--     `cuenta_linea_no_editar`): impiden el UPDATE/DELETE **a cualquiera**,
--     incluido el dueño de la base. Una corrección se hace con un
--     movimiento inverso, nunca editando la fila original.
--   · Privilegios (090_grants.sql): `evento_auditoria` no tiene trigger;
--     lo que impide que la aplicación la toque es que `chasquipet_app`
--     no tiene UPDATE ni DELETE sobre ella. Por eso esa parte se prueba
--     con SET ROLE: como dueño sí se puede, y ese es el diseño.
-- =====================================================================
BEGIN;
SELECT plan(14);

-- --- Fixture: una venta completa de verdad ---------------------------
CREATE TEMP TABLE datos AS
WITH med AS (SELECT prueba.medicamento('Amoxicilina de prueba') AS id),
     lot AS (SELECT prueba.lote((SELECT id FROM med), (hoy_bogota() + 90), 100) AS id),
     pac AS (SELECT prueba.paciente() AS id),
     sal AS (SELECT salida_medicamento(prueba.superadmin(), (SELECT id FROM lot), 5,
                                       'Prueba de append-only') AS r),
     tur AS (SELECT crear_turno_manual(prueba.superadmin(), prueba.sede(), 'general', false,
                                       NULL, (SELECT id FROM pac)) AS r),
     cta AS (SELECT abrir_cuenta_para_turno((SELECT (r->'turno'->>'turno_id')::uuid FROM tur),
                                            prueba.superadmin()) AS r)
SELECT (SELECT id FROM med) AS medicamento_id,
       (SELECT id FROM lot) AS lote_id,
       (SELECT (r->'movimiento'->>'movimiento_id')::bigint FROM sal) AS movimiento_id,
       (SELECT (r->'cuenta'->>'cuenta_id')::uuid FROM cta) AS cuenta_id;

-- Una línea, un descuento y un pago sobre esa cuenta.
CREATE TEMP TABLE dinero AS
WITH lin AS (SELECT agregar_linea_servicio(prueba.superadmin(), (SELECT cuenta_id FROM datos),
                                           NULL, 50000, 1, 'Consulta de prueba') AS r),
     des AS (SELECT aplicar_descuento(prueba.superadmin(), (SELECT cuenta_id FROM datos),
                                      5000, 'Prueba') AS r),
     pag AS (SELECT registrar_pago(prueba.superadmin(), (SELECT cuenta_id FROM datos),
                                   'efectivo', 10000) AS r)
SELECT (SELECT r FROM lin) AS linea, (SELECT r FROM des) AS descuento, (SELECT r FROM pag) AS pago;

SELECT ok((SELECT (pago->>'ok')::boolean FROM dinero), 'fixture: el pago se registró');
SELECT ok((SELECT (descuento->>'ok')::boolean FROM dinero), 'fixture: el descuento se aplicó');
SELECT isnt_empty('SELECT 1 FROM pago', 'fixture: hay al menos un pago');

-- --- Triggers: nadie edita, ni el dueño ------------------------------
SELECT throws_ok('UPDATE pago SET valor = 1',                '0A000', NULL, 'pago no se puede editar');
SELECT throws_ok('DELETE FROM pago',                         '0A000', NULL, 'pago no se puede borrar');
SELECT throws_ok('UPDATE descuento SET valor = 1',           '0A000', NULL, 'descuento no se puede editar');
SELECT throws_ok('DELETE FROM descuento',                    '0A000', NULL, 'descuento no se puede borrar');
SELECT throws_ok('UPDATE movimiento_inventario SET cantidad = 1', '0A000', NULL,
                 'movimiento_inventario no se puede editar');
SELECT throws_ok('DELETE FROM movimiento_inventario',        '0A000', NULL,
                 'movimiento_inventario no se puede borrar');
SELECT throws_ok('UPDATE cuenta_linea SET valor_unitario = 1', '0A000', NULL,
                 'cuenta_linea no se puede editar');

-- --- Privilegios: la aplicación no toca la auditoría -----------------
SELECT isnt_empty('SELECT 1 FROM evento_auditoria', 'fixture: la operación dejó auditoría');

SET LOCAL ROLE chasquipet_app;
SELECT throws_ok('UPDATE evento_auditoria SET accion = ''x''', '42501', NULL,
                 'la aplicación no puede editar la auditoría');
SELECT throws_ok('DELETE FROM evento_auditoria', '42501', NULL,
                 'la aplicación no puede borrar la auditoría');
SELECT throws_ok('DELETE FROM telegram_update', '42501', NULL,
                 'la aplicación no puede borrar updates (solo mantenimiento_diario)');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
