-- =====================================================================
-- Chasqui Pet — db/demo/050_compras_demo.sql
-- Datos de demostración de proveedores y compras (entregable §13.9).
-- Se carga con:
--
--     bash scripts/cargar-demo.sh
--
-- Qué produce:
--   · Cuatro proveedores con teléfono y NIT.
--   · Las compras de las que salió el inventario que ya existe: en vez de
--     ingresar mercancía nueva —que dejaría el stock inflado al doble— se
--     le pone origen a los lotes que 020_inventario_demo.sql ya creó. Al
--     terminar, cada lote sabe de qué factura vino y de qué proveedor, que
--     es lo que hace demostrable la trazabilidad (§10.9).
--   · Una factura a medio digitar, en borrador, para poder enseñar en vivo
--     que lo que no se ha confirmado no ha tocado el inventario.
--
-- Se carga después de 020_inventario_demo.sql, del que depende.
--
-- ADVERTENCIA: es re-ejecutable, y para lograrlo BORRA los proveedores y
-- las entradas marcados como demo (`notas = 'DEMO'` y
-- `observaciones = 'DEMO'`). No ejecute esto sobre una base con compras
-- reales.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

-- ---------------------------------------------------------------------
-- Limpieza de la carga anterior
-- ---------------------------------------------------------------------
UPDATE lote SET entrada_id = NULL
 WHERE entrada_id IN (SELECT id FROM entrada_inventario WHERE observaciones = 'DEMO');

-- Los renglones de una entrada confirmada no se borran (trigger
-- `entrada_exigir_borrador`), y así debe ser en operación. Para poder
-- rehacer la demo se devuelven a borrador primero; es el equivalente al
-- DISABLE TRIGGER de 020_inventario_demo, y por la misma razón.
UPDATE entrada_inventario SET estado = 'borrador' WHERE observaciones = 'DEMO';

DELETE FROM entrada_linea
 WHERE entrada_id IN (SELECT id FROM entrada_inventario WHERE observaciones = 'DEMO');

DELETE FROM entrada_inventario WHERE observaciones = 'DEMO';
DELETE FROM proveedor WHERE notas = 'DEMO';

-- ---------------------------------------------------------------------
-- Proveedores
-- ---------------------------------------------------------------------
INSERT INTO proveedor (nombre, tipo_documento, numero_documento, telefono,
                       email, contacto, direccion, notas)
VALUES
  ('Distribuidora Veterinaria del Norte', 'NIT', '830045129-3', '3104458821',
   'pedidos@distrivetnorte.com', 'Claudia Pineda', 'Calle 72 # 24-18, Bogotá', 'DEMO'),
  ('Laboratorios Zoovet',                 'NIT', '900218447-1', '3157742019',
   'ventas@zoovet.com.co', 'Andrés Salgado', 'Carrera 30 # 12-45, Bogotá', 'DEMO'),
  ('Agrocampo Suministros',               'NIT', '811004392-6', '3012209987',
   NULL, 'Mónica Ruiz', 'Autopista Sur # 68-12, Bogotá', 'DEMO'),
  ('Droguería Animal Express',            'NIT', '901552310-8', '3209914455',
   'contacto@animalexpress.co', 'Iván Ramírez', 'Calle 45 # 13-60, Bogotá', 'DEMO');

-- ---------------------------------------------------------------------
-- Las compras que originaron el inventario actual
--
-- Los lotes de demostración se reparten entre los proveedores de forma
-- estable —por el hash del número de lote, no al azar— para que dos
-- cargas seguidas den el mismo resultado y la presentación no cambie de
-- una vez a otra.
--
-- Cada entrada se arma en borrador (que es la única forma de insertar
-- renglones: el trigger de 070_compras.sql lo exige) y después se marca
-- confirmada a mano, porque los lotes y los movimientos ya existen y
-- volver a crearlos duplicaría la existencia.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_admin    uuid;
  v_sede     uuid;
  r          record;
  v_entrada  uuid;
  v_n        int := 0;
BEGIN
  SELECT u.id INTO v_admin
    FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id
   WHERE ur.rol_codigo IN ('admin','superadmin')
   ORDER BY ur.rol_codigo LIMIT 1;

  SELECT id INTO v_sede FROM sede WHERE activa ORDER BY created_at LIMIT 1;

  -- Una entrada por proveedor y por mes de ingreso: así se parece a lo
  -- que pasa de verdad, que es una factura cada tanto y no una por frasco.
  FOR r IN
    SELECT p.id AS proveedor_id,
           date_trunc('month', l.fecha_ingreso)::date AS mes,
           min(l.fecha_ingreso) AS fecha,
           array_agg(l.id) AS lotes
      FROM lote l
      JOIN medicamento m ON m.id = l.medicamento_id
      JOIN LATERAL (
        SELECT pr.id, row_number() OVER (ORDER BY pr.nombre) AS n
          FROM proveedor pr WHERE pr.notas = 'DEMO'
      ) p ON p.n = 1 + (abs(hashtext(l.numero_lote)) % 4)
     WHERE m.notas = 'DEMO' AND l.numero_lote LIKE 'DEMO-%'
     GROUP BY p.id, date_trunc('month', l.fecha_ingreso)
  LOOP
    INSERT INTO entrada_inventario (sede_id, proveedor_id, tipo, fecha,
                                    documento_soporte, usuario_id, canal,
                                    observaciones, estado)
    VALUES (v_sede, r.proveedor_id, 'compra', r.fecha,
            'FV-' || to_char(r.fecha, 'YYMM') || '-' ||
            lpad((100 + (abs(hashtext(r.proveedor_id::text || r.mes::text)) % 899))::text, 3, '0'),
            v_admin, 'web', 'DEMO', 'borrador')
    RETURNING id INTO v_entrada;

    INSERT INTO entrada_linea (entrada_id, medicamento_id, numero_lote,
                               fecha_vencimiento, cantidad, costo_unitario, lote_id)
    SELECT v_entrada, l.medicamento_id, l.numero_lote, l.fecha_vencimiento,
           l.cantidad_inicial, l.costo_unitario, l.id
      FROM lote l WHERE l.id = ANY (r.lotes);

    UPDATE lote SET entrada_id = v_entrada WHERE id = ANY (r.lotes);

    -- La existencia ya entró cuando 020_inventario_demo creó los
    -- movimientos: aquí sólo se le pone nombre y factura al origen.
    UPDATE entrada_inventario
       SET estado = 'confirmada',
           confirmada_at = r.fecha + time '09:30',
           confirmada_por = v_admin
     WHERE id = v_entrada;

    v_n := v_n + 1;
  END LOOP;

  RAISE NOTICE 'Compras de demostración: % entradas confirmadas', v_n;

  -- -------------------------------------------------------------------
  -- La factura a medio digitar. Es lo que se enseña en la presentación
  -- para explicar por qué existe el borrador: dos renglones tecleados,
  -- cero movimiento en el inventario.
  -- -------------------------------------------------------------------
  INSERT INTO entrada_inventario (sede_id, proveedor_id, tipo, fecha,
                                  documento_soporte, usuario_id, canal,
                                  observaciones, estado)
  SELECT v_sede, pr.id, 'compra', hoy_bogota(), 'FV-2610-441',
         v_admin, 'telegram', 'DEMO', 'borrador'
    FROM proveedor pr WHERE pr.notas = 'DEMO' AND pr.nombre = 'Laboratorios Zoovet'
  RETURNING id INTO v_entrada;

  INSERT INTO entrada_linea (entrada_id, medicamento_id, numero_lote,
                             fecha_vencimiento, cantidad, costo_unitario)
  SELECT v_entrada, m.id, v.numero_lote, hoy_bogota() + v.dias, v.cantidad, v.costo
    FROM (VALUES
      ('Amoxicilina',  'ZV-4471', 540, 40, 520),
      ('Meloxicam',    'ZV-4489', 690, 25, 880)
    ) AS v(medicamento, numero_lote, dias, cantidad, costo)
    JOIN medicamento m ON m.nombre_generico = v.medicamento AND m.notas = 'DEMO';
END $$;

COMMIT;
