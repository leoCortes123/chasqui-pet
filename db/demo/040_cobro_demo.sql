-- =====================================================================
-- Chasqui Pet — db/demo/040_cobro_demo.sql
-- Datos de demostración del módulo de cobro (entregable §13.9). Se carga
-- con:
--
--     bash scripts/cargar-demo.sh
--
-- Qué produce:
--   · La caja del día abierta con base, para poder cerrarla en vivo
--     durante la presentación.
--   · Una cuenta por cada turno atendido hoy —la cuenta se abre sola al
--     entrar en atención, haya paciente registrado o no—: la tarifa del
--     servicio más los medicamentos que se despacharon en esa visita, al
--     precio de venta del catálogo.
--   · La mayoría cerradas y pagadas —efectivo, transferencia y datáfono
--     repartidos como en la vida real— con su recibo consecutivo.
--   · Tres o cuatro cuentas ABIERTAS, que es lo que el auxiliar ve al
--     tocar «💵 Cobrar» durante la demostración.
--   · Un par de descuentos con motivo y un cobro parcial (abonado a
--     medias), para que el reporte de descuentos y el saldo pendiente no
--     salgan vacíos.
--
-- Se apoya en 010 (turnos y personal), 020 (salidas de medicamento) y
-- 030 (pacientes y consultas). Por eso se carga al final.
--
-- La limpieza de la carga anterior vive en 010_turnos_demo.sql, junto con
-- la de los turnos: hay que soltar las cuentas antes de poder borrar los
-- turnos y los pacientes de los que cuelgan.
--
-- No ejecute esto sobre una base con caja real.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

DO $demo$
DECLARE
  v_sede    uuid;
  v_aux     uuid;
  v_caja    uuid;
  v_turno   record;
  v_cuenta  uuid;
  v_tarifa  tarifa;
  v_recibo  int;
  v_apertura timestamptz;
  v_cierre  timestamptz;
  v_medio   text;
  v_r       double precision;
  v_desc    numeric;
  v_total   numeric;
  v_i       int := 0;
  v_abiertas int := 0;
  v_cerradas int := 0;
  v_pendientes int := 0;
  v_finalizados int;
BEGIN
  SELECT id INTO v_sede FROM sede WHERE activa ORDER BY created_at LIMIT 1;
  IF v_sede IS NULL THEN
    RAISE EXCEPTION 'No hay ninguna sede activa. Ejecute primero las migraciones.';
  END IF;

  SELECT id INTO v_aux FROM usuario WHERE telegram_user_id = 900000003;
  IF v_aux IS NULL THEN
    RAISE EXCEPTION 'Falta el personal de demo. Cargue antes 010_turnos_demo.sql.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM tarifa WHERE activa) THEN
    RAISE EXCEPTION 'No hay tarifas configuradas (110_seed_operativo.sql).';
  END IF;

  -- ===================================================================
  -- Caja del día. Se deja ABIERTA a propósito: cerrarla es una de las
  -- cosas que se enseñan en vivo, y necesita tener dinero dentro.
  -- ===================================================================
  SELECT COALESCE(min(created_at), now()) INTO v_apertura
    FROM turno WHERE sede_id = v_sede AND fecha = hoy_bogota();

  INSERT INTO cierre_caja (sede_id, fecha, usuario_id, apertura_at, base_inicial, notas)
  VALUES (v_sede, hoy_bogota(), v_aux, v_apertura, 200000,
          'Caja de demostración')
  RETURNING id INTO v_caja;

  SELECT COALESCE(MAX(recibo_numero), 0) INTO v_recibo FROM cuenta WHERE sede_id = v_sede;

  SELECT count(*) INTO v_finalizados
    FROM turno WHERE sede_id = v_sede AND fecha = hoy_bogota()
     AND estado = 'finalizado';

  -- ===================================================================
  -- Una cuenta por visita atendida. Las últimas tres del día se quedan
  -- abiertas: son las que el auxiliar tiene por cobrar ahora mismo.
  -- ===================================================================
  FOR v_turno IN
    SELECT t.*, ts.codigo AS tipo_codigo,
           row_number() OVER (ORDER BY t.numero_secuencial) AS n
      FROM turno t
      JOIN tipo_servicio ts ON ts.id = t.tipo_servicio_id
     WHERE t.sede_id = v_sede AND t.fecha = hoy_bogota()
       AND t.estado IN ('finalizado','en_atencion')
     ORDER BY t.numero_secuencial
  LOOP
    v_i := v_i + 1;
    -- Pseudoaleatorio estable: la misma carga produce siempre lo mismo,
    -- así la demostración es repetible.
    v_r := (abs(hashtext(v_turno.id::text)) % 1000) / 1000.0;

    v_apertura := COALESCE(v_turno.en_atencion_at, v_turno.created_at);

    INSERT INTO cuenta (sede_id, fecha, turno_id, consulta_id, paciente_id, dueno_id,
                        abierta_por, canal_origen, fecha_apertura, created_at)
    VALUES (v_sede, hoy_bogota(), v_turno.id, v_turno.consulta_id,
            v_turno.paciente_id, v_turno.dueno_id,
            v_turno.veterinario_id, 'telegram', v_apertura, v_apertura)
    RETURNING id INTO v_cuenta;

    UPDATE turno SET cuenta_id = v_cuenta WHERE id = v_turno.id;

    -- La tarifa del servicio por el que vino.
    SELECT * INTO v_tarifa FROM tarifa t
      JOIN tipo_servicio ts ON ts.id = t.tipo_servicio_id
     WHERE t.activa AND ts.codigo = v_turno.tipo_codigo
     LIMIT 1;

    IF v_tarifa.id IS NULL THEN
      SELECT * INTO v_tarifa FROM tarifa WHERE codigo = 'consulta_general';
    END IF;

    INSERT INTO cuenta_linea (cuenta_id, tipo, referencia_id, descripcion,
                              cantidad, valor_unitario, usuario_id, canal, created_at)
    VALUES (v_cuenta, 'servicio', v_tarifa.id, v_tarifa.nombre, 1,
            v_tarifa.valor_sugerido, v_turno.veterinario_id, 'telegram',
            v_apertura + interval '2 minutes');

    -- Los medicamentos que salieron en esa visita, al precio del catálogo.
    -- En operación real esta línea la crea el worker al despacharlos; aquí
    -- se replica el resultado sobre los movimientos que dejó 020.
    INSERT INTO cuenta_linea (cuenta_id, tipo, referencia_id, movimiento_id, descripcion,
                              cantidad, valor_unitario, usuario_id, canal, created_at)
    SELECT v_cuenta, 'medicamento', m.id, mi.id,
           m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', ''),
           mi.cantidad, m.precio_venta, mi.usuario_id, 'telegram', mi.created_at
      FROM movimiento_inventario mi
      JOIN medicamento m ON m.id = mi.medicamento_id
     WHERE mi.turno_id = v_turno.id AND mi.tipo = 'salida'
       AND NOT EXISTS (SELECT 1 FROM cuenta_linea cl WHERE cl.movimiento_id = mi.id);

    -- Un descuento de cada doce, siempre con motivo (§7.3).
    IF v_r < 0.08 THEN
      SELECT round(subtotal * 0.10, -2) INTO v_desc FROM cuenta WHERE id = v_cuenta;
      IF v_desc > 0 THEN
        INSERT INTO descuento (cuenta_id, valor, motivo, autorizado_por, canal, created_at)
        VALUES (v_cuenta, v_desc,
                CASE WHEN v_r < 0.04 THEN 'Cliente frecuente'
                     ELSE 'Segunda mascota de la misma familia' END,
                v_aux, 'telegram', v_apertura + interval '20 minutes');
      END IF;
    END IF;

    SELECT total INTO v_total FROM cuenta WHERE id = v_cuenta;

    -- Las últimas tres visitas y las que siguen en atención quedan sin
    -- cobrar: es lo que el auxiliar ve en «💵 Cobrar» al abrir la demo.
    IF v_turno.estado <> 'finalizado' OR v_i > v_finalizados - 3 THEN
      v_abiertas := v_abiertas + 1;
      CONTINUE;
    END IF;

    v_cierre := COALESCE(v_turno.finalizado_at, now()) + interval '4 minutes';
    v_medio := CASE WHEN v_r < 0.55 THEN 'efectivo'
                    WHEN v_r < 0.80 THEN 'datafono'
                    ELSE 'transferencia' END;

    -- Un abono a medias: hay quien paga una parte y vuelve por la tarde.
    IF v_r >= 0.94 AND v_total > 20000 THEN
      INSERT INTO pago (cuenta_id, cierre_caja_id, medio, valor, usuario_id, canal, created_at)
      VALUES (v_cuenta, v_caja, 'efectivo', round(v_total / 2, -2), v_aux, 'telegram', v_cierre);
      v_abiertas := v_abiertas + 1;
      v_pendientes := v_pendientes + 1;
      CONTINUE;
    END IF;

    IF v_total > 0 THEN
      INSERT INTO pago (cuenta_id, cierre_caja_id, medio, valor, referencia,
                        usuario_id, canal, created_at)
      VALUES (v_cuenta, v_caja, v_medio, v_total,
              CASE WHEN v_medio = 'datafono'
                   THEN 'Aprob. ' || lpad((abs(hashtext(v_cuenta::text)) % 1000000)::text, 6, '0')
              END,
              v_aux, 'telegram', v_cierre);
    END IF;

    v_recibo := v_recibo + 1;
    UPDATE cuenta
       SET estado = 'cerrada', fecha_cierre = v_cierre, cerrada_por = v_aux,
           recibo_numero = v_recibo, cierre_caja_id = v_caja
     WHERE id = v_cuenta;

    v_cerradas := v_cerradas + 1;
  END LOOP;

  PERFORM auditar('demo', '040_cobro_demo', 'cargar', NULL, 'sistema', NULL,
                  jsonb_build_object('cuentas_cerradas', v_cerradas,
                                     'cuentas_abiertas', v_abiertas,
                                     'con_abono', v_pendientes,
                                     'caja_id', v_caja),
                  'Carga de datos de demostración del módulo de cobro');

  RAISE NOTICE 'Demo cobro: % cuentas cerradas, % abiertas (% con abono parcial). Caja abierta con base %.',
               v_cerradas, v_abiertas, v_pendientes, pesos(200000);
  RAISE NOTICE 'Caja del día: %', resumen_caja_dia(v_sede);
END
$demo$;

COMMIT;
