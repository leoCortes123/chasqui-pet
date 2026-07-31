-- =====================================================================
-- Chasqui Pet — 045_inventario.sql
-- Catálogo, lotes, movimientos, FEFO y alertas (§6).
--
-- Dos decisiones que gobiernan todo el módulo:
--
--   1. El stock es DERIVADO. La verdad son las filas de
--      movimiento_inventario; lote.cantidad_actual es un caché que
--      mantiene un trigger. Así se puede reconstruir la existencia de
--      cualquier lote en cualquier fecha y —lo que importa de verdad
--      cuando hay un retiro de producto— saber qué pacientes recibieron
--      un lote concreto.
--
--   2. movimiento_inventario es append-only de verdad: el rol de la
--      aplicación no tiene UPDATE ni DELETE sobre ella (090_grants.sql).
--      Un error se corrige con un movimiento inverso, que también queda.
--
-- El costo vive en el lote y el precio de venta en el medicamento: el
-- mismo producto entra a distinto costo en cada compra y se vende
-- siempre al mismo precio. El margen se calcula por movimiento contra el
-- costo del lote que efectivamente salió.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Catálogo
-- ---------------------------------------------------------------------
CREATE TABLE medicamento (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre_generico  text NOT NULL,
  nombre_comercial text,
  principio_activo text,
  presentacion     text,                       -- 'frasco 100 ml', 'caja x 10'
  concentracion    text,                       -- '50 mg/ml'
  unidad_base      text NOT NULL DEFAULT 'unidad'
                     CHECK (unidad_base IN ('ml','mg','tableta','unidad','dosis')),
  categoria        text,
  requiere_receta  boolean NOT NULL DEFAULT false,
  precio_venta     numeric(12,2) NOT NULL DEFAULT 0 CHECK (precio_venta >= 0),
  stock_minimo     numeric(12,3) NOT NULL DEFAULT 0 CHECK (stock_minimo >= 0),
  activo           boolean NOT NULL DEFAULT true,
  notas            text,
  -- Columna de búsqueda: el veterinario escribe «amoxi» con el animal en
  -- la mesa y no siempre bien. Se normaliza al guardar y se indexa con
  -- trigramas para que la búsqueda tolere errores de tipeo (§6.3).
  busqueda         text GENERATED ALWAYS AS (
                     normalizar(coalesce(nombre_generico,'') || ' ' ||
                                coalesce(nombre_comercial,'') || ' ' ||
                                coalesce(principio_activo,''))
                   ) STORED,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER medicamento_touch BEFORE UPDATE ON medicamento
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_medicamento_busqueda ON medicamento USING gin (busqueda gin_trgm_ops);
CREATE INDEX idx_medicamento_activo ON medicamento (activo) WHERE activo;
CREATE UNIQUE INDEX idx_medicamento_nombre
  ON medicamento (normalizar(nombre_generico), coalesce(normalizar(nombre_comercial), ''));

-- ---------------------------------------------------------------------
-- Lote: la existencia física, con vencimiento y costo de compra
-- ---------------------------------------------------------------------
CREATE TABLE lote (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  medicamento_id   uuid NOT NULL REFERENCES medicamento(id),
  numero_lote      text NOT NULL,
  fecha_vencimiento date NOT NULL,
  cantidad_inicial numeric(12,3) NOT NULL CHECK (cantidad_inicial > 0),
  cantidad_actual  numeric(12,3) NOT NULL DEFAULT 0 CHECK (cantidad_actual >= 0),
  costo_unitario   numeric(12,2) NOT NULL DEFAULT 0 CHECK (costo_unitario >= 0),
  entrada_id       uuid,          -- FK añadida en 070_compras.sql (paso 6)
  fecha_ingreso    date NOT NULL DEFAULT hoy_bogota(),
  bloqueado        boolean NOT NULL DEFAULT false,
  motivo_bloqueo   text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (medicamento_id, numero_lote, fecha_vencimiento)
);

CREATE TRIGGER lote_touch BEFORE UPDATE ON lote
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- El índice de despacho: FEFO por medicamento sobre lo que se puede usar.
CREATE INDEX idx_lote_fefo ON lote (medicamento_id, fecha_vencimiento)
  WHERE NOT bloqueado AND cantidad_actual > 0;
CREATE INDEX idx_lote_vencimiento ON lote (fecha_vencimiento)
  WHERE cantidad_actual > 0;

-- ---------------------------------------------------------------------
-- Movimiento de inventario — append-only (§6.1)
-- ---------------------------------------------------------------------
CREATE TABLE movimiento_inventario (
  id             bigserial PRIMARY KEY,
  lote_id        uuid NOT NULL REFERENCES lote(id),
  medicamento_id uuid NOT NULL REFERENCES medicamento(id),  -- denormalizado: los
                                                            -- reportes de consumo
                                                            -- no deben unir siempre
  tipo           text NOT NULL CHECK (tipo IN ('entrada','salida','ajuste_positivo',
                                               'ajuste_negativo','baja_vencimiento',
                                               'baja_dano','devolucion')),
  cantidad       numeric(12,3) NOT NULL CHECK (cantidad > 0),  -- siempre positiva;
                                                               -- el signo lo da el tipo
  motivo         text,
  turno_id       uuid REFERENCES turno(id),   -- la visita en curso; hasta el paso 4
                                              -- es lo único que ata la salida a un
                                              -- paciente concreto
  consulta_id    uuid,                        -- FK añadida en 050_pacientes.sql
  paciente_id    uuid,                        -- FK añadida en 050_pacientes.sql
  cuenta_linea_id uuid,                       -- FK añadida en 060_cobro.sql
  usuario_id     uuid REFERENCES usuario(id),
  canal          text NOT NULL DEFAULT 'telegram'
                   CHECK (canal IN ('telegram','web','job','sistema')),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_movimiento_lote ON movimiento_inventario (lote_id, created_at DESC);
CREATE INDEX idx_movimiento_medicamento ON movimiento_inventario (medicamento_id, created_at DESC);
CREATE INDEX idx_movimiento_fecha ON movimiento_inventario (created_at DESC);
CREATE INDEX idx_movimiento_paciente ON movimiento_inventario (paciente_id, created_at DESC)
  WHERE paciente_id IS NOT NULL;
CREATE INDEX idx_movimiento_usuario ON movimiento_inventario (usuario_id, created_at DESC);

-- Qué suma y qué resta. Una sola definición: si esto se dispersa por el
-- código, el stock derivado deja de cuadrar con el caché.
CREATE OR REPLACE FUNCTION signo_movimiento(p_tipo text) RETURNS int
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE p_tipo
           WHEN 'entrada'          THEN  1
           WHEN 'ajuste_positivo'  THEN  1
           WHEN 'devolucion'       THEN  1
           ELSE -1
         END;
$$;

-- Cantidades sin relleno: «2», «0.5»; nunca «2.000» ni «2.».
-- (FM suprime los ceros de la derecha pero deja el punto colgando.)
CREATE OR REPLACE FUNCTION fmt_cant(v numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT rtrim(trim(to_char(COALESCE(v, 0), 'FM999999990.999')), '.');
$$;

CREATE OR REPLACE FUNCTION nombre_tipo_movimiento(p_tipo text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE p_tipo
           WHEN 'entrada'          THEN 'Entrada'
           WHEN 'salida'           THEN 'Salida'
           WHEN 'ajuste_positivo'  THEN 'Ajuste positivo'
           WHEN 'ajuste_negativo'  THEN 'Ajuste negativo'
           WHEN 'baja_vencimiento' THEN 'Baja por vencimiento'
           WHEN 'baja_dano'        THEN 'Baja por daño'
           WHEN 'devolucion'       THEN 'Devolución'
           ELSE p_tipo
         END;
$$;

-- Validación previa: bloquea la fila del lote (FOR UPDATE) para que dos
-- salidas simultáneas del mismo lote no lean la misma existencia, y
-- devuelve un mensaje entendible en vez del error del CHECK.
CREATE OR REPLACE FUNCTION movimiento_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v lote;
BEGIN
  SELECT * INTO v FROM lote WHERE id = NEW.lote_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Lote inexistente';
  END IF;

  NEW.medicamento_id := v.medicamento_id;

  -- Un lote bloqueado (vencido, o retenido a mano) sólo admite la baja
  -- que lo saca del inventario.
  IF v.bloqueado AND NEW.tipo <> 'baja_vencimiento' THEN
    RAISE EXCEPTION 'El lote % está bloqueado: sólo admite baja por vencimiento', v.numero_lote
      USING ERRCODE = '23514';
  END IF;

  IF signo_movimiento(NEW.tipo) < 0 AND v.cantidad_actual < NEW.cantidad THEN
    RAISE EXCEPTION 'Existencia insuficiente en el lote %: hay % y se piden %',
                    v.numero_lote, v.cantidad_actual, NEW.cantidad
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER movimiento_validar BEFORE INSERT ON movimiento_inventario
  FOR EACH ROW EXECUTE FUNCTION movimiento_validar();

-- Mantiene el caché. La fila del lote ya está bloqueada por el trigger
-- anterior, así que este UPDATE no compite con nadie.
CREATE OR REPLACE FUNCTION movimiento_aplicar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE lote
     SET cantidad_actual = cantidad_actual + signo_movimiento(NEW.tipo) * NEW.cantidad
   WHERE id = NEW.lote_id;
  RETURN NULL;
END;
$$;

CREATE TRIGGER movimiento_aplicar AFTER INSERT ON movimiento_inventario
  FOR EACH ROW EXECUTE FUNCTION movimiento_aplicar();

-- Nadie edita ni borra un movimiento, tampoco el dueño de la tabla por
-- descuido: el REVOKE de 090_grants.sql cubre a la aplicación, esto cubre
-- al resto.
CREATE OR REPLACE FUNCTION movimiento_inmutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'movimiento_inventario es de sólo agregar: corrija con un movimiento inverso'
    USING ERRCODE = '0A000';
END;
$$;

CREATE TRIGGER movimiento_inmutable BEFORE UPDATE OR DELETE ON movimiento_inventario
  FOR EACH ROW EXECUTE FUNCTION movimiento_inmutable();

-- ---------------------------------------------------------------------
-- Vistas de existencia
-- ---------------------------------------------------------------------

-- Lotes que se pueden despachar hoy, en orden FEFO.
CREATE OR REPLACE VIEW v_lote_disponible AS
  SELECT l.id AS lote_id, l.medicamento_id, l.numero_lote, l.fecha_vencimiento,
         l.cantidad_actual, l.costo_unitario,
         (l.fecha_vencimiento - hoy_bogota()) AS dias_para_vencer,
         m.nombre_generico, m.nombre_comercial, m.unidad_base, m.precio_venta
    FROM lote l
    JOIN medicamento m ON m.id = l.medicamento_id
   WHERE NOT l.bloqueado
     AND l.cantidad_actual > 0
     AND l.fecha_vencimiento >= hoy_bogota()
   ORDER BY l.medicamento_id, l.fecha_vencimiento, l.created_at;

-- Existencia por medicamento. `disponible` excluye lo bloqueado y lo
-- vencido: es lo que de verdad se puede despachar.
CREATE OR REPLACE VIEW v_stock_medicamento AS
  SELECT m.id AS medicamento_id,
         m.nombre_generico, m.nombre_comercial, m.presentacion, m.concentracion,
         m.unidad_base, m.precio_venta, m.stock_minimo, m.requiere_receta, m.activo,
         COALESCE(d.disponible, 0)      AS disponible,
         COALESCE(t.total_fisico, 0)    AS total_fisico,
         COALESCE(d.lotes, 0)           AS lotes_disponibles,
         d.proximo_vencimiento,
         (COALESCE(d.disponible, 0) < m.stock_minimo) AS bajo_minimo
    FROM medicamento m
    LEFT JOIN LATERAL (
      SELECT sum(cantidad_actual) AS disponible,
             count(*)             AS lotes,
             min(fecha_vencimiento) AS proximo_vencimiento
        FROM lote
       WHERE medicamento_id = m.id AND NOT bloqueado
         AND cantidad_actual > 0 AND fecha_vencimiento >= hoy_bogota()
    ) d ON true
    LEFT JOIN LATERAL (
      SELECT sum(cantidad_actual) AS total_fisico
        FROM lote WHERE medicamento_id = m.id AND cantidad_actual > 0
    ) t ON true;

-- ---------------------------------------------------------------------
-- Consultas del flujo de chat (§6.3)
-- ---------------------------------------------------------------------

-- Búsqueda tolerante a errores de tipeo. Combina prefijo (rápido y exacto
-- cuando el usuario escribe bien) con similitud de trigramas (rescata
-- «amoxicilna»). Devuelve el top N para pintarlo como botones.
CREATE OR REPLACE FUNCTION buscar_medicamento(p_texto text, p_limite int DEFAULT 5)
RETURNS TABLE (
  medicamento_id uuid, nombre text, presentacion text, unidad_base text,
  precio_venta numeric, disponible numeric, bajo_minimo boolean, puntaje real
)
LANGUAGE sql STABLE AS $$
  WITH q AS (SELECT normalizar(COALESCE(p_texto, '')) AS t)
  SELECT s.medicamento_id,
         s.nombre_generico ||
           COALESCE(' (' || s.nombre_comercial || ')', '') AS nombre,
         s.presentacion, s.unidad_base, s.precio_venta,
         s.disponible, s.bajo_minimo,
         GREATEST(similarity(m.busqueda, q.t),
                  CASE WHEN m.busqueda LIKE q.t || '%' THEN 0.95
                       WHEN position(q.t in m.busqueda) > 0 THEN 0.85
                       ELSE 0 END)::real AS puntaje
    FROM v_stock_medicamento s
    JOIN medicamento m ON m.id = s.medicamento_id
   CROSS JOIN q
   WHERE s.activo
     AND q.t <> ''
     AND (m.busqueda % q.t OR position(q.t in m.busqueda) > 0)
   ORDER BY puntaje DESC, s.disponible DESC, s.nombre_generico
   LIMIT GREATEST(p_limite, 1);
$$;

-- Lotes de un medicamento en orden FEFO. El primero es el sugerido.
CREATE OR REPLACE FUNCTION lotes_fefo(p_medicamento_id uuid, p_limite int DEFAULT 5)
RETURNS TABLE (
  lote_id uuid, numero_lote text, fecha_vencimiento date,
  dias_para_vencer int, cantidad_actual numeric, costo_unitario numeric, es_sugerido boolean
)
LANGUAGE sql STABLE AS $$
  SELECT lote_id, numero_lote, fecha_vencimiento, dias_para_vencer::int,
         cantidad_actual, costo_unitario,
         row_number() OVER (ORDER BY fecha_vencimiento, lote_id) = 1
    FROM v_lote_disponible
   WHERE medicamento_id = p_medicamento_id
   ORDER BY fecha_vencimiento, lote_id
   LIMIT GREATEST(p_limite, 1);
$$;

CREATE OR REPLACE FUNCTION lote_fefo(p_medicamento_id uuid)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT lote_id FROM lotes_fefo(p_medicamento_id, 1);
$$;

-- Lo que ese veterinario despacha habitualmente: botones de primer nivel
-- para que la ruta feliz no empiece siempre por escribir.
CREATE OR REPLACE FUNCTION medicamentos_frecuentes(p_usuario_id uuid, p_limite int DEFAULT 4)
RETURNS TABLE (medicamento_id uuid, nombre text, disponible numeric)
LANGUAGE sql STABLE AS $$
  SELECT s.medicamento_id,
         s.nombre_generico || COALESCE(' (' || s.nombre_comercial || ')', ''),
         s.disponible
    FROM movimiento_inventario mi
    JOIN v_stock_medicamento s ON s.medicamento_id = mi.medicamento_id
   WHERE mi.tipo = 'salida'
     AND mi.usuario_id = p_usuario_id
     AND mi.created_at > now() - interval '30 days'
     AND s.activo AND s.disponible > 0
   GROUP BY s.medicamento_id, s.nombre_generico, s.nombre_comercial, s.disponible
   ORDER BY count(*) DESC, max(mi.created_at) DESC
   LIMIT GREATEST(p_limite, 1);
$$;

CREATE OR REPLACE FUNCTION medicamento_json(p_medicamento_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'medicamento_id',  s.medicamento_id,
    'nombre',          s.nombre_generico || COALESCE(' (' || s.nombre_comercial || ')', ''),
    'nombre_generico', s.nombre_generico,
    'presentacion',    s.presentacion,
    'concentracion',   s.concentracion,
    'unidad',          s.unidad_base,
    'precio_venta',    s.precio_venta,
    'requiere_receta', s.requiere_receta,
    'stock_minimo',    s.stock_minimo,
    'disponible',      s.disponible,
    'bajo_minimo',     s.bajo_minimo,
    'proximo_vencimiento', s.proximo_vencimiento)
  FROM v_stock_medicamento s
 WHERE s.medicamento_id = p_medicamento_id;
$$;

CREATE OR REPLACE FUNCTION movimiento_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'movimiento_id', mi.id,
    'tipo',          mi.tipo,
    'tipo_nombre',   nombre_tipo_movimiento(mi.tipo),
    'cantidad',      mi.cantidad,
    'unidad',        m.unidad_base,
    'medicamento',   m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', ''),
    'medicamento_id', m.id,
    'lote',          l.numero_lote,
    'lote_id',       l.id,
    'vence',         l.fecha_vencimiento,
    'restante',      l.cantidad_actual,
    'precio_venta',  m.precio_venta,
    'valor',         round(m.precio_venta * mi.cantidad, 2),
    'costo',         round(l.costo_unitario * mi.cantidad, 2),
    'motivo',        mi.motivo,
    'turno_id',      mi.turno_id,
    'paciente_id',   mi.paciente_id,
    'consulta_id',   mi.consulta_id,
    'hora',          to_char(mi.created_at AT TIME ZONE 'America/Bogota', 'HH24:MI'))
  FROM movimiento_inventario mi
  JOIN lote l ON l.id = mi.lote_id
  JOIN medicamento m ON m.id = mi.medicamento_id
 WHERE mi.id = p_id;
$$;

-- ---------------------------------------------------------------------
-- Escritura: catálogo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_medicamento(
  p_actor_id uuid,
  p_nombre_generico text,
  p_precio_venta numeric,
  p_unidad_base text DEFAULT 'unidad',
  p_nombre_comercial text DEFAULT NULL,
  p_principio_activo text DEFAULT NULL,
  p_presentacion text DEFAULT NULL,
  p_concentracion text DEFAULT NULL,
  p_categoria text DEFAULT NULL,
  p_requiere_receta boolean DEFAULT false,
  p_stock_minimo numeric DEFAULT 0,
  p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.catalogo');

  INSERT INTO medicamento (nombre_generico, nombre_comercial, principio_activo,
                           presentacion, concentracion, unidad_base, categoria,
                           requiere_receta, precio_venta, stock_minimo)
  VALUES (trim(p_nombre_generico), NULLIF(trim(COALESCE(p_nombre_comercial,'')), ''),
          p_principio_activo, p_presentacion, p_concentracion,
          COALESCE(p_unidad_base, 'unidad'), p_categoria,
          COALESCE(p_requiere_receta, false), COALESCE(p_precio_venta, 0),
          COALESCE(p_stock_minimo, 0))
  RETURNING id INTO v_id;

  PERFORM auditar('medicamento', v_id::text, 'crear', p_actor_id, p_canal, NULL,
                  medicamento_json(v_id));
  RETURN jsonb_build_object('ok', true, 'medicamento', medicamento_json(v_id));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'duplicado',
             'mensaje', 'Ya existe un medicamento con ese nombre.');
END;
$$;

CREATE OR REPLACE FUNCTION cambiar_precio_medicamento(
  p_actor_id uuid, p_medicamento_id uuid, p_precio numeric, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_antes numeric;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.catalogo');

  IF p_precio IS NULL OR p_precio < 0 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'El precio no puede ser negativo.');
  END IF;

  SELECT precio_venta INTO v_antes FROM medicamento WHERE id = p_medicamento_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese medicamento no existe.');
  END IF;

  UPDATE medicamento SET precio_venta = p_precio WHERE id = p_medicamento_id;

  -- El precio viejo se conserva en la auditoría: los movimientos ya
  -- registrados guardan su valor en la cuenta, no se recalculan.
  PERFORM auditar('medicamento', p_medicamento_id::text, 'cambiar_precio', p_actor_id, p_canal,
                  jsonb_build_object('precio_venta', v_antes),
                  jsonb_build_object('precio_venta', p_precio));

  RETURN jsonb_build_object('ok', true, 'medicamento', medicamento_json(p_medicamento_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Escritura: movimientos
-- ---------------------------------------------------------------------

-- Núcleo común. NO comprueba permisos: cada operación de negocio exige el
-- suyo antes de llamar aquí. Se mantiene privado por convención.
CREATE OR REPLACE FUNCTION registrar_movimiento(
  p_actor_id uuid,
  p_lote_id uuid,
  p_tipo text,
  p_cantidad numeric,
  p_motivo text DEFAULT NULL,
  p_turno_id uuid DEFAULT NULL,
  p_consulta_id uuid DEFAULT NULL,
  p_paciente_id uuid DEFAULT NULL,
  p_cuenta_linea_id uuid DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO movimiento_inventario (lote_id, medicamento_id, tipo, cantidad, motivo,
                                     turno_id, consulta_id, paciente_id, cuenta_linea_id,
                                     usuario_id, canal)
  VALUES (p_lote_id,
          (SELECT medicamento_id FROM lote WHERE id = p_lote_id),
          p_tipo, p_cantidad, NULLIF(trim(COALESCE(p_motivo,'')), ''),
          p_turno_id, p_consulta_id, p_paciente_id, p_cuenta_linea_id,
          p_actor_id, p_canal)
  RETURNING id INTO v_id;

  PERFORM auditar('movimiento_inventario', v_id::text, p_tipo, p_actor_id, p_canal, NULL,
                  movimiento_json(v_id), p_motivo);
  RETURN v_id;
END;
$$;

-- Salida por consumo (§6.3). Es la operación más frecuente del sistema.
--
-- FEFO obligatorio: si el lote elegido no es el de vencimiento más
-- próximo, hace falta justificación, y queda en `motivo`. No se prohíbe
-- —a veces el frasco abierto es otro— pero no pasa en silencio.
CREATE OR REPLACE FUNCTION salida_medicamento(
  p_actor_id uuid,
  p_lote_id uuid,
  p_cantidad numeric,
  p_motivo text DEFAULT NULL,
  p_turno_id uuid DEFAULT NULL,
  p_consulta_id uuid DEFAULT NULL,
  p_paciente_id uuid DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_lote lote;
  v_sugerido uuid;
  v_id bigint;
  v_turno turno;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.salida');

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'cantidad_invalida',
             'mensaje', 'La cantidad debe ser mayor que cero.');
  END IF;

  SELECT * INTO v_lote FROM lote WHERE id = p_lote_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese lote ya no existe.');
  END IF;

  IF v_lote.bloqueado THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'lote_bloqueado',
             'mensaje', format('El lote %s está bloqueado y no se puede despachar.', v_lote.numero_lote));
  END IF;

  IF v_lote.fecha_vencimiento < hoy_bogota() THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'lote_vencido',
             'mensaje', format('El lote %s está vencido. Dale de baja por vencimiento.', v_lote.numero_lote));
  END IF;

  IF v_lote.cantidad_actual < p_cantidad THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_existencia',
             'mensaje', format('Sólo quedan %s en el lote %s.',
                               fmt_cant(v_lote.cantidad_actual), v_lote.numero_lote));
  END IF;

  v_sugerido := lote_fefo(v_lote.medicamento_id);
  IF v_sugerido IS NOT NULL AND v_sugerido <> p_lote_id
     AND NULLIF(trim(COALESCE(p_motivo,'')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'fefo_sin_justificacion',
             'lote_sugerido', v_sugerido,
             'mensaje', 'Ese no es el lote que vence primero. Escribe el motivo para usar otro.');
  END IF;

  -- Contexto clínico: si el veterinario tiene un paciente en la mesa, la
  -- salida se ata a esa visita sin preguntar nada más.
  IF p_turno_id IS NULL THEN
    SELECT * INTO v_turno FROM turno
     WHERE veterinario_id = p_actor_id AND fecha = hoy_bogota()
       AND estado = 'en_atencion'
     ORDER BY en_atencion_at DESC LIMIT 1;
  ELSE
    SELECT * INTO v_turno FROM turno WHERE id = p_turno_id;
  END IF;

  v_id := registrar_movimiento(
            p_actor_id, p_lote_id, 'salida', p_cantidad, p_motivo,
            v_turno.id,
            COALESCE(p_consulta_id, v_turno.consulta_id),
            COALESCE(p_paciente_id, v_turno.paciente_id),
            NULL, p_canal);

  -- La línea en la cuenta del paciente al precio_venta (§6.3) la crea el
  -- módulo de cobro, que es el paso 5. Se encola ya para que cuando ese
  -- módulo exista no haya que tocar este flujo: hoy el worker la completa
  -- como pendiente explícita.
  PERFORM encolar_tarea('agregar_linea_cuenta',
            jsonb_build_object('movimiento_id', v_id,
                               'turno_id', v_turno.id,
                               'origen', 'salida_medicamento'), 5,
            'linea_mov_' || v_id::text);

  RETURN jsonb_build_object('ok', true, 'movimiento', movimiento_json(v_id));
END;
$$;

-- Ajustes y bajas (§6.1). El motivo es obligatorio: un ajuste sin
-- explicación es indistinguible de un faltante.
CREATE OR REPLACE FUNCTION ajustar_lote(
  p_actor_id uuid,
  p_lote_id uuid,
  p_tipo text,
  p_cantidad numeric,
  p_motivo text,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id bigint; v_lote lote;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.ajuste');

  IF p_tipo NOT IN ('ajuste_positivo','ajuste_negativo','baja_vencimiento','baja_dano','devolucion') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Tipo de ajuste no válido.');
  END IF;
  IF NULLIF(trim(COALESCE(p_motivo,'')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_motivo',
             'mensaje', 'Todo ajuste necesita un motivo.');
  END IF;
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'La cantidad debe ser mayor que cero.');
  END IF;

  SELECT * INTO v_lote FROM lote WHERE id = p_lote_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese lote ya no existe.');
  END IF;

  BEGIN
    v_id := registrar_movimiento(p_actor_id, p_lote_id, p_tipo, p_cantidad,
                                 p_motivo, NULL, NULL, NULL, NULL, p_canal);
  EXCEPTION WHEN check_violation THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', SQLERRM);
  END;

  RETURN jsonb_build_object('ok', true, 'movimiento', movimiento_json(v_id));
END;
$$;

-- Ingreso de mercancía. En el paso 6 la entrada por compra creará lotes a
-- través de esta misma función, pasando p_entrada_id.
CREATE OR REPLACE FUNCTION ingresar_lote(
  p_actor_id uuid,
  p_medicamento_id uuid,
  p_numero_lote text,
  p_fecha_vencimiento date,
  p_cantidad numeric,
  p_costo_unitario numeric DEFAULT 0,
  p_entrada_id uuid DEFAULT NULL,
  p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_lote_id uuid; v_id bigint; v_num text := NULLIF(trim(COALESCE(p_numero_lote,'')), '');
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.entrada');

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'La cantidad debe ser mayor que cero.');
  END IF;
  IF p_fecha_vencimiento IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Falta la fecha de vencimiento del lote.');
  END IF;
  IF p_fecha_vencimiento < hoy_bogota() THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'vencido',
             'mensaje', 'No se puede ingresar un lote ya vencido.');
  END IF;
  IF v_num IS NULL THEN
    -- Hay proveedores que despachan sin número de lote visible. Se genera
    -- uno trazable en vez de dejar el campo vacío.
    v_num := 'S/L-' || to_char(hoy_bogota(), 'YYYYMMDD') || '-' ||
             lpad((floor(random() * 1000))::text, 3, '0');
  END IF;

  -- Reingreso del mismo lote (misma referencia y vencimiento): suma
  -- existencia en vez de partir la trazabilidad en dos filas.
  SELECT id INTO v_lote_id FROM lote
   WHERE medicamento_id = p_medicamento_id AND numero_lote = v_num
     AND fecha_vencimiento = p_fecha_vencimiento;

  IF v_lote_id IS NULL THEN
    INSERT INTO lote (medicamento_id, numero_lote, fecha_vencimiento,
                      cantidad_inicial, cantidad_actual, costo_unitario, entrada_id)
    VALUES (p_medicamento_id, v_num, p_fecha_vencimiento, p_cantidad, 0,
            COALESCE(p_costo_unitario, 0), p_entrada_id)
    RETURNING id INTO v_lote_id;
  ELSE
    UPDATE lote
       SET cantidad_inicial = cantidad_inicial + p_cantidad,
           costo_unitario = COALESCE(NULLIF(p_costo_unitario, 0), costo_unitario),
           bloqueado = false, motivo_bloqueo = NULL
     WHERE id = v_lote_id;
  END IF;

  v_id := registrar_movimiento(p_actor_id, v_lote_id, 'entrada', p_cantidad,
                               'Ingreso de mercancía', NULL, NULL, NULL, NULL, p_canal);

  RETURN jsonb_build_object('ok', true, 'lote_id', v_lote_id,
                            'movimiento', movimiento_json(v_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Job diario: bloqueo de vencidos y alertas (§6.2)
-- ---------------------------------------------------------------------

-- Un lote vencido deja de ser despachable el mismo día. No se le da de
-- baja solo: eso es una decisión con responsable, y queda pendiente en la
-- alerta hasta que alguien la tome.
CREATE OR REPLACE FUNCTION bloquear_lotes_vencidos()
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN
    UPDATE lote
       SET bloqueado = true,
           motivo_bloqueo = format('Vencido el %s', to_char(fecha_vencimiento, 'DD/MM/YYYY'))
     WHERE NOT bloqueado AND fecha_vencimiento < hoy_bogota()
    RETURNING id, numero_lote, medicamento_id, fecha_vencimiento, cantidad_actual
  LOOP
    v_n := v_n + 1;
    PERFORM auditar('lote', r.id::text, 'bloquear_vencido', NULL, 'job', NULL,
                    jsonb_build_object('numero_lote', r.numero_lote,
                                       'vencimiento', r.fecha_vencimiento,
                                       'existencia', r.cantidad_actual));
  END LOOP;

  RETURN v_n;
END;
$$;

-- Todo lo que el administrador tiene que saber cada mañana, en una sola
-- consulta: qué falta, qué está por vencerse y qué hay que dar de baja.
CREATE OR REPLACE FUNCTION alertas_inventario()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'fecha', hoy_bogota(),
    'dias_aviso',  config_int('alerta_vencimiento_dias', 30),
    'dias_critico', config_int('alerta_vencimiento_dias_critico', 7),
    'bajo_minimo', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'medicamento_id', s.medicamento_id,
               'nombre', s.nombre_generico || COALESCE(' (' || s.nombre_comercial || ')', ''),
               'disponible', s.disponible, 'minimo', s.stock_minimo, 'unidad', s.unidad_base)
             ORDER BY s.disponible, s.nombre_generico)
        FROM v_stock_medicamento s
       WHERE s.activo AND s.bajo_minimo), '[]'::jsonb),
    'por_vencer', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'lote_id', v.lote_id, 'lote', v.numero_lote,
               'nombre', v.nombre_generico || COALESCE(' (' || v.nombre_comercial || ')', ''),
               'vence', v.fecha_vencimiento, 'dias', v.dias_para_vencer,
               'cantidad', v.cantidad_actual, 'unidad', v.unidad_base,
               'critico', v.dias_para_vencer <= config_int('alerta_vencimiento_dias_critico', 7))
             ORDER BY v.fecha_vencimiento)
        FROM v_lote_disponible v
       WHERE v.dias_para_vencer <= config_int('alerta_vencimiento_dias', 30)), '[]'::jsonb),
    'vencidos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'lote_id', l.id, 'lote', l.numero_lote,
               'nombre', m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', ''),
               'vencio', l.fecha_vencimiento, 'cantidad', l.cantidad_actual,
               'unidad', m.unidad_base)
             ORDER BY l.fecha_vencimiento)
        FROM lote l JOIN medicamento m ON m.id = l.medicamento_id
       WHERE l.fecha_vencimiento < hoy_bogota() AND l.cantidad_actual > 0), '[]'::jsonb)
  );
$$;

-- Devuelve true si hay algo que reportar. Evita mandarle al admin un
-- «todo en orden» cada mañana, que es la forma más rápida de conseguir
-- que deje de leer las alertas.
CREATE OR REPLACE FUNCTION hay_alertas_inventario()
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT (a->'bajo_minimo') <> '[]'::jsonb
      OR (a->'por_vencer')  <> '[]'::jsonb
      OR (a->'vencidos')    <> '[]'::jsonb
    FROM alertas_inventario() a;
$$;
