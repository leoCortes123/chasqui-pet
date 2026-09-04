-- =====================================================================
-- Chasqui Pet — db/simulacion/000_limpiar.sql
-- Deja la base en «clínica recién instalada»: borra TODOS los datos de
-- operación y conserva únicamente lo que trajeron las migraciones más
-- el personal real.
--
-- Se ejecuta con:
--
--     bash scripts/simular.sh limpiar
--
-- QUÉ BORRA (todo, no sólo lo marcado como demo — para eso está este
-- archivo y no la limpieza parcial de db/demo/010_turnos_demo.sql):
--   turnos, consultas, adendas, citas, bloqueos, disponibilidad,
--   remisiones y resultados, controles avisados, cuentas con sus líneas,
--   pagos, descuentos y cierres de caja, inventario entero (catálogo,
--   lotes, movimientos, entradas y proveedores), pacientes y dueños,
--   la cola de tareas, la conversación del bot, el historial del
--   asistente, los updates de Telegram, el rate limit, las sesiones de
--   consultorio y la auditoría.
--
-- QUÉ CONSERVA:
--   sede, consultorio, tipo_servicio, tarifa, rol, permiso, rol_permiso,
--   config, ia_herramienta, schema_version y los usuarios REALES (el
--   superadmin y cualquier persona de la clínica que ya haya entrado),
--   con sus roles, permisos y sesión web abierta.
--
-- Cómo se distingue a una persona de un dato de prueba: por el rango
-- CERRADO 900000000–900999999 que reservó db/demo/010_turnos_demo.sql
-- para el personal inventado. Tiene que ser cerrado por arriba: los ids
-- de Telegram de hoy pasan de los diez dígitos y quedan muy por encima
-- de 900000000, así que un corte abierto («todo lo que supere el
-- rango») borraría justamente a las personas reales.
--
-- ADVERTENCIA: esto NO distingue datos reales de simulados. Si la
-- clínica ya está operando, este archivo borra su historia clínica y su
-- contabilidad. Es una herramienta de banco de pruebas.
--
-- Sobre los triggers: pago, descuento, cuenta_linea y
-- movimiento_inventario son de sólo agregar (§2.2.8 y 090_grants.sql) y
-- lo defienden con triggers que ni el dueño de la tabla puede rodear. Se
-- desactivan DENTRO de esta transacción y se vuelven a activar antes de
-- terminar: si algo falla, el ROLLBACK los devuelve solos.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

ALTER TABLE pago                  DISABLE TRIGGER pago_inmutable;
ALTER TABLE descuento             DISABLE TRIGGER descuento_inmutable;
ALTER TABLE cuenta_linea          DISABLE TRIGGER cuenta_linea_no_editar;
ALTER TABLE cuenta_linea          DISABLE TRIGGER cuenta_linea_recalcular;
ALTER TABLE movimiento_inventario DISABLE TRIGGER movimiento_inmutable;
ALTER TABLE entrada_linea         DISABLE TRIGGER entrada_linea_borrador;
ALTER TABLE entrada_linea         DISABLE TRIGGER entrada_linea_recalcular;
ALTER TABLE consulta              DISABLE TRIGGER consulta_no_editar_firmada;

-- ---------------------------------------------------------------------
-- 1. Soltar las referencias cruzadas.
-- El turno apunta a cuenta, consulta y paciente; la cita al turno; el
-- lote a la entrada. Se ponen en NULL antes de borrar para no depender
-- del orden exacto de las claves foráneas.
-- ---------------------------------------------------------------------
UPDATE turno SET cuenta_id = NULL, consulta_id = NULL,
                 paciente_id = NULL, dueno_id = NULL;
UPDATE cita  SET turno_id = NULL, consulta_origen_id = NULL;
UPDATE lote  SET entrada_id = NULL;

-- ---------------------------------------------------------------------
-- 2. Dinero (§7). De abajo hacia arriba: recibos, luego la cuenta.
-- ---------------------------------------------------------------------
DELETE FROM pago;
DELETE FROM descuento;
DELETE FROM cuenta_linea;
DELETE FROM cuenta;
DELETE FROM cierre_caja;

-- ---------------------------------------------------------------------
-- 3. Inventario y compras (§6, §10).
-- El movimiento va primero: es lo que sostiene la existencia del lote.
-- ---------------------------------------------------------------------
DELETE FROM movimiento_inventario;
DELETE FROM entrada_linea;
DELETE FROM entrada_inventario;
DELETE FROM lote;
DELETE FROM medicamento;
DELETE FROM proveedor;

-- ---------------------------------------------------------------------
-- 4. Módulos del bloque B: remisiones (§B3), agenda (§B1) y controles
-- (§B2). El resultado cuelga de la remisión y el aviso de la consulta.
-- ---------------------------------------------------------------------
DELETE FROM resultado_remision;
DELETE FROM remision;
DELETE FROM cita;
DELETE FROM bloqueo_agenda;
DELETE FROM disponibilidad;
DELETE FROM aviso_control_enviado;

-- ---------------------------------------------------------------------
-- 5. Clínico (§8) y turnos (§5).
-- ---------------------------------------------------------------------
DELETE FROM consulta_adenda;
DELETE FROM consulta;
DELETE FROM aviso_turno_enviado;
DELETE FROM turno;
DELETE FROM paciente;
DELETE FROM dueno;

-- ---------------------------------------------------------------------
-- 6. Estado volátil: cola, bot, asistente, sesiones de consultorio.
-- Nada de esto es historia; es el sistema en marcha, y una base limpia
-- no está en marcha.
-- ---------------------------------------------------------------------
DELETE FROM tarea_async;
DELETE FROM conversacion_estado;
DELETE FROM ia_accion_pendiente;
DELETE FROM ia_mensaje;
DELETE FROM ia_plan;
DELETE FROM telegram_update;
DELETE FROM rate_limit;
DELETE FROM sesion_consultorio;
DELETE FROM auth_challenge;

-- ---------------------------------------------------------------------
-- 7. Personal inventado. Los roles, permisos y sesiones cuelgan con
-- ON DELETE CASCADE, así que se van con el usuario.
-- ---------------------------------------------------------------------
DELETE FROM usuario WHERE telegram_user_id BETWEEN 900000000 AND 900999999;

-- ---------------------------------------------------------------------
-- 8. Auditoría. Es append-only para la aplicación y se borra aquí a
-- propósito: dejar el rastro de unos turnos que ya no existen ensucia
-- los reportes y las métricas del asistente, que es justo lo que se va a
-- probar. Se hace de últimas para que los DELETE de arriba no dejen
-- filas nuevas detrás.
-- ---------------------------------------------------------------------
DELETE FROM evento_auditoria;

ALTER TABLE consulta              ENABLE TRIGGER consulta_no_editar_firmada;
ALTER TABLE entrada_linea         ENABLE TRIGGER entrada_linea_recalcular;
ALTER TABLE entrada_linea         ENABLE TRIGGER entrada_linea_borrador;
ALTER TABLE movimiento_inventario ENABLE TRIGGER movimiento_inmutable;
ALTER TABLE cuenta_linea          ENABLE TRIGGER cuenta_linea_recalcular;
ALTER TABLE cuenta_linea          ENABLE TRIGGER cuenta_linea_no_editar;
ALTER TABLE descuento             ENABLE TRIGGER descuento_inmutable;
ALTER TABLE pago                  ENABLE TRIGGER pago_inmutable;

DO $$
BEGIN
  RAISE NOTICE 'Base limpia: quedan % usuario(s) real(es), % sede(s), % tipo(s) de servicio.',
    (SELECT count(*) FROM usuario),
    (SELECT count(*) FROM sede),
    (SELECT count(*) FROM tipo_servicio);
END
$$;

COMMIT;
