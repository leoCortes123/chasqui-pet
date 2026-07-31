-- =====================================================================
-- Chasqui Pet — db/demo/020_inventario_demo.sql
-- Datos de demostración del módulo de inventario (entregable §13.9).
-- Se carga con:
--
--     bash scripts/cargar-demo.sh
--
-- Qué produce:
--   · 14 medicamentos de catálogo con precio de venta y stock mínimo.
--   · ~20 lotes con vencimientos repartidos a propósito para que la
--     alerta diaria tenga algo que decir en la presentación:
--       – dos productos por debajo del mínimo,
--       – un lote que vence dentro de 5 días (alerta crítica),
--       – dos lotes que vencen dentro del mes,
--       – un lote ya vencido con existencia sin dar de baja.
--   · Las salidas de la jornada, atadas a los turnos que atendió cada
--     veterinario, con sus movimientos fechados a la hora real de la
--     atención.
--
-- Se apoya en 010_turnos_demo.sql: usa los veterinarios y los turnos que
-- ese archivo crea. Por eso se carga después (el script recorre
-- db/demo/*.sql en orden alfabético).
--
-- ADVERTENCIA: es re-ejecutable, y para lograrlo BORRA el catálogo, los
-- lotes y los movimientos marcados como demo. Todo lo de demostración
-- lleva `medicamento.notas = 'DEMO'` y `lote.numero_lote LIKE 'DEMO-%'`:
-- lo que no lleve esa marca no se toca. No ejecute esto sobre una base
-- con inventario real.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

-- ---------------------------------------------------------------------
-- Limpieza de la carga anterior.
--
-- movimiento_inventario es de sólo agregar: el rol de la aplicación no
-- puede borrar (090_grants.sql) y además hay un trigger que lo impide
-- incluso para el dueño de la tabla. Eso es exactamente lo que se quiere
-- en producción. Para poder rehacer la demo se desactiva el trigger
-- dentro de esta transacción y se vuelve a activar antes del COMMIT.
-- Es el único lugar del proyecto donde esto se hace, y a propósito.
-- ---------------------------------------------------------------------
ALTER TABLE movimiento_inventario DISABLE TRIGGER movimiento_inmutable;

DELETE FROM movimiento_inventario mi
 USING medicamento m
 WHERE m.id = mi.medicamento_id AND m.notas = 'DEMO';

DELETE FROM lote l USING medicamento m
 WHERE m.id = l.medicamento_id AND m.notas = 'DEMO';

DELETE FROM medicamento WHERE notas = 'DEMO';

-- ---------------------------------------------------------------------
-- Catálogo
-- ---------------------------------------------------------------------
INSERT INTO medicamento (nombre_generico, nombre_comercial, principio_activo,
                         presentacion, concentracion, unidad_base, categoria,
                         requiere_receta, precio_venta, stock_minimo, notas)
VALUES
  ('Amoxicilina',        'Amoxifar',   'Amoxicilina trihidrato', 'Frasco 100 ml', '150 mg/ml', 'ml',      'Antibiótico',    true,   1200,  200, 'DEMO'),
  ('Enrofloxacina',      'Baytril',    'Enrofloxacina',          'Frasco 50 ml',  '50 mg/ml',  'ml',      'Antibiótico',    true,   2400,  100, 'DEMO'),
  ('Meloxicam',          'Metacam',    'Meloxicam',              'Frasco 20 ml',  '5 mg/ml',   'ml',      'Antiinflamatorio', true, 3500,   60, 'DEMO'),
  ('Dipirona',           NULL,         'Metamizol sódico',       'Frasco 30 ml',  '500 mg/ml', 'ml',      'Analgésico',     false,   900,  100, 'DEMO'),
  ('Ivermectina',        'Ivomec',     'Ivermectina',            'Frasco 50 ml',  '10 mg/ml',  'ml',      'Antiparasitario', true,  1800,   80, 'DEMO'),
  ('Praziquantel',       'Drontal',    'Praziquantel + pirantel','Caja x 10',     '50 mg',     'tableta', 'Antiparasitario', false, 4500,   20, 'DEMO'),
  ('Vacuna triple felina', 'Felocell', 'Virus atenuados',        'Vial monodosis', NULL,       'dosis',   'Biológico',      true,  38000,   10, 'DEMO'),
  ('Vacuna quíntuple canina', 'Vanguard', 'Virus atenuados',     'Vial monodosis', NULL,       'dosis',   'Biológico',      true,  32000,   10, 'DEMO'),
  ('Vacuna antirrábica', NULL,         'Virus inactivado',       'Vial monodosis', NULL,       'dosis',   'Biológico',      true,  25000,   15, 'DEMO'),
  ('Suero fisiológico',  NULL,         'Cloruro de sodio 0.9%',  'Bolsa 500 ml',  '0.9%',      'ml',      'Fluidoterapia',  false,    45, 2000, 'DEMO'),
  ('Dexametasona',       NULL,         'Dexametasona',           'Frasco 20 ml',  '2 mg/ml',   'ml',      'Corticoide',     true,   1500,   40, 'DEMO'),
  ('Ketamina',           NULL,         'Ketamina clorhidrato',   'Frasco 10 ml',  '50 mg/ml',  'ml',      'Anestésico',     true,   9000,   20, 'DEMO'),
  ('Gasa estéril',       NULL,         NULL,                     'Sobre x 5',     NULL,        'unidad',  'Insumo',         false,  1500,   50, 'DEMO'),
  ('Jeringa 3 ml',       NULL,         NULL,                     'Unidad',        NULL,        'unidad',  'Insumo',         false,   700,  100, 'DEMO');

-- ---------------------------------------------------------------------
-- Lotes y su entrada. La existencia NO se escribe a mano: se inserta el
-- movimiento de entrada y el trigger mantiene lote.cantidad_actual. Es la
-- misma ruta que sigue una compra real, así que la demo prueba de paso
-- que el caché y los movimientos cuadran.
-- ---------------------------------------------------------------------
DO $demo$
DECLARE
  r          record;
  v_lote_id  uuid;
  v_admin    uuid;
  v_vets     uuid[];
  v_vet      uuid;
  v_turno    record;
  v_cant     numeric;
BEGIN
  -- Quien "ingresó" la mercancía: el primer usuario con permiso de
  -- entrada; si la demo corre sin superadmin real, cualquiera de demo.
  SELECT vp.usuario_id INTO v_admin
    FROM v_usuario_permiso vp
   WHERE vp.permiso_codigo = 'inventario.entrada'
   ORDER BY vp.usuario_id LIMIT 1;

  SELECT array_agg(u.id ORDER BY u.nombre_completo) INTO v_vets
    FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id
   WHERE ur.rol_codigo = 'veterinario'
     AND u.telegram_user_id BETWEEN 900000000 AND 900000099;

  -- (medicamento, lote, días hasta el vencimiento, cantidad, costo)
  -- Los días negativos son el lote vencido que la alerta debe cazar.
  FOR r IN
    SELECT * FROM (VALUES
      ('Amoxicilina',              'DEMO-AMX-2401',  400,  1500, 620),
      ('Amoxicilina',              'DEMO-AMX-2312',   25,   300, 600),
      ('Enrofloxacina',            'DEMO-ENR-2402',  300,   500, 1300),
      ('Meloxicam',                'DEMO-MLX-2401',  210,   120, 1900),
      ('Meloxicam',                'DEMO-MLX-2309',    5,    40, 1850),
      ('Dipirona',                 'DEMO-DIP-2403',  540,   600, 420),
      ('Ivermectina',              'DEMO-IVM-2401',  365,   300, 950),
      ('Praziquantel',             'DEMO-PZQ-2402',  270,    80, 2100),
      ('Vacuna triple felina',     'DEMO-VTF-2404',  150,    24, 21000),
      ('Vacuna quíntuple canina',  'DEMO-VQC-2404',  120,    40, 18000),
      ('Vacuna quíntuple canina',  'DEMO-VQC-2312',  -20,     6, 17500),
      ('Vacuna antirrábica',       'DEMO-VAR-2403',  240,    30, 12000),
      ('Suero fisiológico',        'DEMO-SUE-2405',  600, 10000,  18),
      ('Dexametasona',             'DEMO-DEX-2402',  330,   120,  800),
      ('Ketamina',                 'DEMO-KET-2401',  400,    30, 5200),
      ('Gasa estéril',             'DEMO-GAS-2404',  900,   150,  700),
      ('Jeringa 3 ml',             'DEMO-JER-2404',  900,   400,  260),
      -- Los dos que quedan por debajo del mínimo a propósito.
      ('Praziquantel',             'DEMO-PZQ-2310',   40,     6, 2050),
      ('Vacuna antirrábica',       'DEMO-VAR-2311',   18,     4, 11800)
    ) AS t(medicamento, numero_lote, dias, cantidad, costo)
  LOOP
    INSERT INTO lote (medicamento_id, numero_lote, fecha_vencimiento,
                      cantidad_inicial, cantidad_actual, costo_unitario, fecha_ingreso)
    SELECT m.id, r.numero_lote, hoy_bogota() + r.dias,
           r.cantidad, 0, r.costo, hoy_bogota() - 30
      FROM medicamento m
     WHERE m.nombre_generico = r.medicamento AND m.notas = 'DEMO'
    RETURNING id INTO v_lote_id;

    CONTINUE WHEN v_lote_id IS NULL;   -- el medicamento no está en el catálogo de demo

    INSERT INTO movimiento_inventario (lote_id, medicamento_id, tipo, cantidad, motivo,
                                       usuario_id, canal, created_at)
    SELECT v_lote_id, l.medicamento_id, 'entrada', r.cantidad,
           'Compra de demostración', v_admin, 'web', now() - interval '30 days'
      FROM lote l WHERE l.id = v_lote_id;
  END LOOP;

  -- -------------------------------------------------------------------
  -- Consumo de la jornada. Cada turno ya finalizado por un veterinario
  -- de demo recibe una o dos salidas, fechadas a la hora en que se
  -- atendió, y despachadas siempre del lote FEFO.
  -- -------------------------------------------------------------------
  IF v_vets IS NULL THEN
    RAISE NOTICE 'No hay veterinarios de demo: se omiten las salidas. Cargue antes 010_turnos_demo.sql.';
  ELSE
    FOR v_turno IN
      SELECT t.id, t.veterinario_id, t.paciente_id, t.consulta_id,
             COALESCE(t.finalizado_at, t.en_atencion_at, t.created_at) AS momento
        FROM turno t
       WHERE t.fecha = hoy_bogota()
         AND t.estado = 'finalizado'
         AND t.veterinario_id = ANY (v_vets)
       ORDER BY t.numero_secuencial
    LOOP
      v_vet := v_turno.veterinario_id;

      -- Cada atención despacha uno o dos productos. Se toma siempre el
      -- lote FEFO del medicamento, que es lo que haría el bot, y la
      -- cantidad depende de la unidad para que los números se vean
      -- creíbles en la tarjeta.
      FOR r IN
        SELECT v.lote_id, v.unidad_base
          FROM v_lote_disponible v
          JOIN medicamento m ON m.id = v.medicamento_id AND m.notas = 'DEMO'
         WHERE v.cantidad_actual > 20
           AND v.lote_id = lote_fefo(v.medicamento_id)
         ORDER BY md5(v.lote_id::text || v_turno.id::text)
         LIMIT (1 + (abs(hashtext(v_turno.id::text)) % 2))
      LOOP
        v_cant := CASE r.unidad_base
                    WHEN 'ml'      THEN 2 + (abs(hashtext(r.lote_id::text)) % 8)
                    WHEN 'dosis'   THEN 1
                    WHEN 'tableta' THEN 1 + (abs(hashtext(r.lote_id::text)) % 2)
                    ELSE 1 + (abs(hashtext(r.lote_id::text)) % 3)
                  END;

        INSERT INTO movimiento_inventario (lote_id, medicamento_id, tipo, cantidad,
                                           turno_id, paciente_id, consulta_id,
                                           usuario_id, canal, created_at)
        SELECT r.lote_id, l.medicamento_id, 'salida', v_cant,
               v_turno.id, v_turno.paciente_id, v_turno.consulta_id,
               v_vet, 'telegram', v_turno.momento
          FROM lote l WHERE l.id = r.lote_id;
      END LOOP;
    END LOOP;
  END IF;

  -- Un ajuste y una baja, para que el libro de movimientos no sea sólo
  -- entradas y salidas cuando se muestre en la presentación.
  SELECT l.id INTO v_lote_id
    FROM lote l JOIN medicamento m ON m.id = l.medicamento_id
   WHERE l.numero_lote = 'DEMO-GAS-2404' AND m.notas = 'DEMO';

  IF v_lote_id IS NOT NULL THEN
    INSERT INTO movimiento_inventario (lote_id, medicamento_id, tipo, cantidad, motivo,
                                       usuario_id, canal, created_at)
    SELECT v_lote_id, l.medicamento_id, 'ajuste_negativo', 5,
           'Conteo físico: faltaban 5 sobres', v_admin, 'web', now() - interval '3 days'
      FROM lote l WHERE l.id = v_lote_id;
  END IF;

  SELECT l.id INTO v_lote_id
    FROM lote l JOIN medicamento m ON m.id = l.medicamento_id
   WHERE l.numero_lote = 'DEMO-DEX-2402' AND m.notas = 'DEMO';

  IF v_lote_id IS NOT NULL THEN
    INSERT INTO movimiento_inventario (lote_id, medicamento_id, tipo, cantidad, motivo,
                                       usuario_id, canal, created_at)
    SELECT v_lote_id, l.medicamento_id, 'baja_dano', 10,
           'Frasco roto al descargar', v_admin, 'web', now() - interval '6 days'
      FROM lote l WHERE l.id = v_lote_id;
  END IF;
END
$demo$;

-- El job diario deja bloqueado lo vencido; se corre aquí para que la demo
-- se vea exactamente como se vería una mañana cualquiera.
SELECT bloquear_lotes_vencidos();

ALTER TABLE movimiento_inventario ENABLE TRIGGER movimiento_inmutable;

COMMIT;
