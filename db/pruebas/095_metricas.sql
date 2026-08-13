-- =====================================================================
-- Fase B5 — métricas del asistente.
--
-- Lo que se protege aquí:
--
--   · las tres son de LECTURA. Una métrica que escribiera algo sería un
--     agujero en C6.9 que ninguna otra prueba vería, porque las de
--     confirmación solo recorren el catálogo de escrituras.
--   · el permiso se exige DENTRO de la operación, no solo en el
--     catálogo. Es la excepción de diseño de esta fase y hay que
--     sostenerla: lo que exponen es el margen del negocio y el
--     rendimiento de cada médico.
--   · el rango que se devuelve es el rango que se pidió. Una cifra con
--     el período equivocado es peor que no tenerla.
--   · el margen por lote sale de los datos reales, no de una fórmula
--     escrita dos veces.
-- =====================================================================
BEGIN;
SELECT plan(22);

-- --- El catálogo -------------------------------------------------------
SELECT is((SELECT count(*)::int FROM ia_herramienta
            WHERE nombre IN ('analizar_ocupacion', 'analizar_rendimiento_medico',
                             'analizar_rentabilidad_lotes')
              AND activa), 3,
          'las tres métricas están registradas y activas');

SELECT is((SELECT count(*)::int FROM ia_herramienta
            WHERE nombre LIKE 'analizar\_%' AND escribe), 0,
          'ninguna métrica escribe');

SELECT is((SELECT count(*)::int FROM ia_herramienta
            WHERE nombre LIKE 'analizar\_%' AND (funcion IS NULL OR modulo IS NULL)), 0,
          'las tres declaran su operación y su módulo (Fase A5)');

SELECT ok((verificar_registro_operaciones()->>'ok')::boolean,
          'el registro de operaciones sigue sin hallazgos con las métricas dentro');

SELECT is((SELECT permiso FROM ia_herramienta WHERE nombre = 'analizar_rentabilidad_lotes'),
          'reportes.financieros',
          'la rentabilidad pide el permiso financiero, no el operativo');

-- --- El permiso se exige dentro de la operación ------------------------
CREATE OR REPLACE FUNCTION pg_temp.sin_permiso(p_fn text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  EXECUTE format('SELECT public.%I($1, $2, $3)', p_fn)
     INTO v USING prueba.don_nadie(), prueba.sede(), '{}'::jsonb;
  RETURN 'no lanzó';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'rechazó';
END;
$$;

SELECT is(pg_temp.sin_permiso('op_analizar_ocupacion'), 'rechazó',
          'la ocupación exige permiso dentro de la operación');
SELECT is(pg_temp.sin_permiso('op_analizar_rendimiento_medico'), 'rechazó',
          'el rendimiento médico exige permiso dentro de la operación');
SELECT is(pg_temp.sin_permiso('op_analizar_rentabilidad_lotes'), 'rechazó',
          'la rentabilidad exige permiso dentro de la operación');

-- Y por la puerta del asistente el rechazo no se cae: se le explica al
-- modelo, que es lo que espera el bucle del worker.
SELECT is(ia_llamar(prueba.don_nadie(), 700500, prueba.sede(),
                    'analizar_rentabilidad_lotes', '{}'::jsonb)->>'ok', 'false',
          'ia_llamar rechaza la métrica sin permiso en vez de lanzar');

-- --- El rango es el que se pidió ---------------------------------------
SELECT is(ia_metrica_desde('{"dias":7}'::jsonb), hoy_bogota() - 7,
          'el atajo «últimos 7 días» arranca hace siete días');
SELECT is(ia_metrica_hasta('{}'::jsonb), hoy_bogota(),
          'sin fecha final, el rango llega hasta hoy');
SELECT is(ia_metrica_desde('{"desde":"2026-01-15","dias":7}'::jsonb), '2026-01-15'::date,
          'una fecha explícita manda sobre el atajo');
SELECT is((ia_metrica_rango('{"desde":"2026-01-01","hasta":"2026-01-31"}'::jsonb)->>'dias')::int,
          31, 'el rango informa cuántos días cubre, contando los dos extremos');

-- --- Lectura pura: nada de lo que tocan cambia -------------------------
CREATE TEMP TABLE antes AS
SELECT (SELECT count(*) FROM evento_auditoria)      AS auditoria,
       (SELECT count(*) FROM ia_accion_pendiente)   AS propuestas,
       (SELECT count(*) FROM movimiento_inventario) AS movimientos,
       (SELECT count(*) FROM tarea_async)           AS tareas;

CREATE TEMP TABLE lecturas AS
SELECT op_analizar_ocupacion(prueba.superadmin(), prueba.sede(), '{"dias":30}'::jsonb) AS ocu,
       op_analizar_rendimiento_medico(prueba.superadmin(), prueba.sede(), '{}'::jsonb) AS ren,
       op_analizar_rentabilidad_lotes(prueba.superadmin(), prueba.sede(), '{}'::jsonb) AS rent;

SELECT is((SELECT count(*) FROM evento_auditoria), (SELECT auditoria FROM antes),
          'consultar métricas no deja eventos de auditoría');
SELECT is((SELECT count(*) FROM ia_accion_pendiente), (SELECT propuestas FROM antes),
          'consultar métricas no deja propuestas por confirmar');
SELECT is((SELECT count(*) FROM tarea_async), (SELECT tareas FROM antes),
          'consultar métricas no encola nada');

SELECT ok((SELECT (ocu->>'ok')::boolean AND (ren->>'ok')::boolean AND (rent->>'ok')::boolean
             FROM lecturas),
          'las tres responden ok aunque el período no tenga datos');
SELECT is((SELECT ocu->'datos'->'rango'->>'desde' FROM lecturas),
          (hoy_bogota() - 30)::text,
          'la respuesta trae el rango que se consultó, no uno cualquiera');

-- --- El margen por lote sale de los datos ------------------------------
-- Lote de 100 unidades a 400 de costo, medicamento a 1000 de venta.
-- Salen 10 → ingreso 10 000, costo 4 000, margen 6 000, 60 %.
CREATE TEMP TABLE med AS SELECT prueba.medicamento('Metrico de prueba') AS id;
CREATE TEMP TABLE lot AS
SELECT (ingresar_lote(prueba.superadmin(), (SELECT id FROM med), 'L-METRICA',
                      hoy_bogota() + 365, 100, 400)->>'lote_id')::uuid AS id;

SELECT ok((salida_medicamento(prueba.superadmin(), (SELECT id FROM lot), 10,
                              'Prueba de métricas')->>'ok')::boolean,
          'se despachan 10 unidades del lote de prueba');

CREATE TEMP TABLE rent AS
SELECT op_analizar_rentabilidad_lotes(prueba.superadmin(), prueba.sede(),
         '{"dias":1}'::jsonb)->'datos' AS d;

SELECT is((SELECT (x->>'margen')::numeric FROM rent, jsonb_array_elements(d->'por_lote') x
            WHERE x->>'numero_lote' = 'L-METRICA'),
          6000::numeric,
          'el margen del lote es venta menos costo, por lote y no por medicamento');

SELECT is((SELECT (x->>'margen_pct')::numeric FROM rent, jsonb_array_elements(d->'por_lote') x
            WHERE x->>'numero_lote' = 'L-METRICA'),
          60.0::numeric,
          'y su porcentaje de margen cuadra');

SELECT ok((SELECT (d->'totales'->>'margen')::numeric >= 6000 FROM rent),
          'el total incluye ese margen');

SELECT * FROM finish();
ROLLBACK;
