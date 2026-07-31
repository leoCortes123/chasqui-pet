-- =====================================================================
-- Chasqui Pet — 060_cobro.sql
-- Tarifas, cuenta, líneas, descuentos, pagos, recibo y cierre de caja (§7).
--
-- Cuatro decisiones gobiernan el módulo:
--
--   1. Los totales de la cuenta son un CACHÉ. La verdad son las filas de
--      cuenta_linea, descuento y pago; cuenta.subtotal, .descuento, .total
--      y .pagado los mantiene un trigger, igual que lote.cantidad_actual
--      en inventario. Así el detalle y el total nunca pueden discrepar.
--
--   2. El dinero es de sólo agregar. pago y descuento no admiten UPDATE
--      ni DELETE —ni por la aplicación (090_grants.sql) ni por su dueño
--      (trigger)—: un pago mal registrado se corrige con una fila
--      'reverso', que también queda. Es la misma regla de
--      movimiento_inventario, y por la misma razón: aquí hay caja.
--
--   3. El descuento nunca borra ni edita líneas (§7.3). El subtotal se
--      conserva intacto y la rebaja se registra aparte, con motivo
--      obligatorio y con quién la autorizó. Si no, un descuento y un
--      error de digitación son indistinguibles a fin de mes.
--
--   4. El recibo es interno y lo dice (§7.4). `recibo_numero` es un
--      consecutivo propio, NO un documento tributario. Cuando llegue la
--      facturación electrónica DIAN, será una tabla
--      documento_electronico referenciando cuenta: nada de lo que hay
--      aquí tiene que cambiar.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Tarifa: cuánto vale cada servicio
-- ---------------------------------------------------------------------
CREATE TABLE tarifa (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo_servicio_id    uuid REFERENCES tipo_servicio(id),  -- nullable: hay
                                                          -- cobros que no
                                                          -- son un tipo de
                                                          -- turno (certificado)
  codigo              text UNIQUE,
  nombre              text NOT NULL,
  valor_sugerido      numeric(12,2) NOT NULL DEFAULT 0 CHECK (valor_sugerido >= 0),
  -- Lo que se cobra por peso, por dosis o por acuerdo: el bot pregunta el
  -- valor en vez de darlo por hecho.
  permite_valor_libre boolean NOT NULL DEFAULT false,
  activa              boolean NOT NULL DEFAULT true,
  orden               int NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER tarifa_touch BEFORE UPDATE ON tarifa
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_tarifa_activa ON tarifa (orden, nombre) WHERE activa;

-- ---------------------------------------------------------------------
-- Cierre de caja: la jornada de dinero de una sede
--
-- Se declara antes que `pago` porque cada pago nace atado a la caja
-- abierta: asignarlo al insertar —y no al cerrar— es lo que permite que
-- pago sea de sólo agregar y que el cuadre siga siendo exacto.
-- ---------------------------------------------------------------------
CREATE TABLE cierre_caja (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sede_id                  uuid NOT NULL REFERENCES sede(id),
  fecha                    date NOT NULL DEFAULT hoy_bogota(),
  usuario_id               uuid REFERENCES usuario(id),   -- quien la abrió
  cerrada_por              uuid REFERENCES usuario(id),
  apertura_at              timestamptz NOT NULL DEFAULT now(),
  cierre_at                timestamptz,
  base_inicial             numeric(12,2) NOT NULL DEFAULT 0 CHECK (base_inicial >= 0),
  total_efectivo_esperado  numeric(12,2) NOT NULL DEFAULT 0,
  total_efectivo_contado   numeric(12,2),
  total_transferencia      numeric(12,2) NOT NULL DEFAULT 0,
  total_datafono           numeric(12,2) NOT NULL DEFAULT 0,
  total_descuento          numeric(12,2) NOT NULL DEFAULT 0,
  cuentas_cerradas         int NOT NULL DEFAULT 0,
  diferencia               numeric(12,2),
  notas                    text,
  estado                   text NOT NULL DEFAULT 'abierto'
                             CHECK (estado IN ('abierto','cerrado')),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER cierre_caja_touch BEFORE UPDATE ON cierre_caja
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Una sola caja abierta por sede: si hubiera dos, el efectivo contado no
-- sabría a cuál pertenece.
CREATE UNIQUE INDEX idx_caja_abierta ON cierre_caja (sede_id)
  WHERE estado = 'abierto';
CREATE INDEX idx_caja_fecha ON cierre_caja (sede_id, fecha DESC);

-- ---------------------------------------------------------------------
-- Cuenta: lo que se le cobra a una atención
-- ---------------------------------------------------------------------
CREATE TABLE cuenta (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sede_id          uuid NOT NULL REFERENCES sede(id),
  fecha            date NOT NULL DEFAULT hoy_bogota(),
  turno_id         uuid REFERENCES turno(id),
  consulta_id      uuid REFERENCES consulta(id),
  paciente_id      uuid REFERENCES paciente(id),
  dueno_id         uuid REFERENCES dueno(id),

  estado           text NOT NULL DEFAULT 'abierta'
                     CHECK (estado IN ('abierta','cerrada','anulada')),

  -- Caché mantenido por trigger a partir de las filas de detalle.
  subtotal         numeric(12,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  descuento        numeric(12,2) NOT NULL DEFAULT 0 CHECK (descuento >= 0),
  total            numeric(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  pagado           numeric(12,2) NOT NULL DEFAULT 0,

  recibo_numero    int UNIQUE,          -- consecutivo interno, sólo al cerrar
  cierre_caja_id   uuid REFERENCES cierre_caja(id),
  abierta_por      uuid REFERENCES usuario(id),
  cerrada_por      uuid REFERENCES usuario(id),
  anulada_por      uuid REFERENCES usuario(id),
  motivo_anulacion text,
  canal_origen     text NOT NULL DEFAULT 'sistema'
                     CHECK (canal_origen IN ('telegram','web','sistema','job')),
  fecha_apertura   timestamptz NOT NULL DEFAULT now(),
  fecha_cierre     timestamptz,
  anulada_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER cuenta_touch BEFORE UPDATE ON cuenta
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Un turno tiene como mucho una cuenta: es la que abre iniciar_atencion().
CREATE UNIQUE INDEX idx_cuenta_turno ON cuenta (turno_id)
  WHERE turno_id IS NOT NULL;
CREATE INDEX idx_cuenta_abierta ON cuenta (sede_id, fecha)
  WHERE estado = 'abierta';
CREATE INDEX idx_cuenta_paciente ON cuenta (paciente_id, fecha DESC);
CREATE INDEX idx_cuenta_caja ON cuenta (cierre_caja_id) WHERE cierre_caja_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- Línea de la cuenta
--
-- valor_total es GENERATED: no hay forma de guardar una línea cuyo total
-- no sea su cantidad por su valor unitario.
-- ---------------------------------------------------------------------
CREATE TABLE cuenta_linea (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cuenta_id      uuid NOT NULL REFERENCES cuenta(id),
  tipo           text NOT NULL CHECK (tipo IN ('servicio','medicamento')),
  referencia_id  uuid,          -- tarifa_id o medicamento_id, según el tipo
  -- El movimiento que despachó el medicamento. Es el enlace bueno entre
  -- inventario y caja: el movimiento nace antes que la línea (la crea el
  -- worker) y es inmutable, así que el puntero tiene que vivir de este
  -- lado. UNIQUE: es lo que hace idempotente a la tarea agregar_linea_cuenta.
  movimiento_id  bigint UNIQUE REFERENCES movimiento_inventario(id),
  descripcion    text NOT NULL,
  cantidad       numeric(12,3) NOT NULL DEFAULT 1 CHECK (cantidad > 0),
  valor_unitario numeric(12,2) NOT NULL CHECK (valor_unitario >= 0),
  valor_total    numeric(12,2) GENERATED ALWAYS AS
                   (round(cantidad * valor_unitario, 2)) STORED,
  usuario_id     uuid REFERENCES usuario(id),
  canal          text NOT NULL DEFAULT 'telegram'
                   CHECK (canal IN ('telegram','web','sistema','job')),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_cuenta_linea_cuenta ON cuenta_linea (cuenta_id, created_at);

-- ---------------------------------------------------------------------
-- Descuento y pago — de sólo agregar, con reverso (§7.3)
-- ---------------------------------------------------------------------
CREATE TABLE descuento (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cuenta_id      uuid NOT NULL REFERENCES cuenta(id),
  tipo           text NOT NULL DEFAULT 'descuento'
                   CHECK (tipo IN ('descuento','reverso')),
  valor          numeric(12,2) NOT NULL CHECK (valor > 0),  -- el signo lo da el tipo
  motivo         text NOT NULL CHECK (length(trim(motivo)) > 0),
  autorizado_por uuid REFERENCES usuario(id),
  revierte_id    uuid REFERENCES descuento(id),
  canal          text NOT NULL DEFAULT 'telegram'
                   CHECK (canal IN ('telegram','web','sistema','job')),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_descuento_cuenta ON descuento (cuenta_id, created_at);

CREATE TABLE pago (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cuenta_id      uuid NOT NULL REFERENCES cuenta(id),
  cierre_caja_id uuid REFERENCES cierre_caja(id),
  tipo           text NOT NULL DEFAULT 'pago' CHECK (tipo IN ('pago','reverso')),
  medio          text NOT NULL CHECK (medio IN ('efectivo','transferencia','datafono')),
  valor          numeric(12,2) NOT NULL CHECK (valor > 0),
  referencia     text,          -- aprobación del datáfono, número de la transferencia
  motivo         text,          -- obligatorio en los reversos
  revierte_id    uuid REFERENCES pago(id),
  usuario_id     uuid REFERENCES usuario(id),
  canal          text NOT NULL DEFAULT 'telegram'
                   CHECK (canal IN ('telegram','web','sistema','job')),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_pago_cuenta ON pago (cuenta_id, created_at);
CREATE INDEX idx_pago_caja ON pago (cierre_caja_id, medio);
CREATE INDEX idx_pago_fecha ON pago (created_at DESC);

-- ---------------------------------------------------------------------
-- Llaves que quedaron pendientes en las migraciones anteriores
--
-- movimiento_inventario.cuenta_linea_id se declaró en 045 apuntando aquí.
-- Queda NULL en la salida por chat —el movimiento existe antes que la
-- línea— y se poblará en la venta directa de mostrador (paso 6), donde el
-- orden se invierte. El enlace vigente hoy es cuenta_linea.movimiento_id.
-- ---------------------------------------------------------------------
ALTER TABLE turno
  ADD CONSTRAINT turno_cuenta_fk FOREIGN KEY (cuenta_id) REFERENCES cuenta(id);

ALTER TABLE movimiento_inventario
  ADD CONSTRAINT movimiento_cuenta_linea_fk
    FOREIGN KEY (cuenta_linea_id) REFERENCES cuenta_linea(id);

-- ---------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------

-- Qué suma y qué resta, en un solo sitio (igual que signo_movimiento).
CREATE OR REPLACE FUNCTION signo_dinero(p_tipo text) RETURNS int
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE p_tipo WHEN 'reverso' THEN -1 ELSE 1 END;
$$;

-- Pesos colombianos: separador de miles con PUNTO (§12). `pesos()` viene de
-- 040_bot_turnos.sql y usaba 'G', que es el separador del locale del
-- servidor: en el contenedor sale «$60,000», que en Colombia se lee como
-- sesenta con cero. Con dinero de por medio eso deja de ser cosmético, así
-- que el formato se fija aquí y no depende ya de ninguna variable de entorno.
CREATE OR REPLACE FUNCTION pesos(v numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT '$' || translate(to_char(round(COALESCE(v, 0)), 'FM999,999,999,999'), ',', '.');
$$;

CREATE OR REPLACE FUNCTION nombre_medio_pago(p_medio text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_medio
           WHEN 'efectivo'      THEN 'Efectivo'
           WHEN 'transferencia' THEN 'Transferencia'
           WHEN 'datafono'      THEN 'Datáfono'
           ELSE COALESCE(p_medio, '—')
         END;
$$;

CREATE OR REPLACE FUNCTION emoji_medio_pago(p_medio text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_medio
           WHEN 'efectivo'      THEN '💵'
           WHEN 'transferencia' THEN '📲'
           WHEN 'datafono'      THEN '💳'
           ELSE '💰'
         END;
$$;

-- Lee un monto escrito por una persona con prisa: «50000», «50.000»,
-- «$ 50.000», «50 mil» no. En pesos colombianos no hay centavos (§12), así
-- que se toman los dígitos y se ignora toda puntuación: quien escribe
-- «50.000» quiere cincuenta mil, no cincuenta.
CREATE OR REPLACE FUNCTION parse_pesos(p_texto text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(regexp_replace(COALESCE(p_texto, ''), '\D', '', 'g'), '')::numeric;
$$;

-- Consecutivo del recibo interno. Mismo patrón que la numeración de
-- turnos (§2.2.6): advisory lock sobre la sede, nunca MAX+1 a pelo. Dos
-- auxiliares cerrando cuentas al tiempo emitirían el mismo número.
CREATE OR REPLACE FUNCTION siguiente_numero_recibo(p_sede_id uuid)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_numero int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('recibo:' || p_sede_id::text));

  SELECT COALESCE(MAX(recibo_numero), 0) + 1 INTO v_numero
    FROM cuenta WHERE sede_id = p_sede_id;

  RETURN v_numero;
END;
$$;

-- ---------------------------------------------------------------------
-- Caché de totales
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cuenta_recalcular(p_cuenta_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_sub numeric; v_desc numeric; v_pag numeric;
BEGIN
  SELECT COALESCE(sum(valor_total), 0) INTO v_sub
    FROM cuenta_linea WHERE cuenta_id = p_cuenta_id;

  SELECT COALESCE(sum(signo_dinero(tipo) * valor), 0) INTO v_desc
    FROM descuento WHERE cuenta_id = p_cuenta_id;

  SELECT COALESCE(sum(signo_dinero(tipo) * valor), 0) INTO v_pag
    FROM pago WHERE cuenta_id = p_cuenta_id;

  -- El descuento no puede dejar la cuenta en negativo, y un subtotal que
  -- baja después de un descuento grande tampoco: se topa aquí, que es por
  -- donde pasan todos los caminos.
  v_desc := LEAST(GREATEST(v_desc, 0), v_sub);

  UPDATE cuenta
     SET subtotal = v_sub,
         descuento = v_desc,
         total = v_sub - v_desc,
         pagado = v_pag
   WHERE id = p_cuenta_id;
END;
$$;

CREATE OR REPLACE FUNCTION cuenta_recalcular_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM cuenta_recalcular(COALESCE(NEW.cuenta_id, OLD.cuenta_id));
  RETURN NULL;
END;
$$;

CREATE TRIGGER cuenta_linea_recalcular AFTER INSERT OR DELETE ON cuenta_linea
  FOR EACH ROW EXECUTE FUNCTION cuenta_recalcular_trigger();
CREATE TRIGGER descuento_recalcular AFTER INSERT ON descuento
  FOR EACH ROW EXECUTE FUNCTION cuenta_recalcular_trigger();
CREATE TRIGGER pago_recalcular AFTER INSERT ON pago
  FOR EACH ROW EXECUTE FUNCTION cuenta_recalcular_trigger();

-- Sobre una cuenta que ya no está abierta no se agrega nada. La excepción
-- es el reverso, que es justamente lo que permite deshacer un pago de una
-- cuenta ya cerrada al anularla.
CREATE OR REPLACE FUNCTION cuenta_exigir_abierta() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  IF TG_TABLE_NAME IN ('pago','descuento') AND NEW.tipo = 'reverso' THEN
    RETURN NEW;
  END IF;

  SELECT estado INTO v_estado FROM cuenta WHERE id = NEW.cuenta_id;
  IF v_estado <> 'abierta' THEN
    RAISE EXCEPTION 'La cuenta está %: no admite movimientos nuevos', v_estado
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER cuenta_linea_abierta BEFORE INSERT ON cuenta_linea
  FOR EACH ROW EXECUTE FUNCTION cuenta_exigir_abierta();
CREATE TRIGGER descuento_abierta BEFORE INSERT ON descuento
  FOR EACH ROW EXECUTE FUNCTION cuenta_exigir_abierta();
CREATE TRIGGER pago_abierta BEFORE INSERT ON pago
  FOR EACH ROW EXECUTE FUNCTION cuenta_exigir_abierta();

-- Dinero recibido y rebajas otorgadas no se editan ni se borran: se
-- revierten. El REVOKE de 090_grants.sql cubre a la aplicación; esto
-- cubre a cualquiera con psql y prisa.
CREATE OR REPLACE FUNCTION dinero_inmutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% es de sólo agregar: corrija con un reverso', TG_TABLE_NAME
    USING ERRCODE = '0A000';
END;
$$;

CREATE TRIGGER pago_inmutable BEFORE UPDATE OR DELETE ON pago
  FOR EACH ROW EXECUTE FUNCTION dinero_inmutable();
CREATE TRIGGER descuento_inmutable BEFORE UPDATE OR DELETE ON descuento
  FOR EACH ROW EXECUTE FUNCTION dinero_inmutable();

-- La línea sí se puede quitar mientras la cuenta esté abierta —el auxiliar
-- se equivocó de servicio— pero nunca modificar: se quita y se vuelve a
-- agregar, y ambas cosas quedan en la auditoría.
CREATE OR REPLACE FUNCTION cuenta_linea_no_editar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'Una línea de la cuenta no se edita: quítela y agréguela de nuevo'
      USING ERRCODE = '0A000';
  END IF;

  SELECT estado INTO v_estado FROM cuenta WHERE id = OLD.cuenta_id;
  IF v_estado <> 'abierta' THEN
    RAISE EXCEPTION 'La cuenta está %: su detalle ya no se toca', v_estado
      USING ERRCODE = '23514';
  END IF;
  RETURN OLD;
END;
$$;

CREATE TRIGGER cuenta_linea_no_editar BEFORE UPDATE OR DELETE ON cuenta_linea
  FOR EACH ROW EXECUTE FUNCTION cuenta_linea_no_editar();

-- ---------------------------------------------------------------------
-- Lectura
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cuenta_json(p_cuenta_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'cuenta_id',   c.id,
    'estado',      c.estado,
    'fecha',       c.fecha,
    'sede_id',     c.sede_id,
    'turno_id',    c.turno_id,
    'turno',       t.codigo,
    'consulta_id', c.consulta_id,
    'paciente_id', c.paciente_id,
    'paciente',    p.nombre,
    'especie_emoji', CASE WHEN p.id IS NOT NULL THEN emoji_especie(p.especie) END,
    'dueno_id',    c.dueno_id,
    'dueno',       d.nombre_completo,
    'chat_id',     d.telegram_chat_id,
    'consentimiento', COALESCE(d.consentimiento_datos, false),
    'subtotal',    c.subtotal,
    'descuento',   c.descuento,
    'total',       c.total,
    'pagado',      c.pagado,
    'pendiente',   GREATEST(c.total - c.pagado, 0),
    'vuelto',      GREATEST(c.pagado - c.total, 0),
    'recibo_numero', c.recibo_numero,
    'motivo_anulacion', c.motivo_anulacion,
    'abierta_at',  to_char(c.fecha_apertura AT TIME ZONE 'America/Bogota', 'HH24:MI'),
    'cerrada_at',  to_char(c.fecha_cierre AT TIME ZONE 'America/Bogota', 'HH24:MI'),
    'lineas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'linea_id', l.id, 'tipo', l.tipo, 'descripcion', l.descripcion,
               'cantidad', l.cantidad, 'valor_unitario', l.valor_unitario,
               'valor_total', l.valor_total,
               'de_inventario', l.movimiento_id IS NOT NULL) ORDER BY l.created_at)
        FROM cuenta_linea l WHERE l.cuenta_id = c.id), '[]'::jsonb),
    'descuentos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'descuento_id', x.id, 'tipo', x.tipo, 'valor', x.valor,
               'motivo', x.motivo, 'autorizado_por', ua.nombre_completo) ORDER BY x.created_at)
        FROM descuento x LEFT JOIN usuario ua ON ua.id = x.autorizado_por
       WHERE x.cuenta_id = c.id), '[]'::jsonb),
    'pagos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'pago_id', g.id, 'tipo', g.tipo, 'medio', g.medio,
               'medio_nombre', nombre_medio_pago(g.medio),
               'emoji', emoji_medio_pago(g.medio),
               'valor', g.valor, 'referencia', g.referencia,
               'hora', to_char(g.created_at AT TIME ZONE 'America/Bogota', 'HH24:MI'))
             ORDER BY g.created_at)
        FROM pago g WHERE g.cuenta_id = c.id), '[]'::jsonb))
    FROM cuenta c
    LEFT JOIN turno t    ON t.id = c.turno_id
    LEFT JOIN paciente p ON p.id = c.paciente_id
    LEFT JOIN dueno d    ON d.id = c.dueno_id
   WHERE c.id = p_cuenta_id;
$$;

-- Las cuentas que están esperando cobro. Es la primera pantalla del
-- auxiliar en recepción.
CREATE OR REPLACE FUNCTION cuentas_abiertas(p_sede_id uuid, p_limite int DEFAULT 10)
RETURNS TABLE (
  cuenta_id uuid, turno text, paciente text, emoji text, dueno text,
  total numeric, pendiente numeric, estado_turno text, minutos int
)
LANGUAGE sql STABLE AS $$
  SELECT c.id, t.codigo,
         COALESCE(p.nombre, 'Sin paciente'),
         CASE WHEN p.id IS NOT NULL THEN emoji_especie(p.especie) ELSE '🐾' END,
         d.nombre_completo,
         c.total, GREATEST(c.total - c.pagado, 0),
         t.estado,
         (extract(epoch FROM now() - c.fecha_apertura) / 60)::int
    FROM cuenta c
    LEFT JOIN turno t    ON t.id = c.turno_id
    LEFT JOIN paciente p ON p.id = c.paciente_id
    LEFT JOIN dueno d    ON d.id = c.dueno_id
   WHERE c.sede_id = p_sede_id AND c.estado = 'abierta'
   ORDER BY (t.estado = 'finalizado') DESC, c.fecha_apertura
   LIMIT GREATEST(p_limite, 1);
$$;

CREATE OR REPLACE FUNCTION tarifas_activas(p_limite int DEFAULT 12)
RETURNS TABLE (
  tarifa_id uuid, nombre text, valor_sugerido numeric, permite_valor_libre boolean
)
LANGUAGE sql STABLE AS $$
  SELECT id, nombre, valor_sugerido, permite_valor_libre
    FROM tarifa WHERE activa
   ORDER BY orden, nombre
   LIMIT GREATEST(p_limite, 1);
$$;

-- El recibo tal como lo recibe el dueño por Telegram y lo ve el auxiliar
-- al cerrar. Sin tablas ASCII: se lee en un celular de gama baja (§12).
CREATE OR REPLACE FUNCTION recibo_texto(p_cuenta_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  c jsonb := cuenta_json(p_cuenta_id);
  v_texto text;
  v_bloque text;
BEGIN
  IF c IS NULL THEN RETURN NULL; END IF;

  v_texto := format('🧾 <b>%s</b>%sRecibo N.° %s · %s',
               esc(config_txt('nombre_clinica', 'Chasqui Pet')), E'\n',
               COALESCE((c->>'recibo_numero'), '—'),
               to_char((c->>'fecha')::date, 'DD/MM/YYYY'));

  IF c->>'paciente' IS NOT NULL THEN
    v_texto := v_texto || E'\n' ||
               format('%s %s', COALESCE(c->>'especie_emoji', '🐾'), esc(c->>'paciente'));
  END IF;

  SELECT string_agg(format('• %s%s · %s',
                           esc(l->>'descripcion'),
                           CASE WHEN (l->>'cantidad')::numeric <> 1
                                THEN ' ×' || fmt_cant((l->>'cantidad')::numeric) ELSE '' END,
                           pesos((l->>'valor_total')::numeric)), E'\n')
    INTO v_bloque FROM jsonb_array_elements(c->'lineas') l;

  IF v_bloque IS NOT NULL THEN
    v_texto := v_texto || E'\n\n' || v_bloque;
  END IF;

  v_texto := v_texto || E'\n\n' || format('Subtotal: %s', pesos((c->>'subtotal')::numeric));

  IF (c->>'descuento')::numeric > 0 THEN
    v_texto := v_texto || E'\n' || format('Descuento: −%s', pesos((c->>'descuento')::numeric));
  END IF;

  v_texto := v_texto || E'\n' || format('<b>Total: %s</b>', pesos((c->>'total')::numeric));

  SELECT string_agg(format('%s %s: %s', x->>'emoji', esc(x->>'medio_nombre'),
                           pesos((x->>'valor')::numeric)), E'\n')
    INTO v_bloque
    FROM jsonb_array_elements(c->'pagos') x
   WHERE x->>'tipo' = 'pago';

  IF v_bloque IS NOT NULL THEN
    v_texto := v_texto || E'\n' || v_bloque;
  END IF;

  IF (c->>'vuelto')::numeric > 0 THEN
    v_texto := v_texto || E'\n' || format('Cambio: %s', pesos((c->>'vuelto')::numeric));
  END IF;

  IF c->>'estado' = 'anulada' THEN
    v_texto := v_texto || E'\n\n' || '🚫 <b>ANULADO</b>: ' || esc(c->>'motivo_anulacion');
  END IF;

  RETURN v_texto || E'\n\n' ||
         esc(config_txt('recibo_leyenda',
             'Documento interno de la clínica. No es factura electrónica.'));
END;
$$;

-- ---------------------------------------------------------------------
-- Escritura: apertura de la cuenta
--
-- La llama la tarea abrir_cuenta_turno, encolada por iniciar_atencion()
-- (§7.2.1). Es idempotente: el worker puede reintentar sin duplicar.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION abrir_cuenta_para_turno(
  p_turno_id uuid,
  p_actor_id uuid DEFAULT NULL,
  p_canal text DEFAULT 'sistema'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v turno; v_id uuid;
BEGIN
  SELECT * INTO v FROM turno WHERE id = p_turno_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'turno_inexistente',
             'mensaje', 'Ese turno ya no existe.');
  END IF;

  SELECT id INTO v_id FROM cuenta WHERE turno_id = p_turno_id;
  IF v_id IS NOT NULL THEN
    -- Reintento del worker, o el turno volvió a atención: no se duplica.
    -- Sí se completan los datos que no se sabían al abrirla, porque la
    -- cuenta se abre al entrar en atención y el paciente puede vincularse
    -- después.
    UPDATE cuenta
       SET paciente_id = COALESCE(paciente_id, v.paciente_id),
           dueno_id    = COALESCE(dueno_id, v.dueno_id),
           consulta_id = COALESCE(consulta_id, v.consulta_id)
     WHERE id = v_id AND estado = 'abierta';

    RETURN jsonb_build_object('ok', true, 'ya_existia', true,
                              'cuenta', cuenta_json(v_id));
  END IF;

  INSERT INTO cuenta (sede_id, fecha, turno_id, consulta_id, paciente_id, dueno_id,
                      abierta_por, canal_origen)
  VALUES (v.sede_id, v.fecha, v.id, v.consulta_id, v.paciente_id, v.dueno_id,
          COALESCE(p_actor_id, v.veterinario_id), p_canal)
  RETURNING id INTO v_id;

  UPDATE turno SET cuenta_id = v_id WHERE id = p_turno_id;

  PERFORM auditar('cuenta', v_id::text, 'abrir', p_actor_id, p_canal, NULL,
                  jsonb_build_object('turno_id', p_turno_id, 'codigo', v.codigo));

  RETURN jsonb_build_object('ok', true, 'ya_existia', false,
                            'cuenta', cuenta_json(v_id));
END;
$$;

-- La cuenta viva de un turno. Si el turno ya pasó por atención pero la
-- tarea aún no corrió, la abre: nadie debe quedarse sin poder cobrar
-- porque el worker esté ocupado.
CREATE OR REPLACE FUNCTION cuenta_de_turno(p_turno_id uuid, p_actor_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_r jsonb;
BEGIN
  SELECT id INTO v_id FROM cuenta WHERE turno_id = p_turno_id AND estado = 'abierta';
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  IF EXISTS (SELECT 1 FROM cuenta WHERE turno_id = p_turno_id) THEN
    RETURN NULL;   -- ya se cerró o se anuló: no se reabre sola
  END IF;

  v_r := abrir_cuenta_para_turno(p_turno_id, p_actor_id, 'telegram');
  RETURN (v_r->'cuenta'->>'cuenta_id')::uuid;
END;
$$;

-- ---------------------------------------------------------------------
-- Escritura: líneas
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION agregar_linea_servicio(
  p_actor_id uuid,
  p_cuenta_id uuid,
  p_tarifa_id uuid DEFAULT NULL,
  p_valor numeric DEFAULT NULL,
  p_cantidad numeric DEFAULT 1,
  p_descripcion text DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_tarifa tarifa;
  v_valor numeric := p_valor;
  v_desc text := NULLIF(trim(COALESCE(p_descripcion, '')), '');
  v_id uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'cobro.linea');

  IF p_tarifa_id IS NOT NULL THEN
    SELECT * INTO v_tarifa FROM tarifa WHERE id = p_tarifa_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa tarifa ya no existe.');
    END IF;
    v_valor := COALESCE(v_valor, v_tarifa.valor_sugerido);
    v_desc  := COALESCE(v_desc, v_tarifa.nombre);
  END IF;

  IF v_desc IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_descripcion',
             'mensaje', 'Toda línea necesita decir qué se cobra.');
  END IF;
  IF v_valor IS NULL OR v_valor < 0 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'valor_invalido',
             'mensaje', 'El valor no puede ir vacío ni ser negativo.');
  END IF;
  IF COALESCE(p_cantidad, 1) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'La cantidad debe ser mayor que cero.');
  END IF;

  BEGIN
    INSERT INTO cuenta_linea (cuenta_id, tipo, referencia_id, descripcion,
                              cantidad, valor_unitario, usuario_id, canal)
    VALUES (p_cuenta_id, 'servicio', p_tarifa_id, v_desc,
            COALESCE(p_cantidad, 1), v_valor, p_actor_id, p_canal)
    RETURNING id INTO v_id;
  EXCEPTION WHEN check_violation THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'cuenta_cerrada', 'mensaje', SQLERRM);
  END;

  PERFORM auditar('cuenta', p_cuenta_id::text, 'agregar_linea', p_actor_id, p_canal, NULL,
                  jsonb_build_object('linea_id', v_id, 'descripcion', v_desc,
                                     'cantidad', COALESCE(p_cantidad, 1),
                                     'valor_unitario', v_valor));

  RETURN jsonb_build_object('ok', true, 'linea_id', v_id,
                            'cuenta', cuenta_json(p_cuenta_id));
END;
$$;

-- La línea del medicamento despachado, al precio_venta del catálogo
-- (§6.3). La crea la tarea agregar_linea_cuenta a partir del movimiento,
-- y por eso es idempotente por movimiento_id: el worker puede reintentar.
--
-- El precio se copia a la línea y no se vuelve a leer: si mañana sube el
-- precio del medicamento, el recibo de hoy sigue diciendo lo que se cobró.
CREATE OR REPLACE FUNCTION agregar_linea_medicamento(
  p_movimiento_id bigint,
  p_actor_id uuid DEFAULT NULL,
  p_canal text DEFAULT 'job'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_mov movimiento_inventario;
  v_med medicamento;
  v_cuenta uuid;
  v_id uuid;
BEGIN
  SELECT * INTO v_mov FROM movimiento_inventario WHERE id = p_movimiento_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'movimiento_inexistente',
             'mensaje', 'Ese movimiento no existe.');
  END IF;

  SELECT id INTO v_id FROM cuenta_linea WHERE movimiento_id = p_movimiento_id;
  IF v_id IS NOT NULL THEN
    SELECT cuenta_id INTO v_cuenta FROM cuenta_linea WHERE id = v_id;
    RETURN jsonb_build_object('ok', true, 'ya_existia', true, 'linea_id', v_id,
                              'cuenta', cuenta_json(v_cuenta));
  END IF;

  IF v_mov.tipo <> 'salida' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'no_es_salida',
             'mensaje', 'Sólo las salidas se cobran.');
  END IF;

  -- Sin turno no hay a quién cobrarle: es una salida suelta (muestra,
  -- uso interno). No es un error, simplemente no genera línea.
  IF v_mov.turno_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_turno',
             'mensaje', 'La salida no está atada a una visita: no genera cobro.');
  END IF;

  v_cuenta := cuenta_de_turno(v_mov.turno_id, COALESCE(p_actor_id, v_mov.usuario_id));
  IF v_cuenta IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'cuenta_cerrada',
             'mensaje', 'La cuenta de esa visita ya está cerrada.');
  END IF;

  SELECT * INTO v_med FROM medicamento WHERE id = v_mov.medicamento_id;

  INSERT INTO cuenta_linea (cuenta_id, tipo, referencia_id, movimiento_id, descripcion,
                            cantidad, valor_unitario, usuario_id, canal)
  VALUES (v_cuenta, 'medicamento', v_med.id, p_movimiento_id,
          v_med.nombre_generico || COALESCE(' (' || v_med.nombre_comercial || ')', ''),
          v_mov.cantidad, v_med.precio_venta,
          COALESCE(p_actor_id, v_mov.usuario_id), p_canal)
  RETURNING id INTO v_id;

  PERFORM auditar('cuenta', v_cuenta::text, 'agregar_linea_medicamento',
                  COALESCE(p_actor_id, v_mov.usuario_id), p_canal, NULL,
                  jsonb_build_object('linea_id', v_id, 'movimiento_id', p_movimiento_id,
                                     'cantidad', v_mov.cantidad,
                                     'valor_unitario', v_med.precio_venta));

  RETURN jsonb_build_object('ok', true, 'ya_existia', false, 'linea_id', v_id,
                            'cuenta', cuenta_json(v_cuenta));
END;
$$;

-- Quitar una línea equivocada. La del medicamento no se quita desde aquí:
-- el producto ya salió del inventario y borrar sólo el cobro dejaría la
-- existencia sin cuadrar. Se corrige con una devolución en inventario.
CREATE OR REPLACE FUNCTION quitar_linea(
  p_actor_id uuid, p_linea_id uuid, p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_linea cuenta_linea;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'cobro.linea');

  SELECT * INTO v_linea FROM cuenta_linea WHERE id = p_linea_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa línea ya no está.');
  END IF;

  IF v_linea.movimiento_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'linea_de_inventario',
             'mensaje', 'Esa línea viene de una salida de medicamento. ' ||
                        'Para quitarla hay que registrar la devolución en inventario.');
  END IF;

  BEGIN
    DELETE FROM cuenta_linea WHERE id = p_linea_id;
  EXCEPTION WHEN check_violation THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', SQLERRM);
  END;

  PERFORM auditar('cuenta', v_linea.cuenta_id::text, 'quitar_linea', p_actor_id, p_canal,
                  jsonb_build_object('descripcion', v_linea.descripcion,
                                     'valor_total', v_linea.valor_total), NULL);

  RETURN jsonb_build_object('ok', true, 'cuenta', cuenta_json(v_linea.cuenta_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Escritura: descuentos (§7.3)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aplicar_descuento(
  p_actor_id uuid,
  p_cuenta_id uuid,
  p_valor numeric,
  p_motivo text,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE c cuenta; v_id uuid; v_motivo text := NULLIF(trim(COALESCE(p_motivo, '')), '');
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'cobro.descuento');

  SELECT * INTO c FROM cuenta WHERE id = p_cuenta_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa cuenta ya no existe.');
  END IF;
  IF c.estado <> 'abierta' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'cuenta_cerrada',
             'mensaje', format('La cuenta está %s.', c.estado));
  END IF;
  IF v_motivo IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_motivo',
             'mensaje', 'Todo descuento necesita un motivo escrito.');
  END IF;
  IF p_valor IS NULL OR p_valor <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'valor_invalido',
             'mensaje', 'El descuento debe ser mayor que cero.');
  END IF;
  IF p_valor > (c.subtotal - c.descuento) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'excede',
             'mensaje', format('El descuento no puede pasar de %s.',
                               pesos(c.subtotal - c.descuento)));
  END IF;

  INSERT INTO descuento (cuenta_id, tipo, valor, motivo, autorizado_por, canal)
  VALUES (p_cuenta_id, 'descuento', p_valor, v_motivo, p_actor_id, p_canal)
  RETURNING id INTO v_id;

  PERFORM auditar('cuenta', p_cuenta_id::text, 'descuento', p_actor_id, p_canal, NULL,
                  jsonb_build_object('descuento_id', v_id, 'valor', p_valor), v_motivo);

  RETURN jsonb_build_object('ok', true, 'descuento_id', v_id,
                            'cuenta', cuenta_json(p_cuenta_id));
END;
$$;

CREATE OR REPLACE FUNCTION revertir_descuento(
  p_actor_id uuid, p_descuento_id uuid, p_motivo text, p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE d descuento; v_id uuid; v_motivo text := NULLIF(trim(COALESCE(p_motivo, '')), '');
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'cobro.descuento');

  SELECT * INTO d FROM descuento WHERE id = p_descuento_id;
  IF NOT FOUND OR d.tipo <> 'descuento' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese descuento no existe.');
  END IF;
  IF EXISTS (SELECT 1 FROM descuento WHERE revierte_id = p_descuento_id) THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese descuento ya se había revertido.');
  END IF;

  INSERT INTO descuento (cuenta_id, tipo, valor, motivo, autorizado_por, revierte_id, canal)
  VALUES (d.cuenta_id, 'reverso', d.valor,
          COALESCE(v_motivo, 'Reverso del descuento'), p_actor_id, d.id, p_canal)
  RETURNING id INTO v_id;

  PERFORM auditar('cuenta', d.cuenta_id::text, 'revertir_descuento', p_actor_id, p_canal,
                  jsonb_build_object('descuento_id', d.id, 'valor', d.valor),
                  jsonb_build_object('reverso_id', v_id), v_motivo);

  RETURN jsonb_build_object('ok', true, 'cuenta', cuenta_json(d.cuenta_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Caja (§7.1)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION caja_abierta(p_sede_id uuid)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM cierre_caja WHERE sede_id = p_sede_id AND estado = 'abierto';
$$;

CREATE OR REPLACE FUNCTION abrir_caja(
  p_actor_id uuid,
  p_sede_id uuid,
  p_base_inicial numeric DEFAULT 0,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'caja.cerrar');

  v_id := caja_abierta(p_sede_id);
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'ya_existia', true, 'caja', caja_json(v_id));
  END IF;

  INSERT INTO cierre_caja (sede_id, usuario_id, base_inicial)
  VALUES (p_sede_id, p_actor_id, GREATEST(COALESCE(p_base_inicial, 0), 0))
  RETURNING id INTO v_id;

  PERFORM auditar('cierre_caja', v_id::text, 'abrir', p_actor_id, p_canal, NULL,
                  jsonb_build_object('base_inicial', COALESCE(p_base_inicial, 0)));

  RETURN jsonb_build_object('ok', true, 'ya_existia', false, 'caja', caja_json(v_id));
END;
$$;

-- Se abre sola al recibir el primer pago del día. Que el auxiliar no
-- pueda cobrar porque nadie declaró la base sería una traba inventada;
-- la base queda en cero y se corrige al cerrar, en las notas.
CREATE OR REPLACE FUNCTION caja_abierta_o_abrir(p_sede_id uuid, p_actor_id uuid)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  v_id := caja_abierta(p_sede_id);
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  INSERT INTO cierre_caja (sede_id, usuario_id, base_inicial, notas)
  VALUES (p_sede_id, p_actor_id, 0, 'Abierta automáticamente con el primer pago del día.')
  RETURNING id INTO v_id;

  PERFORM auditar('cierre_caja', v_id::text, 'abrir_automatica', p_actor_id, 'sistema');
  RETURN v_id;
END;
$$;

-- Lo que la caja lleva acumulado ahora mismo, sin cerrarla.
CREATE OR REPLACE FUNCTION caja_json(p_caja_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH t AS (
    SELECT COALESCE(sum(signo_dinero(p.tipo) * p.valor)
             FILTER (WHERE p.medio = 'efectivo'), 0)      AS efectivo,
           COALESCE(sum(signo_dinero(p.tipo) * p.valor)
             FILTER (WHERE p.medio = 'transferencia'), 0) AS transferencia,
           COALESCE(sum(signo_dinero(p.tipo) * p.valor)
             FILTER (WHERE p.medio = 'datafono'), 0)      AS datafono,
           count(*) FILTER (WHERE p.tipo = 'pago')        AS pagos
      FROM pago p WHERE p.cierre_caja_id = p_caja_id
  ), c AS (
    SELECT count(*) AS cuentas, COALESCE(sum(descuento), 0) AS descuentos
      FROM cuenta WHERE cierre_caja_id = p_caja_id AND estado = 'cerrada'
  )
  SELECT jsonb_build_object(
    'caja_id',       k.id,
    'sede_id',       k.sede_id,
    'estado',        k.estado,
    'fecha',         k.fecha,
    'abierta_por',   u.nombre_completo,
    'abierta_at',    to_char(k.apertura_at AT TIME ZONE 'America/Bogota', 'HH24:MI'),
    'cerrada_at',    to_char(k.cierre_at AT TIME ZONE 'America/Bogota', 'HH24:MI'),
    'base_inicial',  k.base_inicial,
    'efectivo',      CASE WHEN k.estado = 'cerrado' THEN k.total_efectivo_esperado
                          ELSE k.base_inicial + t.efectivo END,
    'efectivo_recibido', CASE WHEN k.estado = 'cerrado'
                              THEN k.total_efectivo_esperado - k.base_inicial
                              ELSE t.efectivo END,
    'transferencia', CASE WHEN k.estado = 'cerrado' THEN k.total_transferencia
                          ELSE t.transferencia END,
    'datafono',      CASE WHEN k.estado = 'cerrado' THEN k.total_datafono ELSE t.datafono END,
    'descuentos',    CASE WHEN k.estado = 'cerrado' THEN k.total_descuento ELSE c.descuentos END,
    'cuentas',       CASE WHEN k.estado = 'cerrado' THEN k.cuentas_cerradas ELSE c.cuentas END,
    'pagos',         t.pagos,
    'contado',       k.total_efectivo_contado,
    'diferencia',    k.diferencia,
    'notas',         k.notas)
  FROM cierre_caja k
  LEFT JOIN usuario u ON u.id = k.usuario_id
  CROSS JOIN t CROSS JOIN c
  WHERE k.id = p_caja_id;
$$;

CREATE OR REPLACE FUNCTION cerrar_caja(
  p_actor_id uuid,
  p_caja_id uuid,
  p_efectivo_contado numeric,
  p_notas text DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE k cierre_caja; v jsonb; v_esperado numeric; v_dif numeric;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'caja.cerrar');

  SELECT * INTO k FROM cierre_caja WHERE id = p_caja_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa caja no existe.');
  END IF;
  IF k.estado = 'cerrado' THEN
    RETURN jsonb_build_object('ok', true, 'ya_cerrada', true, 'caja', caja_json(p_caja_id));
  END IF;
  IF p_efectivo_contado IS NULL OR p_efectivo_contado < 0 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_conteo',
             'mensaje', 'Falta cuánto efectivo hay contado en la caja.');
  END IF;

  -- Cerrar con cuentas abiertas deja dinero sin registrar y el cuadre no
  -- significa nada. Se dice cuántas son para que se puedan cerrar antes.
  IF EXISTS (SELECT 1 FROM cuenta
              WHERE sede_id = k.sede_id AND estado = 'abierta' AND total > 0) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'cuentas_abiertas',
             'cuentas', (SELECT count(*) FROM cuenta
                          WHERE sede_id = k.sede_id AND estado = 'abierta' AND total > 0),
             'mensaje', 'Hay cuentas con saldo sin cerrar. Ciérralas antes de cuadrar la caja.');
  END IF;

  v := caja_json(p_caja_id);
  v_esperado := (v->>'efectivo')::numeric;
  v_dif := p_efectivo_contado - v_esperado;

  UPDATE cierre_caja
     SET estado = 'cerrado',
         cierre_at = now(),
         cerrada_por = p_actor_id,
         total_efectivo_esperado = v_esperado,
         total_efectivo_contado = p_efectivo_contado,
         total_transferencia = (v->>'transferencia')::numeric,
         total_datafono = (v->>'datafono')::numeric,
         total_descuento = (v->>'descuentos')::numeric,
         cuentas_cerradas = (v->>'cuentas')::int,
         diferencia = v_dif,
         notas = COALESCE(NULLIF(trim(COALESCE(p_notas, '')), ''), notas)
   WHERE id = p_caja_id;

  PERFORM auditar('cierre_caja', p_caja_id::text, 'cerrar', p_actor_id, p_canal, v,
                  jsonb_build_object('contado', p_efectivo_contado, 'diferencia', v_dif),
                  p_notas);

  -- Una diferencia no es un error del sistema, es un hecho del día: se le
  -- avisa a quien administra en vez de dejarlo en un reporte que nadie abre.
  IF v_dif <> 0 THEN
    PERFORM encolar_tarea('notificar_superadmin',
             jsonb_build_object('texto',
               format('🧾 Cierre de caja con diferencia de %s.%sEsperado %s · contado %s.',
                      pesos(v_dif), E'\n', pesos(v_esperado), pesos(p_efectivo_contado))),
             5, 'caja_dif_' || p_caja_id::text, 0, 2);
  END IF;

  RETURN jsonb_build_object('ok', true, 'caja', caja_json(p_caja_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Escritura: pagos y cierre de la cuenta (§7.2)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION registrar_pago(
  p_actor_id uuid,
  p_cuenta_id uuid,
  p_medio text,
  p_valor numeric DEFAULT NULL,       -- NULL = lo que falte
  p_referencia text DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c cuenta;
  v_pendiente numeric;
  v_valor numeric;
  v_vuelto numeric := 0;
  v_caja uuid;
  v_id uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'cobro.pago');

  SELECT * INTO c FROM cuenta WHERE id = p_cuenta_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa cuenta ya no existe.');
  END IF;
  IF c.estado <> 'abierta' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'cuenta_cerrada',
             'mensaje', format('La cuenta está %s.', c.estado));
  END IF;
  IF p_medio NOT IN ('efectivo','transferencia','datafono') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Medio de pago no válido.');
  END IF;

  v_pendiente := GREATEST(c.total - c.pagado, 0);
  IF v_pendiente = 0 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_pendiente',
             'mensaje', 'Esa cuenta ya está pagada.');
  END IF;

  v_valor := COALESCE(p_valor, v_pendiente);
  IF v_valor <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'valor_invalido',
             'mensaje', 'El pago debe ser mayor que cero.');
  END IF;

  -- Con billetes se entrega de más y se devuelve el cambio. Se registra lo
  -- que se cobra, no lo que pasó por el mostrador, y se informa el vuelto.
  IF v_valor > v_pendiente THEN
    IF p_medio <> 'efectivo' THEN
      RETURN jsonb_build_object('ok', false, 'motivo', 'excede',
               'mensaje', format('Faltan %s. No se puede pagar de más por %s.',
                                 pesos(v_pendiente), lower(nombre_medio_pago(p_medio))));
    END IF;
    v_vuelto := v_valor - v_pendiente;
    v_valor := v_pendiente;
  END IF;

  v_caja := caja_abierta_o_abrir(c.sede_id, p_actor_id);

  INSERT INTO pago (cuenta_id, cierre_caja_id, tipo, medio, valor, referencia,
                    usuario_id, canal)
  VALUES (p_cuenta_id, v_caja, 'pago', p_medio, v_valor,
          NULLIF(trim(COALESCE(p_referencia, '')), ''), p_actor_id, p_canal)
  RETURNING id INTO v_id;

  PERFORM auditar('cuenta', p_cuenta_id::text, 'pago', p_actor_id, p_canal, NULL,
                  jsonb_build_object('pago_id', v_id, 'medio', p_medio, 'valor', v_valor));

  RETURN jsonb_build_object('ok', true, 'pago_id', v_id, 'vuelto', v_vuelto,
                            'cuenta', cuenta_json(p_cuenta_id));
END;
$$;

CREATE OR REPLACE FUNCTION revertir_pago(
  p_actor_id uuid, p_pago_id uuid, p_motivo text, p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE g pago; v_id uuid; v_motivo text := NULLIF(trim(COALESCE(p_motivo, '')), '');
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'cobro.pago');

  IF v_motivo IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_motivo',
             'mensaje', 'Deshacer un pago exige explicar por qué.');
  END IF;

  SELECT * INTO g FROM pago WHERE id = p_pago_id;
  IF NOT FOUND OR g.tipo <> 'pago' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese pago no existe.');
  END IF;
  IF EXISTS (SELECT 1 FROM pago WHERE revierte_id = p_pago_id) THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese pago ya se había revertido.');
  END IF;

  INSERT INTO pago (cuenta_id, cierre_caja_id, tipo, medio, valor, motivo,
                    revierte_id, usuario_id, canal)
  VALUES (g.cuenta_id, g.cierre_caja_id, 'reverso', g.medio, g.valor, v_motivo,
          g.id, p_actor_id, p_canal)
  RETURNING id INTO v_id;

  PERFORM auditar('cuenta', g.cuenta_id::text, 'revertir_pago', p_actor_id, p_canal,
                  jsonb_build_object('pago_id', g.id, 'medio', g.medio, 'valor', g.valor),
                  jsonb_build_object('reverso_id', v_id), v_motivo);

  RETURN jsonb_build_object('ok', true, 'cuenta', cuenta_json(g.cuenta_id));
END;
$$;

-- Cierre de la cuenta (§7.2.4): consecutivo, recibo al dueño y adiós.
CREATE OR REPLACE FUNCTION cerrar_cuenta(
  p_actor_id uuid, p_cuenta_id uuid, p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE c cuenta; v_numero int; v_caja uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'cobro.pago');

  SELECT * INTO c FROM cuenta WHERE id = p_cuenta_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa cuenta ya no existe.');
  END IF;
  IF c.estado = 'cerrada' THEN
    RETURN jsonb_build_object('ok', true, 'ya_cerrada', true, 'cuenta', cuenta_json(p_cuenta_id));
  END IF;
  IF c.estado = 'anulada' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa cuenta está anulada.');
  END IF;

  IF c.pagado < c.total THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'falta_pago',
             'pendiente', c.total - c.pagado,
             'mensaje', format('Faltan %s por pagar.', pesos(c.total - c.pagado)));
  END IF;

  v_numero := siguiente_numero_recibo(c.sede_id);
  v_caja := CASE WHEN c.total > 0 THEN caja_abierta(c.sede_id) END;

  UPDATE cuenta
     SET estado = 'cerrada', fecha_cierre = now(), cerrada_por = p_actor_id,
         recibo_numero = v_numero,
         cierre_caja_id = COALESCE(cierre_caja_id, v_caja)
   WHERE id = p_cuenta_id;

  PERFORM auditar('cuenta', p_cuenta_id::text, 'cerrar', p_actor_id, p_canal, NULL,
                  jsonb_build_object('recibo_numero', v_numero, 'total', c.total));

  -- El recibo al Telegram del dueño, si lo hay y si consintió (§12). Lo
  -- decide el worker: aquí sólo se encola para no demorar el chat.
  PERFORM encolar_tarea('enviar_recibo',
            jsonb_build_object('cuenta_id', p_cuenta_id), 3,
            'recibo_' || p_cuenta_id::text);

  RETURN jsonb_build_object('ok', true, 'cuenta', cuenta_json(p_cuenta_id));
END;
$$;

-- Anular una cuenta cerrada es excepcional y deja rastro doble: la cuenta
-- queda 'anulada' con su motivo y cada pago recibido se revierte, para que
-- el cuadre de caja siga diciendo la verdad.
CREATE OR REPLACE FUNCTION anular_cuenta(
  p_actor_id uuid, p_cuenta_id uuid, p_motivo text, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c cuenta;
  g pago;
  v_motivo text := NULLIF(trim(COALESCE(p_motivo, '')), '');
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'cobro.anular');

  IF v_motivo IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_motivo',
             'mensaje', 'Anular una cuenta exige explicar por qué.');
  END IF;

  SELECT * INTO c FROM cuenta WHERE id = p_cuenta_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa cuenta ya no existe.');
  END IF;
  IF c.estado = 'anulada' THEN
    RETURN jsonb_build_object('ok', true, 'ya_anulada', true, 'cuenta', cuenta_json(p_cuenta_id));
  END IF;

  FOR g IN SELECT * FROM pago
            WHERE cuenta_id = p_cuenta_id AND tipo = 'pago'
              AND NOT EXISTS (SELECT 1 FROM pago r WHERE r.revierte_id = pago.id)
  LOOP
    INSERT INTO pago (cuenta_id, cierre_caja_id, tipo, medio, valor, motivo,
                      revierte_id, usuario_id, canal)
    VALUES (g.cuenta_id, g.cierre_caja_id, 'reverso', g.medio, g.valor,
            'Anulación de la cuenta: ' || v_motivo, g.id, p_actor_id, p_canal);
  END LOOP;

  UPDATE cuenta
     SET estado = 'anulada', motivo_anulacion = v_motivo,
         anulada_at = now(), anulada_por = p_actor_id
   WHERE id = p_cuenta_id;

  PERFORM auditar('cuenta', p_cuenta_id::text, 'anular', p_actor_id, p_canal,
                  cuenta_json(p_cuenta_id), NULL, v_motivo);

  RETURN jsonb_build_object('ok', true, 'cuenta', cuenta_json(p_cuenta_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Resumen de caja del día, para el bot y para el reporte del portal
-- (§10.4). Incluye lo cerrado y lo que todavía está abierto: a mitad de
-- jornada, lo segundo es lo que dice si falta cobrar algo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resumen_caja_dia(p_sede_id uuid, p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH f AS (SELECT COALESCE(p_fecha, hoy_bogota()) AS d)
  SELECT jsonb_build_object(
    'fecha', f.d,
    'caja_abierta_id', caja_abierta(p_sede_id),
    'ingresos', COALESCE((
      SELECT jsonb_object_agg(medio, valor) FROM (
        SELECT p.medio, sum(signo_dinero(p.tipo) * p.valor) AS valor
          FROM pago p JOIN cuenta c ON c.id = p.cuenta_id
         WHERE c.sede_id = p_sede_id AND c.fecha = f.d
         GROUP BY p.medio) x), '{}'::jsonb),
    'total_ingresos', COALESCE((
      SELECT sum(signo_dinero(p.tipo) * p.valor)
        FROM pago p JOIN cuenta c ON c.id = p.cuenta_id
       WHERE c.sede_id = p_sede_id AND c.fecha = f.d), 0),
    'cuentas_cerradas', (SELECT count(*) FROM cuenta
                          WHERE sede_id = p_sede_id AND fecha = f.d AND estado = 'cerrada'),
    'cuentas_abiertas', (SELECT count(*) FROM cuenta
                          WHERE sede_id = p_sede_id AND fecha = f.d AND estado = 'abierta'),
    'por_cobrar', COALESCE((SELECT sum(total - pagado) FROM cuenta
                             WHERE sede_id = p_sede_id AND fecha = f.d
                               AND estado = 'abierta'), 0),
    'descuentos', COALESCE((SELECT sum(descuento) FROM cuenta
                             WHERE sede_id = p_sede_id AND fecha = f.d
                               AND estado <> 'anulada'), 0),
    'ticket_promedio', COALESCE((SELECT round(avg(total)) FROM cuenta
                                  WHERE sede_id = p_sede_id AND fecha = f.d
                                    AND estado = 'cerrada' AND total > 0), 0))
  FROM f;
$$;
