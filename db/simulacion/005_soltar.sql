-- =====================================================================
-- Chasqui Pet — db/simulacion/005_soltar.sql
-- Suelta lo que el bloque B cuelga de la historia clínica, para que
-- db/demo/*.sql pueda rehacer la jornada. Lo corre `simular.sh dia`
-- ANTES de los archivos de db/demo/.
--
-- El problema que resuelve: db/demo/010_turnos_demo.sql borra las
-- consultas de los pacientes de simulación para volver a generarlas,
-- pero una remisión apunta a la consulta que la originó
-- (`remision.consulta_id`) y una cita de control apunta a la suya
-- (`cita.consulta_origen_id`). Con esas filas en pie, el borrado choca
-- contra la clave foránea y la carga se cae a la mitad. Hay que soltar
-- primero lo de arriba.
--
-- Es lo mismo que hace la limpieza al principio de 100, 110 y 120, sólo
-- que adelantado: aquellos archivos corren DESPUÉS de db/demo y para
-- entonces ya es tarde.
--
-- Sólo toca datos de simulación: pacientes marcados `notas = 'DEMO'` y
-- personal del rango ficticio 900000000–900999999.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

DO $sim$
DECLARE
  c_tg_base constant bigint := 900000000;
  c_tg_tope constant bigint := 900999999;

  v_pacientes uuid[];
  v_personal  uuid[];
BEGIN
  SELECT array_agg(id) INTO v_pacientes FROM paciente WHERE notas = 'DEMO';
  SELECT array_agg(id) INTO v_personal  FROM usuario
   WHERE telegram_user_id BETWEEN c_tg_base AND c_tg_tope;

  v_pacientes := COALESCE(v_pacientes, ARRAY[]::uuid[]);
  v_personal  := COALESCE(v_personal,  ARRAY[]::uuid[]);

  DELETE FROM resultado_remision r
   USING remision m
   WHERE r.remision_id = m.id
     AND (m.paciente_id = ANY (v_pacientes) OR m.solicitada_por = ANY (v_personal));

  DELETE FROM remision
   WHERE paciente_id = ANY (v_pacientes) OR solicitada_por = ANY (v_personal);

  DELETE FROM cita
   WHERE paciente_id = ANY (v_pacientes)
      OR veterinario_id = ANY (v_personal)
      OR creado_por = ANY (v_personal);

  DELETE FROM aviso_control_enviado a
   USING consulta c
   WHERE a.consulta_id = c.id
     AND (c.paciente_id = ANY (v_pacientes) OR c.veterinario_id = ANY (v_personal));

  DELETE FROM disponibilidad WHERE veterinario_id = ANY (v_personal);
  DELETE FROM bloqueo_agenda WHERE veterinario_id = ANY (v_personal);

  -- ===================================================================
  -- Cuentas de jornadas simuladas ANTERIORES.
  --
  -- db/demo/010_turnos_demo.sql borra los movimientos de inventario del
  -- personal de simulación sin límite de fecha, pero sólo borra las
  -- cuentas de HOY (o de pacientes DEMO). Una cuenta de una simulación
  -- de días pasados que cuelga del turno —no del paciente, así que
  -- `paciente_id` va en NULL— se queda en pie con sus líneas apuntando
  -- a esos movimientos, y el borrado choca contra
  -- `cuenta_linea_movimiento_id_fkey`: correr `simular.sh dia` un
  -- segundo día se caía en 010. Aquí se sueltan por adelantado.
  --
  -- El criterio es el rastro de simulación, no la fecha: cuenta abierta
  -- por personal ficticio, colgada de un turno de ese personal, de un
  -- paciente DEMO, o con una línea que despachó un movimiento suyo.
  -- pago, descuento y cuenta_linea son de sólo agregar (§7): los
  -- triggers se desactivan dentro de esta transacción, igual que en 010.
  -- ===================================================================
  ALTER TABLE pago         DISABLE TRIGGER pago_inmutable;
  ALTER TABLE descuento    DISABLE TRIGGER descuento_inmutable;
  ALTER TABLE cuenta_linea DISABLE TRIGGER cuenta_linea_no_editar;

  CREATE TEMP TABLE _cuentas_sim ON COMMIT DROP AS
    SELECT DISTINCT c.id
      FROM cuenta c
     WHERE c.paciente_id = ANY (v_pacientes)
        OR c.abierta_por = ANY (v_personal)
        OR c.turno_id IN (SELECT t.id FROM turno t
                           WHERE t.paciente_id = ANY (v_pacientes)
                              OR t.creado_por     = ANY (v_personal)
                              OR t.veterinario_id = ANY (v_personal))
        OR EXISTS (SELECT 1 FROM cuenta_linea cl
                     JOIN movimiento_inventario mi ON mi.id = cl.movimiento_id
                    WHERE cl.cuenta_id = c.id
                      AND mi.usuario_id = ANY (v_personal));

  UPDATE turno SET cuenta_id = NULL
   WHERE cuenta_id IN (SELECT id FROM _cuentas_sim);

  DELETE FROM pago         WHERE cuenta_id IN (SELECT id FROM _cuentas_sim);
  DELETE FROM descuento    WHERE cuenta_id IN (SELECT id FROM _cuentas_sim);
  DELETE FROM cuenta_linea WHERE cuenta_id IN (SELECT id FROM _cuentas_sim);
  DELETE FROM cuenta       WHERE id        IN (SELECT id FROM _cuentas_sim);

  ALTER TABLE cuenta_linea ENABLE TRIGGER cuenta_linea_no_editar;
  ALTER TABLE descuento    ENABLE TRIGGER descuento_inmutable;
  ALTER TABLE pago         ENABLE TRIGGER pago_inmutable;
END
$sim$;

COMMIT;
