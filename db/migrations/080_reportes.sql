-- =====================================================================
-- Chasqui Pet — 080_reportes.sql
-- Los nueve reportes de §10, más el dashboard del portal (§11.2).
--
-- Todos siguen la misma forma a propósito:
--
--   · Devuelven `TABLE (...)`, no `jsonb`. El portal los pinta como tabla
--     y los exporta a CSV sin transformar nada: la exportación es la
--     misma consulta con otra cabecera HTTP. Un reporte que hay que
--     desarmar de un jsonb para hacer un CSV acaba teniendo dos
--     versiones que se desincronizan.
--   · Reciben el rango como (desde, hasta) con NULL = mes en curso.
--   · Son `STABLE` y no exigen permiso: el permiso lo comprueba quien
--     llama —el portal, con `reportes.operativos` o
--     `reportes.financieros`—, porque el mismo dato se sirve por chat y
--     por web y el control tiene que estar en un solo sitio.
--
-- El dinero sale en `numeric` sin formatear. Formatear en SQL obligaría
-- a duplicar el reporte para el CSV, donde «$1.234.567» no es un número.
-- =====================================================================

SET client_min_messages = warning;

-- Rango por defecto: del primero del mes a hoy. Es lo que el
-- administrador quiere ver el 90 % de las veces que abre un reporte.
CREATE OR REPLACE FUNCTION rango_desde(p_desde date) RETURNS date
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(p_desde, date_trunc('month', hoy_bogota())::date);
$$;

CREATE OR REPLACE FUNCTION rango_hasta(p_hasta date) RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(p_hasta, hoy_bogota());
$$;

-- ---------------------------------------------------------------------
-- §10.1 Stock actual, con las alertas que importan
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_stock()
RETURNS TABLE (
  medicamento text, categoria text, unidad text,
  disponible numeric, stock_minimo numeric, estado text,
  lotes int, proximo_vencimiento date, dias_para_vencer int,
  precio_venta numeric, costo_promedio numeric, valor_inventario numeric
)
LANGUAGE sql STABLE AS $$
  SELECT s.nombre_generico || COALESCE(' (' || s.nombre_comercial || ')', ''),
         m.categoria, s.unidad_base,
         s.disponible, s.stock_minimo,
         CASE WHEN s.disponible = 0        THEN 'agotado'
              WHEN s.bajo_minimo           THEN 'bajo minimo'
              WHEN s.proximo_vencimiento <= hoy_bogota() + 7  THEN 'vence esta semana'
              WHEN s.proximo_vencimiento <= hoy_bogota() + 30 THEN 'vence este mes'
              ELSE 'normal' END,
         s.lotes_disponibles::int,
         s.proximo_vencimiento,
         (s.proximo_vencimiento - hoy_bogota())::int,
         s.precio_venta,
         c.costo_promedio,
         round(COALESCE(c.costo_promedio, 0) * s.disponible, 2)
    FROM v_stock_medicamento s
    JOIN medicamento m ON m.id = s.medicamento_id
    LEFT JOIN LATERAL (
      -- Costo medio ponderado de lo que hay hoy en existencia, no de todo
      -- lo que se compró alguna vez: el valor del inventario es el de lo
      -- que está en el estante.
      SELECT round(sum(l.cantidad_actual * l.costo_unitario) /
                   NULLIF(sum(l.cantidad_actual), 0), 2) AS costo_promedio
        FROM lote l
       WHERE l.medicamento_id = s.medicamento_id AND l.cantidad_actual > 0
    ) c ON true
   WHERE s.activo
   ORDER BY (s.disponible = 0) DESC, s.bajo_minimo DESC, s.nombre_generico;
$$;

-- ---------------------------------------------------------------------
-- §10.2 Consumo de medicamentos, en unidades y en valor
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_consumo(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_veterinario_id uuid DEFAULT NULL
)
RETURNS TABLE (
  medicamento text, unidad text, salidas bigint, unidades numeric,
  valor_venta numeric, costo numeric, margen numeric, pacientes bigint
)
LANGUAGE sql STABLE AS $$
  SELECT m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', ''),
         m.unidad_base,
         count(*),
         sum(mi.cantidad),
         round(sum(mi.cantidad * m.precio_venta), 2),
         round(sum(mi.cantidad * l.costo_unitario), 2),
         round(sum(mi.cantidad * (m.precio_venta - l.costo_unitario)), 2),
         count(DISTINCT mi.paciente_id)
    FROM movimiento_inventario mi
    JOIN medicamento m ON m.id = mi.medicamento_id
    JOIN lote l ON l.id = mi.lote_id
   WHERE mi.tipo = 'salida'
     AND (mi.created_at AT TIME ZONE 'America/Bogota')::date
         BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
     AND (p_veterinario_id IS NULL OR mi.usuario_id = p_veterinario_id)
   GROUP BY m.id, m.nombre_generico, m.nombre_comercial, m.unidad_base
   ORDER BY round(sum(mi.cantidad * m.precio_venta), 2) DESC;
$$;

-- ---------------------------------------------------------------------
-- §10.3 Turnos. Este reporte dice cuánto personal se necesita y a qué hora
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_turnos(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS TABLE (
  fecha date, emitidos bigint, atendidos bigint, ausentes bigint,
  cancelados bigint, en_curso bigint,
  espera_promedio_min numeric, atencion_promedio_min numeric,
  hora_pico text, por_qr bigint
)
LANGUAGE sql STABLE AS $$
  SELECT t.fecha,
         count(*),
         count(*) FILTER (WHERE t.estado = 'finalizado'),
         count(*) FILTER (WHERE t.estado = 'ausente'),
         count(*) FILTER (WHERE t.estado = 'cancelado'),
         count(*) FILTER (WHERE t.estado IN ('en_espera','llamado','en_atencion')),
         -- Espera = de que se emite el turno a que lo llaman.
         round(avg(extract(epoch FROM (t.llamado_at - t.created_at)) / 60)
               FILTER (WHERE t.llamado_at IS NOT NULL), 1),
         -- Atención = de que entra al consultorio a que se finaliza.
         round(avg(extract(epoch FROM (t.finalizado_at - t.en_atencion_at)) / 60)
               FILTER (WHERE t.finalizado_at IS NOT NULL AND t.en_atencion_at IS NOT NULL), 1),
         (SELECT to_char(date_trunc('hour', t2.created_at AT TIME ZONE 'America/Bogota'), 'HH24:MI')
            FROM turno t2 WHERE t2.fecha = t.fecha
           GROUP BY date_trunc('hour', t2.created_at AT TIME ZONE 'America/Bogota')
           ORDER BY count(*) DESC, 1 LIMIT 1),
         count(*) FILTER (WHERE t.canal_origen = 'qr_telegram')
    FROM turno t
   WHERE t.fecha BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
   GROUP BY t.fecha
   ORDER BY t.fecha DESC;
$$;

-- Distribución por hora, para saber a qué hora hace falta el segundo
-- consultorio abierto.
CREATE OR REPLACE FUNCTION reporte_turnos_hora(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS TABLE (hora text, emitidos bigint, atendidos bigint, espera_promedio_min numeric)
LANGUAGE sql STABLE AS $$
  SELECT to_char(date_trunc('hour', t.created_at AT TIME ZONE 'America/Bogota'), 'HH24:MI'),
         count(*),
         count(*) FILTER (WHERE t.estado = 'finalizado'),
         round(avg(extract(epoch FROM (t.llamado_at - t.created_at)) / 60)
               FILTER (WHERE t.llamado_at IS NOT NULL), 1)
    FROM turno t
   WHERE t.fecha BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
   GROUP BY 1
   ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION reporte_ocupacion_consultorio(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS TABLE (consultorio text, veterinario text, atendidos bigint,
               atencion_promedio_min numeric, horas_abierto numeric)
LANGUAGE sql STABLE AS $$
  SELECT c.nombre,
         COALESCE(u.nombre_completo, '—'),
         count(t.id) FILTER (WHERE t.estado = 'finalizado'),
         round(avg(extract(epoch FROM (t.finalizado_at - t.en_atencion_at)) / 60)
               FILTER (WHERE t.finalizado_at IS NOT NULL), 1),
         round(COALESCE((
           SELECT sum(extract(epoch FROM (COALESCE(sc.cerrada_at, now()) - sc.abierta_at)) / 3600)
             FROM sesion_consultorio sc
            WHERE sc.consultorio_id = c.id AND sc.usuario_id = u.id
              AND (sc.abierta_at AT TIME ZONE 'America/Bogota')::date
                  BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)), 0), 1)
    FROM turno t
    JOIN consultorio c ON c.id = t.consultorio_id
    LEFT JOIN usuario u ON u.id = t.veterinario_id
   WHERE t.fecha BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
   GROUP BY c.id, c.nombre, u.id, u.nombre_completo
   ORDER BY c.nombre, u.nombre_completo;
$$;

-- ---------------------------------------------------------------------
-- §10.4 Caja: ingresos por día y por medio de pago
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_caja(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS TABLE (
  fecha date, cuentas bigint, efectivo numeric, transferencia numeric,
  datafono numeric, total numeric, descuentos numeric,
  ticket_promedio numeric, diferencia numeric
)
LANGUAGE sql STABLE AS $$
  WITH dias AS (
    SELECT generate_series(rango_desde(p_desde), rango_hasta(p_hasta), '1 day')::date AS fecha
  )
  SELECT d.fecha,
         COALESCE(cu.cuentas, 0),
         COALESCE(p.efectivo, 0), COALESCE(p.transferencia, 0), COALESCE(p.datafono, 0),
         COALESCE(p.efectivo, 0) + COALESCE(p.transferencia, 0) + COALESCE(p.datafono, 0),
         COALESCE(cu.descuentos, 0),
         round(COALESCE(cu.total, 0) / NULLIF(cu.cuentas, 0), 2),
         k.diferencia
    FROM dias d
    LEFT JOIN LATERAL (
      -- El signo lo da el tipo: un reverso resta. Ver signo_dinero() en 060.
      SELECT sum(pg.valor * signo_dinero(pg.tipo)) FILTER (WHERE pg.medio = 'efectivo')      AS efectivo,
             sum(pg.valor * signo_dinero(pg.tipo)) FILTER (WHERE pg.medio = 'transferencia') AS transferencia,
             sum(pg.valor * signo_dinero(pg.tipo)) FILTER (WHERE pg.medio = 'datafono')      AS datafono
        FROM pago pg
       WHERE (pg.created_at AT TIME ZONE 'America/Bogota')::date = d.fecha
    ) p ON true
    LEFT JOIN LATERAL (
      SELECT count(*) AS cuentas, sum(c.total) AS total, sum(c.descuento) AS descuentos
        FROM cuenta c
       WHERE c.fecha = d.fecha AND c.estado = 'cerrada'
    ) cu ON true
    LEFT JOIN LATERAL (
      SELECT sum(cc.diferencia) AS diferencia
        FROM cierre_caja cc WHERE cc.fecha = d.fecha AND cc.estado = 'cerrado'
    ) k ON true
   ORDER BY d.fecha DESC;
$$;

CREATE OR REPLACE FUNCTION reporte_descuentos(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS TABLE (fecha date, hora text, paciente text, valor numeric,
               motivo text, autorizo text, tipo text)
LANGUAGE sql STABLE AS $$
  SELECT (d.created_at AT TIME ZONE 'America/Bogota')::date,
         to_char(d.created_at AT TIME ZONE 'America/Bogota', 'HH24:MI'),
         COALESCE(pa.nombre, '—'),
         d.valor * signo_dinero(d.tipo),
         d.motivo,
         COALESCE(u.nombre_completo, '—'),
         d.tipo
    FROM descuento d
    JOIN cuenta c ON c.id = d.cuenta_id
    LEFT JOIN paciente pa ON pa.id = c.paciente_id
    LEFT JOIN usuario u ON u.id = d.autorizado_por
   WHERE (d.created_at AT TIME ZONE 'America/Bogota')::date
         BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
   ORDER BY d.created_at DESC;
$$;

-- ---------------------------------------------------------------------
-- §10.5 Margen: ingreso contra el costo del lote que efectivamente salió
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_margen(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS TABLE (
  medicamento text, unidades numeric, unidad text,
  ingreso numeric, costo numeric, margen numeric, margen_pct numeric
)
LANGUAGE sql STABLE AS $$
  SELECT m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', ''),
         sum(mi.cantidad), m.unidad_base,
         round(sum(mi.cantidad * m.precio_venta), 2),
         round(sum(mi.cantidad * l.costo_unitario), 2),
         round(sum(mi.cantidad * (m.precio_venta - l.costo_unitario)), 2),
         round(100 * sum(mi.cantidad * (m.precio_venta - l.costo_unitario))
               / NULLIF(sum(mi.cantidad * m.precio_venta), 0), 1)
    FROM movimiento_inventario mi
    JOIN medicamento m ON m.id = mi.medicamento_id
    JOIN lote l ON l.id = mi.lote_id
   WHERE mi.tipo = 'salida'
     AND (mi.created_at AT TIME ZONE 'America/Bogota')::date
         BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
   GROUP BY m.id, m.nombre_generico, m.nombre_comercial, m.unidad_base
   ORDER BY round(sum(mi.cantidad * (m.precio_venta - l.costo_unitario)), 2) DESC;
$$;

-- ---------------------------------------------------------------------
-- §10.6 Consultas por veterinario, por tipo y diagnósticos frecuentes
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_consultas(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS TABLE (veterinario text, firmadas bigint, borradores bigint,
               anuladas bigint, con_remision bigint, con_revision bigint,
               pacientes bigint)
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(u.nombre_completo, 'Sin asignar'),
         count(*) FILTER (WHERE c.estado = 'firmada'),
         count(*) FILTER (WHERE c.estado = 'borrador'),
         count(*) FILTER (WHERE c.estado = 'anulada'),
         count(*) FILTER (WHERE c.remision_externa IS NOT NULL),
         count(*) FILTER (WHERE c.proxima_revision IS NOT NULL),
         count(DISTINCT c.paciente_id)
    FROM consulta c
    LEFT JOIN usuario u ON u.id = c.veterinario_id
   WHERE c.fecha BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
   GROUP BY u.id, u.nombre_completo
   ORDER BY count(*) FILTER (WHERE c.estado = 'firmada') DESC;
$$;

-- Los diagnósticos se escriben a mano: se agrupan normalizados para que
-- «Gastroenteritis» y «gastroenteritis » sean el mismo renglón.
CREATE OR REPLACE FUNCTION reporte_diagnosticos(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_limite int DEFAULT 20
)
RETURNS TABLE (diagnostico text, veces bigint, pacientes bigint)
LANGUAGE sql STABLE AS $$
  SELECT initcap(normalizar(dx)), count(*), count(DISTINCT paciente_id)
    FROM (
      SELECT COALESCE(NULLIF(trim(c.diagnostico_definitivo), ''),
                      NULLIF(trim(c.diagnostico_presuntivo), '')) AS dx,
             c.paciente_id
        FROM consulta c
       WHERE c.estado = 'firmada'
         AND c.fecha BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
    ) s
   WHERE dx IS NOT NULL
   GROUP BY 1
   ORDER BY count(*) DESC, 1
   LIMIT GREATEST(p_limite, 1);
$$;

-- ---------------------------------------------------------------------
-- §10.7 Pacientes: nuevos contra recurrentes, especies y remisiones
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_pacientes(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS TABLE (especie text, pacientes bigint, nuevos bigint, recurrentes bigint,
               consultas bigint, remisiones bigint, retornaron bigint)
LANGUAGE sql STABLE AS $$
  WITH atendidos AS (
    SELECT p.id, p.especie, p.created_at,
           count(c.id) AS consultas,
           count(c.id) FILTER (WHERE c.remision_externa IS NOT NULL) AS remisiones,
           -- «Retornó» = después de una remisión hubo otra consulta suya.
           count(*) FILTER (WHERE c.remision_externa IS NOT NULL AND EXISTS (
             SELECT 1 FROM consulta c2
              WHERE c2.paciente_id = p.id AND c2.fecha > c.fecha
                AND c2.estado = 'firmada')) AS retornaron
      FROM paciente p
      JOIN consulta c ON c.paciente_id = p.id
     WHERE c.fecha BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
     GROUP BY p.id, p.especie, p.created_at
  )
  SELECT COALESCE(especie, 'sin especificar'),
         count(*),
         count(*) FILTER (WHERE (created_at AT TIME ZONE 'America/Bogota')::date
                                >= rango_desde(p_desde)),
         count(*) FILTER (WHERE (created_at AT TIME ZONE 'America/Bogota')::date
                                <  rango_desde(p_desde)),
         sum(consultas), sum(remisiones), sum(retornaron)
    FROM atendidos
   GROUP BY 1
   ORDER BY count(*) DESC;
$$;

-- ---------------------------------------------------------------------
-- §10.8 Compras por proveedor y período (versión tabular; la de resumen
-- en jsonb vive en 070_compras.sql y la usa el bot)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_compras_detalle(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS TABLE (fecha date, proveedor text, documento text, medicamento text,
               lote text, vence date, cantidad numeric, costo_unitario numeric,
               valor_total numeric, registro text)
LANGUAGE sql STABLE AS $$
  SELECT e.fecha,
         COALESCE(pr.nombre, 'Sin proveedor'),
         e.documento_soporte,
         m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', ''),
         COALESCE(l.numero_lote, '—'),
         l.fecha_vencimiento, l.cantidad, l.costo_unitario, l.valor_total,
         COALESCE(u.nombre_completo, '—')
    FROM entrada_linea l
    JOIN entrada_inventario e ON e.id = l.entrada_id
    LEFT JOIN proveedor pr ON pr.id = e.proveedor_id
    LEFT JOIN usuario u ON u.id = e.usuario_id
    JOIN medicamento m ON m.id = l.medicamento_id
   WHERE e.estado = 'confirmada'
     AND e.fecha BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
   ORDER BY e.fecha DESC, pr.nombre, m.nombre_generico;
$$;

-- ---------------------------------------------------------------------
-- §10.9 Trazabilidad: qué pacientes recibieron un lote
-- (la versión jsonb, para el bot, está en 070_compras.sql)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporte_trazabilidad(p_lote_id uuid)
RETURNS TABLE (fecha timestamptz, cantidad numeric, paciente text, especie text,
               dueno text, telefono text, atendio text, consulta_id uuid)
LANGUAGE sql STABLE AS $$
  SELECT mi.created_at, mi.cantidad,
         COALESCE(pa.nombre, '—'), pa.especie,
         COALESCE(du.nombre_completo, '—'), du.telefono,
         COALESCE(us.nombre_completo, '—'), mi.consulta_id
    FROM movimiento_inventario mi
    LEFT JOIN paciente pa ON pa.id = mi.paciente_id
    LEFT JOIN dueno du ON du.id = pa.dueno_id
    LEFT JOIN usuario us ON us.id = mi.usuario_id
   WHERE mi.lote_id = p_lote_id AND mi.tipo = 'salida'
   ORDER BY mi.created_at DESC;
$$;

-- Buscador de lotes para la pantalla de trazabilidad: se llega por el
-- número de lote impreso en la caja, que es lo que trae el comunicado de
-- retiro del laboratorio.
CREATE OR REPLACE FUNCTION buscar_lote(p_texto text, p_limite int DEFAULT 10)
RETURNS TABLE (lote_id uuid, numero_lote text, medicamento text,
               fecha_vencimiento date, cantidad_actual numeric,
               proveedor text, despachos bigint)
LANGUAGE sql STABLE AS $$
  SELECT l.id, l.numero_lote,
         m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', ''),
         l.fecha_vencimiento, l.cantidad_actual,
         COALESCE(pr.nombre, '—'),
         (SELECT count(*) FROM movimiento_inventario mi
           WHERE mi.lote_id = l.id AND mi.tipo = 'salida')
    FROM lote l
    JOIN medicamento m ON m.id = l.medicamento_id
    LEFT JOIN entrada_inventario e ON e.id = l.entrada_id
    LEFT JOIN proveedor pr ON pr.id = e.proveedor_id
   WHERE normalizar(COALESCE(p_texto, '')) <> ''
     AND (normalizar(l.numero_lote) LIKE '%' || normalizar(p_texto) || '%'
          OR m.busqueda LIKE '%' || normalizar(p_texto) || '%')
   ORDER BY l.fecha_vencimiento DESC
   LIMIT GREATEST(p_limite, 1);
$$;

-- ---------------------------------------------------------------------
-- Dashboard del portal (§11.2): cola en vivo, stock crítico y caja del día
--
-- Una sola función y una sola consulta: la portada se pinta en un viaje a
-- la base, no en seis.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dashboard(p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'fecha', hoy_bogota(),
    'cola', jsonb_build_object(
      'en_espera',   (SELECT count(*) FROM turno WHERE sede_id = p_sede_id
                       AND fecha = hoy_bogota() AND estado = 'en_espera'),
      'atendidos',   (SELECT count(*) FROM turno WHERE sede_id = p_sede_id
                       AND fecha = hoy_bogota() AND estado = 'finalizado'),
      'ausentes',    (SELECT count(*) FROM turno WHERE sede_id = p_sede_id
                       AND fecha = hoy_bogota() AND estado = 'ausente'),
      'espera_min',  COALESCE((SELECT round(avg(extract(epoch FROM (now() - created_at)) / 60))
                                 FROM turno WHERE sede_id = p_sede_id
                                  AND fecha = hoy_bogota() AND estado = 'en_espera'), 0),
      'consultorios', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'consultorio', c.nombre,
                 'abierto',     (sc.id IS NOT NULL),
                 'veterinario', u.nombre_completo,
                 'turno',       t.codigo,
                 'estado',      t.estado,
                 'paciente',    pa.nombre)
               ORDER BY c.orden)
          FROM consultorio c
          LEFT JOIN sesion_consultorio sc
                 ON sc.consultorio_id = c.id AND sc.cerrada_at IS NULL
          LEFT JOIN usuario u ON u.id = sc.usuario_id
          LEFT JOIN LATERAL (
            SELECT t2.codigo, t2.estado, t2.paciente_id FROM turno t2
             WHERE t2.consultorio_id = c.id AND t2.fecha = hoy_bogota()
               AND t2.estado IN ('llamado','en_atencion')
             ORDER BY t2.llamado_at DESC LIMIT 1
          ) t ON true
          LEFT JOIN paciente pa ON pa.id = t.paciente_id
         WHERE c.sede_id = p_sede_id AND c.activo), '[]'::jsonb)),
    'inventario', jsonb_build_object(
      'bajo_minimo', (SELECT count(*) FROM v_stock_medicamento WHERE activo AND bajo_minimo),
      'por_vencer',  (SELECT count(*) FROM v_lote_disponible
                       WHERE dias_para_vencer <= config_int('alerta_vencimiento_dias', 30)),
      'vencidos',    (SELECT count(*) FROM lote
                       WHERE fecha_vencimiento < hoy_bogota() AND cantidad_actual > 0),
      'criticos',    COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'medicamento', nombre_generico || COALESCE(' (' || nombre_comercial || ')', ''),
                 'disponible',  disponible,
                 'minimo',      stock_minimo,
                 'unidad',      unidad_base)
               ORDER BY disponible)
          FROM (SELECT * FROM v_stock_medicamento
                 WHERE activo AND bajo_minimo ORDER BY disponible LIMIT 5) s), '[]'::jsonb)),
    'caja', resumen_caja_dia(p_sede_id),
    'tareas_fallidas', (SELECT count(*) FROM tarea_async WHERE estado = 'fallida'),
    'consultas_borrador', (SELECT count(*) FROM consulta
                            WHERE estado = 'borrador' AND fecha = hoy_bogota()),
    'entradas_borrador', (SELECT count(*) FROM entrada_inventario WHERE estado = 'borrador'));
$$;
