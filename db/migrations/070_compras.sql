-- =====================================================================
-- Chasqui Pet — 070_compras.sql
-- Proveedores y entradas de inventario por compra (§9).
--
-- La regla que gobierna el módulo: **una entrada en borrador no existe
-- para el inventario**. Se arma con calma —el auxiliar está tecleando
-- una factura de doce renglones con el proveedor esperando— y sólo al
-- confirmarla se crean los lotes y los movimientos. Antes de eso el
-- stock no se ha movido ni un gramo, y descartar el borrador no deja
-- rastro que haya que corregir después.
--
-- Al confirmar, los lotes se crean a través de `ingresar_lote` (045), la
-- misma función que usa cualquier otro ingreso. No hay un segundo camino
-- para meter existencia al sistema: si lo hubiera, el stock derivado
-- dejaría de cuadrar con los movimientos por alguno de los dos.
--
-- Lo que se confirmó no se edita. Un error en una entrada confirmada se
-- corrige con un ajuste de inventario, que queda con su motivo y su
-- responsable, igual que todo lo demás (§2.2.8).
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Proveedor
-- ---------------------------------------------------------------------
CREATE TABLE proveedor (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre          text NOT NULL,
  tipo_documento  text CHECK (tipo_documento IN ('NIT','CC','CE','PAS','OTRO')),
  numero_documento text,
  telefono        text,
  email           text,
  contacto        text,                  -- la persona con la que se habla
  direccion       text,
  notas           text,
  activo          boolean NOT NULL DEFAULT true,
  -- Se busca por nombre escrito de memoria y con prisa, igual que el
  -- catálogo de medicamentos: trigramas y normalización.
  busqueda        text GENERATED ALWAYS AS (
                    normalizar(coalesce(nombre,'') || ' ' ||
                               coalesce(contacto,'') || ' ' ||
                               coalesce(numero_documento,''))
                  ) STORED,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER proveedor_touch BEFORE UPDATE ON proveedor
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_proveedor_busqueda ON proveedor USING gin (busqueda gin_trgm_ops);
CREATE INDEX idx_proveedor_activo ON proveedor (activo) WHERE activo;
CREATE UNIQUE INDEX idx_proveedor_nombre ON proveedor (normalizar(nombre));
-- El documento identifica al proveedor cuando lo hay; no siempre lo hay.
CREATE UNIQUE INDEX idx_proveedor_documento
  ON proveedor (numero_documento) WHERE numero_documento IS NOT NULL;

-- ---------------------------------------------------------------------
-- Entrada de inventario — cabecera
-- ---------------------------------------------------------------------
CREATE TABLE entrada_inventario (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sede_id          uuid REFERENCES sede(id),
  proveedor_id     uuid REFERENCES proveedor(id),   -- nulo en el ajuste inicial
  tipo             text NOT NULL DEFAULT 'compra'
                     CHECK (tipo IN ('compra','ajuste_inicial')),
  fecha            date NOT NULL DEFAULT hoy_bogota(),
  documento_soporte text,                -- número de factura o remisión
  valor_total      numeric(14,2) NOT NULL DEFAULT 0 CHECK (valor_total >= 0),
  -- La foto de la factura llega por Telegram: se guarda el file_id, que es
  -- lo que la Bot API necesita para volver a mandarla, y la URL cuando la
  -- carga viene del portal.
  adjunto_file_id  text,
  adjunto_url      text,
  usuario_id       uuid REFERENCES usuario(id),
  canal            text NOT NULL DEFAULT 'telegram'
                     CHECK (canal IN ('telegram','web','job','sistema')),
  observaciones    text,
  estado           text NOT NULL DEFAULT 'borrador'
                     CHECK (estado IN ('borrador','confirmada','descartada')),
  confirmada_at    timestamptz,
  confirmada_por   uuid REFERENCES usuario(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER entrada_touch BEFORE UPDATE ON entrada_inventario
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_entrada_fecha ON entrada_inventario (fecha DESC, created_at DESC);
CREATE INDEX idx_entrada_proveedor ON entrada_inventario (proveedor_id, fecha DESC);
-- El borrador de cada quien: es lo que hay que reencontrar al volver al bot.
CREATE INDEX idx_entrada_borrador ON entrada_inventario (usuario_id, created_at DESC)
  WHERE estado = 'borrador';

-- Ya se puede cerrar el círculo: el lote sabe de qué compra vino, y por
-- ahí se llega al proveedor y a la factura (§10.9, trazabilidad).
ALTER TABLE lote
  ADD CONSTRAINT lote_entrada_fk FOREIGN KEY (entrada_id) REFERENCES entrada_inventario(id);
CREATE INDEX idx_lote_entrada ON lote (entrada_id) WHERE entrada_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- Entrada de inventario — líneas
-- ---------------------------------------------------------------------
CREATE TABLE entrada_linea (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entrada_id       uuid NOT NULL REFERENCES entrada_inventario(id) ON DELETE CASCADE,
  medicamento_id   uuid NOT NULL REFERENCES medicamento(id),
  numero_lote      text,                 -- hay proveedores que no lo imprimen
  fecha_vencimiento date NOT NULL,
  cantidad         numeric(12,3) NOT NULL CHECK (cantidad > 0),
  costo_unitario   numeric(12,2) NOT NULL DEFAULT 0 CHECK (costo_unitario >= 0),
  valor_total      numeric(14,2) GENERATED ALWAYS AS (round(cantidad * costo_unitario, 2)) STORED,
  lote_id          uuid REFERENCES lote(id),   -- se llena al confirmar
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_entrada_linea_entrada ON entrada_linea (entrada_id, created_at);
CREATE INDEX idx_entrada_linea_medicamento ON entrada_linea (medicamento_id, created_at DESC);

-- Una entrada confirmada es historia: ya generó lotes y movimientos, y
-- editar sus renglones dejaría la factura diciendo una cosa y el
-- inventario otra.
CREATE OR REPLACE FUNCTION entrada_exigir_borrador() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  SELECT estado INTO v_estado FROM entrada_inventario
   WHERE id = COALESCE(NEW.entrada_id, OLD.entrada_id);

  IF v_estado IS DISTINCT FROM 'borrador' THEN
    RAISE EXCEPTION 'La entrada ya no está en borrador: corrija con un ajuste de inventario'
      USING ERRCODE = '0A000';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- El UPDATE se exceptúa sólo para el lote_id que escribe la confirmación:
-- ese cambio es la confirmación misma, no una edición.
CREATE TRIGGER entrada_linea_borrador
  BEFORE INSERT OR DELETE ON entrada_linea
  FOR EACH ROW EXECUTE FUNCTION entrada_exigir_borrador();

-- La cabecera guarda el total como caché consultable; la verdad son las
-- líneas. Se recalcula solo, para que nadie tenga que sumar a mano.
CREATE OR REPLACE FUNCTION entrada_recalcular(p_entrada_id uuid)
RETURNS void
LANGUAGE sql AS $$
  UPDATE entrada_inventario e
     SET valor_total = COALESCE((SELECT sum(valor_total) FROM entrada_linea
                                  WHERE entrada_id = p_entrada_id), 0)
   WHERE e.id = p_entrada_id AND e.estado = 'borrador';
$$;

CREATE OR REPLACE FUNCTION entrada_recalcular_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM entrada_recalcular(COALESCE(NEW.entrada_id, OLD.entrada_id));
  RETURN NULL;
END;
$$;

CREATE TRIGGER entrada_linea_recalcular
  AFTER INSERT OR UPDATE OR DELETE ON entrada_linea
  FOR EACH ROW EXECUTE FUNCTION entrada_recalcular_trigger();

-- ---------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------

-- Fechas escritas a mano por alguien que está mirando una caja. Se acepta
-- lo que la gente escribe de verdad:
--   31/12/2027  31-12-2027  31/12/27  → ese día
--   12/2027     12-27                 → el último día del mes, que es lo
--                                       que dice una caja de medicamento
--                                       cuando sólo trae mes y año
--   2027-12-31                        → formato ISO, por si viene del portal
CREATE OR REPLACE FUNCTION parse_fecha(p_texto text) RETURNS date
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  -- Se quitan espacios y el punto se trata como separador: «31.12.2027»
  -- es lo que trae impreso media caja de medicamento.
  t text := replace(regexp_replace(trim(COALESCE(p_texto, '')), '\s+', '', 'g'), '.', '/');
  m text[];
  v_a int; v_m int; v_d int;
BEGIN
  IF t = '' THEN RETURN NULL; END IF;

  -- ISO primero: es el único que empieza por cuatro dígitos.
  m := regexp_match(t, '^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$');
  IF m IS NOT NULL THEN
    v_a := m[1]::int; v_m := m[2]::int; v_d := m[3]::int;
  ELSE
    m := regexp_match(t, '^(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})$');
    IF m IS NOT NULL THEN
      v_d := m[1]::int; v_m := m[2]::int; v_a := m[3]::int;
    ELSE
      m := regexp_match(t, '^(\d{1,2})[-/](\d{2,4})$');
      IF m IS NULL THEN RETURN NULL; END IF;
      v_m := m[1]::int; v_a := m[2]::int; v_d := NULL;
    END IF;
  END IF;

  -- Dos dígitos de año son de este siglo: un vencimiento nunca es de 1927.
  IF v_a < 100 THEN v_a := 2000 + v_a; END IF;
  IF v_m < 1 OR v_m > 12 OR v_a < 2000 OR v_a > 2100 THEN RETURN NULL; END IF;

  IF v_d IS NULL THEN
    -- Sólo mes y año: vence el último día de ese mes.
    RETURN (make_date(v_a, v_m, 1) + interval '1 month - 1 day')::date;
  END IF;

  IF v_d < 1 OR v_d > 31 THEN RETURN NULL; END IF;

  BEGIN
    RETURN make_date(v_a, v_m, v_d);
  EXCEPTION WHEN others THEN
    RETURN NULL;   -- 31 de febrero y demás
  END;
END;
$$;

CREATE OR REPLACE FUNCTION nombre_estado_entrada(p_estado text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE p_estado
           WHEN 'borrador'   THEN 'Borrador'
           WHEN 'confirmada' THEN 'Confirmada'
           WHEN 'descartada' THEN 'Descartada'
           ELSE p_estado
         END;
$$;

-- ---------------------------------------------------------------------
-- Lectura
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION proveedor_json(p_proveedor_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'proveedor_id',    p.id,
    'nombre',          p.nombre,
    'tipo_documento',  p.tipo_documento,
    'numero_documento', p.numero_documento,
    'telefono',        p.telefono,
    'email',           p.email,
    'contacto',        p.contacto,
    'direccion',       p.direccion,
    'notas',           p.notas,
    'activo',          p.activo,
    'compras',         (SELECT count(*) FROM entrada_inventario e
                         WHERE e.proveedor_id = p.id AND e.estado = 'confirmada'),
    'ultima_compra',   (SELECT max(fecha) FROM entrada_inventario e
                         WHERE e.proveedor_id = p.id AND e.estado = 'confirmada'))
  FROM proveedor p WHERE p.id = p_proveedor_id;
$$;

CREATE OR REPLACE FUNCTION buscar_proveedor(p_texto text, p_limite int DEFAULT 5)
RETURNS TABLE (proveedor_id uuid, nombre text, telefono text, puntaje real)
LANGUAGE sql STABLE AS $$
  WITH q AS (SELECT normalizar(COALESCE(p_texto, '')) AS t)
  SELECT p.id, p.nombre, p.telefono,
         GREATEST(similarity(p.busqueda, q.t),
                  CASE WHEN p.busqueda LIKE q.t || '%' THEN 0.95
                       WHEN position(q.t in p.busqueda) > 0 THEN 0.85
                       ELSE 0 END)::real AS puntaje
    FROM proveedor p CROSS JOIN q
   WHERE p.activo AND q.t <> ''
     AND (p.busqueda % q.t OR position(q.t in p.busqueda) > 0)
   ORDER BY puntaje DESC, p.nombre
   LIMIT GREATEST(p_limite, 1);
$$;

-- Los de siempre primero: en la práctica se le compra a tres o cuatro.
CREATE OR REPLACE FUNCTION proveedores_frecuentes(p_limite int DEFAULT 5)
RETURNS TABLE (proveedor_id uuid, nombre text, compras bigint, ultima date)
LANGUAGE sql STABLE AS $$
  SELECT p.id, p.nombre,
         count(e.id) FILTER (WHERE e.estado = 'confirmada'),
         max(e.fecha) FILTER (WHERE e.estado = 'confirmada')
    FROM proveedor p
    LEFT JOIN entrada_inventario e ON e.proveedor_id = p.id
   WHERE p.activo
   GROUP BY p.id, p.nombre
   ORDER BY count(e.id) FILTER (WHERE e.estado = 'confirmada') DESC,
            max(e.fecha) FILTER (WHERE e.estado = 'confirmada') DESC NULLS LAST,
            p.nombre
   LIMIT GREATEST(p_limite, 1);
$$;

CREATE OR REPLACE FUNCTION entrada_json(p_entrada_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'entrada_id',    e.id,
    'estado',        e.estado,
    'estado_nombre', nombre_estado_entrada(e.estado),
    'tipo',          e.tipo,
    'fecha',         e.fecha,
    'proveedor_id',  e.proveedor_id,
    'proveedor',     pr.nombre,
    'documento',     e.documento_soporte,
    'observaciones', e.observaciones,
    'valor_total',   e.valor_total,
    'tiene_adjunto', (e.adjunto_file_id IS NOT NULL OR e.adjunto_url IS NOT NULL),
    'adjunto_file_id', e.adjunto_file_id,
    'adjunto_url',   e.adjunto_url,
    'registrada_por', u.nombre_completo,
    'confirmada_at', to_char(e.confirmada_at AT TIME ZONE 'America/Bogota', 'DD/MM/YYYY HH24:MI'),
    'lineas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'linea_id',    l.id,
               'medicamento_id', l.medicamento_id,
               'medicamento', m.nombre_generico ||
                              COALESCE(' (' || m.nombre_comercial || ')', ''),
               'unidad',      m.unidad_base,
               'lote',        l.numero_lote,
               'vence',       l.fecha_vencimiento,
               'cantidad',    l.cantidad,
               'costo_unitario', l.costo_unitario,
               'valor_total', l.valor_total,
               'lote_id',     l.lote_id,
               'precio_venta', m.precio_venta,
               -- Comprar por encima del precio de venta es un error de
               -- digitación nueve de cada diez veces. Se marca para que
               -- salte a la vista antes de confirmar.
               'costo_sobre_precio', (m.precio_venta > 0 AND l.costo_unitario > m.precio_venta))
             ORDER BY l.created_at)
        FROM entrada_linea l JOIN medicamento m ON m.id = l.medicamento_id
       WHERE l.entrada_id = e.id), '[]'::jsonb))
  FROM entrada_inventario e
  LEFT JOIN proveedor pr ON pr.id = e.proveedor_id
  LEFT JOIN usuario u ON u.id = e.usuario_id
 WHERE e.id = p_entrada_id;
$$;

-- El borrador con el que estaba el usuario, para no perder lo tecleado si
-- se sale del flujo o si n8n se reinicia (§2.2.1).
CREATE OR REPLACE FUNCTION entrada_borrador_de(p_usuario_id uuid)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM entrada_inventario
   WHERE usuario_id = p_usuario_id AND estado = 'borrador'
   ORDER BY created_at DESC LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION entradas_recientes(p_limite int DEFAULT 8)
RETURNS TABLE (entrada_id uuid, fecha date, proveedor text, documento text,
               valor_total numeric, estado text, lineas bigint)
LANGUAGE sql STABLE AS $$
  SELECT e.id, e.fecha, COALESCE(pr.nombre, 'Sin proveedor'), e.documento_soporte,
         e.valor_total, e.estado,
         (SELECT count(*) FROM entrada_linea l WHERE l.entrada_id = e.id)
    FROM entrada_inventario e
    LEFT JOIN proveedor pr ON pr.id = e.proveedor_id
   WHERE e.estado <> 'descartada'
   ORDER BY e.fecha DESC, e.created_at DESC
   LIMIT GREATEST(p_limite, 1);
$$;

-- ---------------------------------------------------------------------
-- Escritura: proveedores
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_proveedor(
  p_actor_id uuid,
  p_nombre text,
  p_telefono text DEFAULT NULL,
  p_tipo_documento text DEFAULT NULL,
  p_numero_documento text DEFAULT NULL,
  p_contacto text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_direccion text DEFAULT NULL,
  p_notas text DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_nombre text := NULLIF(trim(COALESCE(p_nombre,'')), '');
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'proveedores.gestionar');

  IF v_nombre IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'El proveedor necesita un nombre.');
  END IF;

  INSERT INTO proveedor (nombre, telefono, tipo_documento, numero_documento,
                         contacto, email, direccion, notas)
  VALUES (v_nombre,
          NULLIF(trim(COALESCE(p_telefono,'')), ''),
          NULLIF(trim(COALESCE(p_tipo_documento,'')), ''),
          NULLIF(trim(COALESCE(p_numero_documento,'')), ''),
          NULLIF(trim(COALESCE(p_contacto,'')), ''),
          NULLIF(trim(COALESCE(p_email,'')), ''),
          NULLIF(trim(COALESCE(p_direccion,'')), ''),
          NULLIF(trim(COALESCE(p_notas,'')), ''))
  RETURNING id INTO v_id;

  PERFORM auditar('proveedor', v_id::text, 'crear', p_actor_id, p_canal, NULL,
                  proveedor_json(v_id));
  RETURN jsonb_build_object('ok', true, 'proveedor', proveedor_json(v_id));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'duplicado',
             'proveedor', (SELECT proveedor_json(id) FROM proveedor
                            WHERE normalizar(nombre) = normalizar(v_nombre)),
             'mensaje', 'Ya existe un proveedor con ese nombre o documento.');
END;
$$;

CREATE OR REPLACE FUNCTION editar_proveedor(
  p_actor_id uuid,
  p_proveedor_id uuid,
  p_campos jsonb,
  p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_antes jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'proveedores.gestionar');

  v_antes := proveedor_json(p_proveedor_id);
  IF v_antes IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese proveedor no existe.');
  END IF;

  UPDATE proveedor
     SET nombre           = COALESCE(NULLIF(trim(p_campos->>'nombre'), ''), nombre),
         telefono         = COALESCE(p_campos->>'telefono', telefono),
         tipo_documento   = COALESCE(p_campos->>'tipo_documento', tipo_documento),
         numero_documento = COALESCE(p_campos->>'numero_documento', numero_documento),
         contacto         = COALESCE(p_campos->>'contacto', contacto),
         email            = COALESCE(p_campos->>'email', email),
         direccion        = COALESCE(p_campos->>'direccion', direccion),
         notas            = COALESCE(p_campos->>'notas', notas),
         activo           = COALESCE((p_campos->>'activo')::boolean, activo)
   WHERE id = p_proveedor_id;

  PERFORM auditar('proveedor', p_proveedor_id::text, 'editar', p_actor_id, p_canal,
                  v_antes, proveedor_json(p_proveedor_id));
  RETURN jsonb_build_object('ok', true, 'proveedor', proveedor_json(p_proveedor_id));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'duplicado',
             'mensaje', 'Ya existe otro proveedor con ese nombre o documento.');
END;
$$;

-- ---------------------------------------------------------------------
-- Escritura: entradas
-- ---------------------------------------------------------------------

-- Abre el borrador. No toca inventario: hasta confirmar, esto es papel.
CREATE OR REPLACE FUNCTION crear_entrada(
  p_actor_id uuid,
  p_proveedor_id uuid DEFAULT NULL,
  p_sede_id uuid DEFAULT NULL,
  p_tipo text DEFAULT 'compra',
  p_documento_soporte text DEFAULT NULL,
  p_fecha date DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.entrada');

  IF COALESCE(p_tipo, 'compra') = 'compra' AND p_proveedor_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_proveedor',
             'mensaje', 'Una compra necesita proveedor.');
  END IF;

  INSERT INTO entrada_inventario (sede_id, proveedor_id, tipo, fecha,
                                  documento_soporte, usuario_id, canal)
  VALUES (COALESCE(p_sede_id, (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1)),
          p_proveedor_id, COALESCE(p_tipo, 'compra'), COALESCE(p_fecha, hoy_bogota()),
          NULLIF(trim(COALESCE(p_documento_soporte,'')), ''), p_actor_id, p_canal)
  RETURNING id INTO v_id;

  PERFORM auditar('entrada_inventario', v_id::text, 'crear_borrador', p_actor_id, p_canal,
                  NULL, entrada_json(v_id));
  RETURN jsonb_build_object('ok', true, 'entrada', entrada_json(v_id));
END;
$$;

CREATE OR REPLACE FUNCTION agregar_linea_entrada(
  p_actor_id uuid,
  p_entrada_id uuid,
  p_medicamento_id uuid,
  p_cantidad numeric,
  p_costo_unitario numeric DEFAULT 0,
  p_fecha_vencimiento date DEFAULT NULL,
  p_numero_lote text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text; v_id uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.entrada');

  SELECT estado INTO v_estado FROM entrada_inventario WHERE id = p_entrada_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa entrada ya no existe.');
  END IF;
  IF v_estado <> 'borrador' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'no_borrador',
             'mensaje', 'Esa entrada ya está confirmada.');
  END IF;
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'La cantidad debe ser mayor que cero.');
  END IF;
  IF p_fecha_vencimiento IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_vencimiento',
             'mensaje', 'Falta la fecha de vencimiento.');
  END IF;
  IF p_fecha_vencimiento < hoy_bogota() THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'vencido',
             'mensaje', 'Ese lote ya está vencido: no se puede ingresar.');
  END IF;

  INSERT INTO entrada_linea (entrada_id, medicamento_id, numero_lote,
                             fecha_vencimiento, cantidad, costo_unitario)
  VALUES (p_entrada_id, p_medicamento_id,
          NULLIF(trim(COALESCE(p_numero_lote,'')), ''),
          p_fecha_vencimiento, p_cantidad, COALESCE(p_costo_unitario, 0))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'linea_id', v_id,
                            'entrada', entrada_json(p_entrada_id));
END;
$$;

CREATE OR REPLACE FUNCTION quitar_linea_entrada(p_actor_id uuid, p_linea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_entrada uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.entrada');

  SELECT entrada_id INTO v_entrada FROM entrada_linea WHERE id = p_linea_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa línea ya no está.');
  END IF;

  BEGIN
    DELETE FROM entrada_linea WHERE id = p_linea_id;
  EXCEPTION WHEN feature_not_supported THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'no_borrador', 'mensaje', SQLERRM);
  END;

  RETURN jsonb_build_object('ok', true, 'entrada', entrada_json(v_entrada));
END;
$$;

-- La foto de la factura (§9). Se guarda el file_id de Telegram: la imagen
-- se queda en los servidores de Telegram y aquí queda la referencia con
-- la que se vuelve a mostrar desde el bot o desde el portal.
CREATE OR REPLACE FUNCTION adjuntar_soporte_entrada(
  p_actor_id uuid,
  p_entrada_id uuid,
  p_file_id text DEFAULT NULL,
  p_url text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.entrada');

  SELECT estado INTO v_estado FROM entrada_inventario WHERE id = p_entrada_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa entrada ya no existe.');
  END IF;

  -- Adjuntar el soporte a una entrada ya confirmada sí se permite: la
  -- factura llega a veces después de la mercancía, y no cambia nada de lo
  -- que ya pasó en el inventario.
  UPDATE entrada_inventario
     SET adjunto_file_id = COALESCE(p_file_id, adjunto_file_id),
         adjunto_url     = COALESCE(p_url, adjunto_url)
   WHERE id = p_entrada_id;

  PERFORM auditar('entrada_inventario', p_entrada_id::text, 'adjuntar_soporte',
                  p_actor_id, 'telegram', NULL,
                  jsonb_build_object('file_id', p_file_id, 'url', p_url));

  RETURN jsonb_build_object('ok', true, 'entrada', entrada_json(p_entrada_id));
END;
$$;

CREATE OR REPLACE FUNCTION anotar_entrada(
  p_actor_id uuid,
  p_entrada_id uuid,
  p_documento_soporte text DEFAULT NULL,
  p_observaciones text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.entrada');

  UPDATE entrada_inventario
     SET documento_soporte = COALESCE(NULLIF(trim(COALESCE(p_documento_soporte,'')), ''),
                                      documento_soporte),
         observaciones     = COALESCE(NULLIF(trim(COALESCE(p_observaciones,'')), ''),
                                      observaciones)
   WHERE id = p_entrada_id AND estado = 'borrador';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa entrada ya no está en borrador.');
  END IF;

  RETURN jsonb_build_object('ok', true, 'entrada', entrada_json(p_entrada_id));
END;
$$;

-- El momento en que la compra entra al inventario (§9). Todo o nada: si
-- una sola línea falla, no entra ninguna. Media factura ingresada es peor
-- que ninguna, porque nadie sabría cuál mitad.
CREATE OR REPLACE FUNCTION confirmar_entrada(
  p_actor_id uuid, p_entrada_id uuid, p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_entrada entrada_inventario;
  r         record;
  v_res     jsonb;
  v_n       int := 0;
  v_total   numeric := 0;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.entrada');

  SELECT * INTO v_entrada FROM entrada_inventario WHERE id = p_entrada_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa entrada ya no existe.');
  END IF;
  IF v_entrada.estado <> 'borrador' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'no_borrador',
             'mensaje', format('Esa entrada ya está %s.',
                               lower(nombre_estado_entrada(v_entrada.estado))));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM entrada_linea WHERE entrada_id = p_entrada_id) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'vacia',
             'mensaje', 'La entrada no tiene ningún medicamento.');
  END IF;

  -- Se marca confirmada ANTES de crear los lotes para que el trigger de
  -- append-only proteja las líneas desde este instante: a partir de aquí
  -- lo único que las toca es el UPDATE del lote_id de más abajo.
  UPDATE entrada_inventario
     SET estado = 'confirmada', confirmada_at = now(), confirmada_por = p_actor_id
   WHERE id = p_entrada_id;

  FOR r IN SELECT * FROM entrada_linea WHERE entrada_id = p_entrada_id ORDER BY created_at
  LOOP
    v_res := ingresar_lote(p_actor_id, r.medicamento_id, r.numero_lote,
                           r.fecha_vencimiento, r.cantidad, r.costo_unitario,
                           p_entrada_id, p_canal);

    IF NOT (v_res->>'ok')::boolean THEN
      -- La transacción entera se va atrás: ni lotes, ni movimientos, ni
      -- el cambio de estado. El borrador queda como estaba, corregible.
      RAISE EXCEPTION 'linea_invalida:%', COALESCE(v_res->>'mensaje', 'error al ingresar el lote')
        USING ERRCODE = '23514';
    END IF;

    UPDATE entrada_linea SET lote_id = (v_res->>'lote_id')::uuid WHERE id = r.id;

    v_n := v_n + 1;
    v_total := v_total + r.valor_total;
  END LOOP;

  UPDATE entrada_inventario SET valor_total = v_total WHERE id = p_entrada_id;

  PERFORM auditar('entrada_inventario', p_entrada_id::text, 'confirmar', p_actor_id, p_canal,
                  NULL, entrada_json(p_entrada_id));

  RETURN jsonb_build_object('ok', true, 'lineas', v_n, 'entrada', entrada_json(p_entrada_id));
EXCEPTION
  WHEN check_violation THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'linea_invalida',
             'mensaje', regexp_replace(SQLERRM, '^linea_invalida:', ''));
END;
$$;

-- Descartar un borrador. No se borra: quedó registrado que alguien empezó
-- a digitar una factura y la abandonó, y eso a veces es la explicación de
-- por qué la mercancía está en la bodega y no en el sistema.
CREATE OR REPLACE FUNCTION descartar_entrada(
  p_actor_id uuid, p_entrada_id uuid, p_motivo text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.entrada');

  SELECT estado INTO v_estado FROM entrada_inventario WHERE id = p_entrada_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa entrada ya no existe.');
  END IF;
  IF v_estado <> 'borrador' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'no_borrador',
             'mensaje', 'Sólo se descarta un borrador. Lo confirmado se corrige con un ajuste.');
  END IF;

  UPDATE entrada_inventario
     SET estado = 'descartada',
         observaciones = concat_ws(' · ', observaciones,
                                   NULLIF(trim(COALESCE(p_motivo,'')), ''))
   WHERE id = p_entrada_id;

  PERFORM auditar('entrada_inventario', p_entrada_id::text, 'descartar', p_actor_id,
                  'telegram', NULL, NULL, p_motivo);

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------------------------------------------------------------------
-- Reportes (§10.8 compras, §10.9 trazabilidad de lote)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_compras(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH rango AS (
    SELECT COALESCE(p_desde, date_trunc('month', hoy_bogota())::date) AS desde,
           COALESCE(p_hasta, hoy_bogota()) AS hasta
  ), compras AS (
    SELECT e.* FROM entrada_inventario e, rango r
     WHERE e.estado = 'confirmada' AND e.fecha BETWEEN r.desde AND r.hasta
  )
  SELECT jsonb_build_object(
    'desde',  (SELECT desde FROM rango),
    'hasta',  (SELECT hasta FROM rango),
    'total',  COALESCE((SELECT sum(valor_total) FROM compras), 0),
    'entradas', (SELECT count(*) FROM compras),
    'por_proveedor', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x->>'valor')::numeric DESC) FROM (
        SELECT jsonb_build_object(
                 'proveedor_id', c.proveedor_id,
                 'proveedor',    COALESCE(p.nombre, 'Sin proveedor'),
                 'entradas',     count(*),
                 'valor',        sum(c.valor_total)) AS x
          FROM compras c LEFT JOIN proveedor p ON p.id = c.proveedor_id
         GROUP BY c.proveedor_id, p.nombre) s), '[]'::jsonb),
    'por_medicamento', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x->>'valor')::numeric DESC) FROM (
        SELECT jsonb_build_object(
                 'medicamento_id', m.id,
                 'medicamento',    m.nombre_generico ||
                                   COALESCE(' (' || m.nombre_comercial || ')', ''),
                 'cantidad',       sum(l.cantidad),
                 'unidad',         m.unidad_base,
                 'valor',          sum(l.valor_total),
                 'costo_promedio', round(sum(l.valor_total) / NULLIF(sum(l.cantidad), 0), 2)) AS x
          FROM entrada_linea l
          JOIN compras c ON c.id = l.entrada_id
          JOIN medicamento m ON m.id = l.medicamento_id
         GROUP BY m.id, m.nombre_generico, m.nombre_comercial, m.unidad_base) s), '[]'::jsonb));
$$;

-- Qué pacientes recibieron un lote concreto. Es la consulta que hay que
-- poder responder en minutos el día que un laboratorio retira un producto
-- del mercado; por eso vive aquí desde ya y no en «reportes».
CREATE OR REPLACE FUNCTION trazabilidad_lote(p_lote_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'lote_id',      l.id,
    'lote',         l.numero_lote,
    'medicamento',  m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', ''),
    'vence',        l.fecha_vencimiento,
    'ingresado',    l.fecha_ingreso,
    'cantidad_inicial', l.cantidad_inicial,
    'cantidad_actual',  l.cantidad_actual,
    'costo_unitario', l.costo_unitario,
    'proveedor',    pr.nombre,
    'documento',    e.documento_soporte,
    'entrada_id',   e.id,
    'salidas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'fecha',     to_char(mi.created_at AT TIME ZONE 'America/Bogota', 'DD/MM/YYYY HH24:MI'),
               'cantidad',  mi.cantidad,
               'paciente',  pa.nombre,
               'paciente_id', pa.id,
               'dueno',     du.nombre_completo,
               'telefono',  du.telefono,
               'consulta_id', mi.consulta_id,
               'atendio',   us.nombre_completo)
             ORDER BY mi.created_at)
        FROM movimiento_inventario mi
        LEFT JOIN paciente pa ON pa.id = mi.paciente_id
        LEFT JOIN dueno du    ON du.id = pa.dueno_id
        LEFT JOIN usuario us  ON us.id = mi.usuario_id
       WHERE mi.lote_id = l.id AND mi.tipo = 'salida'), '[]'::jsonb))
  FROM lote l
  JOIN medicamento m ON m.id = l.medicamento_id
  LEFT JOIN entrada_inventario e ON e.id = l.entrada_id
  LEFT JOIN proveedor pr ON pr.id = e.proveedor_id
 WHERE l.id = p_lote_id;
$$;
