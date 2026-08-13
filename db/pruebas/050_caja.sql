-- =====================================================================
-- Invariante: la caja cuadra contra los pagos del día (§7.3).
--
-- El cierre no es un formulario: `cerrar_caja` toma lo que dicen los
-- pagos registrados, lo compara con lo que la persona contó y guarda la
-- diferencia. Lo que se prueba es que ese esperado salga de los pagos
-- reales, por medio de pago, y no de un total escrito a mano.
--
-- Se prueba también la regla que protege el cuadre: no se cierra la caja
-- con cuentas abiertas con saldo, porque entonces el número no
-- significaría nada.
-- =====================================================================
BEGIN;
SELECT plan(12);

-- Dos cuentas: una que se paga en efectivo y otra por transferencia.
CREATE TEMP TABLE caja AS
SELECT (abrir_caja(prueba.superadmin(), prueba.sede())->'caja'->>'caja_id')::uuid AS id;

CREATE OR REPLACE FUNCTION pg_temp.cuenta_con(p_valor numeric) RETURNS uuid
LANGUAGE sql AS $$
  WITH pac AS (SELECT prueba.paciente() AS id),
       tur AS (SELECT crear_turno_manual(prueba.superadmin(), prueba.sede(), 'general', false,
                                         NULL, (SELECT id FROM pac)) AS r),
       cta AS (SELECT abrir_cuenta_para_turno((SELECT (r->'turno'->>'turno_id')::uuid FROM tur),
                                              prueba.superadmin()) AS r),
       lin AS (SELECT agregar_linea_servicio(prueba.superadmin(),
                        (SELECT (r->'cuenta'->>'cuenta_id')::uuid FROM cta),
                        NULL, p_valor, 1, 'Servicio de prueba') AS r)
  SELECT (SELECT (r->'cuenta'->>'cuenta_id')::uuid FROM cta) FROM lin;
$$;

CREATE TEMP TABLE cuentas AS
SELECT pg_temp.cuenta_con(60000) AS efectivo, pg_temp.cuenta_con(40000) AS transferencia;

SELECT ok((SELECT id FROM caja) IS NOT NULL, 'la caja del día se abre');

-- --- Con una cuenta con saldo abierta, no se cierra -------------------
SELECT is((cerrar_caja(prueba.superadmin(), (SELECT id FROM caja), 0)->>'motivo'),
          'cuentas_abiertas', 'no se cierra la caja con cuentas abiertas con saldo');
SELECT is((SELECT estado FROM cierre_caja WHERE id = (SELECT id FROM caja)), 'abierto',
          'la caja sigue abierta tras el rechazo');

-- --- Se cobran las dos cuentas ---------------------------------------
SELECT ok((registrar_pago(prueba.superadmin(), (SELECT efectivo FROM cuentas),
                          'efectivo', 60000)->>'ok')::boolean, 'se cobra en efectivo');
SELECT ok((registrar_pago(prueba.superadmin(), (SELECT transferencia FROM cuentas),
                          'transferencia', 40000)->>'ok')::boolean, 'se cobra por transferencia');
-- El pago no cierra la cuenta: cerrarla es un acto aparte (`cerrar_cuenta`),
-- que es lo que emite el recibo. Se cierran las dos antes de cuadrar.
SELECT ok((cerrar_cuenta(prueba.superadmin(), (SELECT efectivo FROM cuentas))->>'ok')::boolean,
          'la cuenta saldada se puede cerrar');
SELECT ok((cerrar_cuenta(prueba.superadmin(), (SELECT transferencia FROM cuentas))->>'ok')::boolean,
          'la segunda cuenta también');

-- --- El cierre cuadra contra los pagos --------------------------------
CREATE TEMP TABLE cierre AS
SELECT cerrar_caja(prueba.superadmin(), (SELECT id FROM caja), 60000) AS r;

SELECT ok((SELECT (r->>'ok')::boolean FROM cierre), 'la caja cierra cuando no queda saldo abierto');
SELECT is((SELECT total_efectivo_esperado FROM cierre_caja WHERE id = (SELECT id FROM caja)),
          60000::numeric, 'el efectivo esperado sale de los pagos en efectivo');
SELECT is((SELECT total_transferencia FROM cierre_caja WHERE id = (SELECT id FROM caja)),
          40000::numeric, 'la transferencia no se mezcla con el efectivo');
SELECT is((SELECT diferencia FROM cierre_caja WHERE id = (SELECT id FROM caja)), 0::numeric,
          'contando lo mismo que dicen los pagos, la diferencia es cero');
SELECT is((SELECT estado FROM cierre_caja WHERE id = (SELECT id FROM caja)), 'cerrado',
          'la caja queda cerrada');

SELECT * FROM finish();
ROLLBACK;
