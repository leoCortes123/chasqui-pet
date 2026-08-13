-- =====================================================================
-- Invariante C6.9: la IA nunca ejecuta una escritura por su cuenta.
--
-- El flujo obligatorio es propuesta → tarjeta → botón → ejecución. Aquí
-- se recorre el catálogo COMPLETO de herramientas con `escribe = true`
-- —las 25 de hoy y las que se agreguen mañana— y se comprueba que
-- ninguna, llamada como la llamaría el modelo, ejecute algo.
--
-- Que la prueba recorra el catálogo y no una lista escrita a mano es
-- deliberado: el día que alguien registre una herramienta nueva, esta
-- prueba la cubre sola.
-- =====================================================================
BEGIN;
SELECT plan(12);

-- --- Invariantes del catálogo ----------------------------------------
SELECT is((SELECT count(*)::int FROM ia_herramienta WHERE escribe AND permiso IS NULL), 0,
          'ninguna herramienta que escribe está sin permiso');
SELECT isnt_empty('SELECT 1 FROM ia_herramienta WHERE escribe AND activa',
                  'hay herramientas de escritura registradas (si no, la prueba no probaría nada)');

-- Toda herramienta que escribe tiene que tener un ejecutor en `ia_escribir`.
-- Una registrada sin rama se propondría, se confirmaría y moriría en el ELSE.
SELECT is((SELECT count(*)::int FROM ia_herramienta h
            WHERE h.escribe AND h.activa
              AND NOT EXISTS (SELECT 1 FROM pg_proc p
                               WHERE p.proname = 'ia_escribir'
                                 AND p.prosrc LIKE '%' || h.nombre || '%')), 0,
          'toda herramienta de escritura tiene ejecutor en ia_escribir');

-- --- Nada se ejecuta sin confirmar -----------------------------------
-- Se llama a todas como las llamaría el modelo. Los errores por
-- argumentos vacíos son un resultado válido para esta prueba: lo que NO
-- puede pasar es que alguna devuelva «hecho».
CREATE OR REPLACE FUNCTION pg_temp.llamar(p_nombre text) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  RETURN ia_llamar(prueba.superadmin(), 700100, prueba.sede(), p_nombre, '{}'::jsonb);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE TEMP TABLE antes AS
SELECT (SELECT count(*) FROM turno)                  AS turnos,
       (SELECT count(*) FROM consulta)               AS consultas,
       (SELECT count(*) FROM pago)                   AS pagos,
       (SELECT count(*) FROM descuento)              AS descuentos,
       (SELECT count(*) FROM movimiento_inventario)  AS movimientos,
       (SELECT count(*) FROM cuenta_linea)           AS lineas,
       (SELECT count(*) FROM paciente)               AS pacientes,
       (SELECT count(*) FROM tarea_async)            AS tareas;

CREATE TEMP TABLE resultados AS
SELECT h.nombre, pg_temp.llamar(h.nombre) AS r
  FROM ia_herramienta h WHERE h.escribe AND h.activa;

SELECT is((SELECT count(*)::int FROM resultados
            WHERE (r->>'ok')::boolean IS TRUE
              AND COALESCE((r->>'requiere_confirmacion')::boolean, false) IS FALSE), 0,
          'ninguna herramienta de escritura devolvió una ejecución hecha');

SELECT is((SELECT count(*) FROM turno),                 (SELECT turnos FROM antes),
          'no se creó ningún turno');
SELECT is((SELECT count(*) FROM consulta),              (SELECT consultas FROM antes),
          'no se creó ninguna consulta');
SELECT is((SELECT count(*) FROM pago),                  (SELECT pagos FROM antes),
          'no se registró ningún pago');
SELECT is((SELECT count(*) FROM descuento),             (SELECT descuentos FROM antes),
          'no se aplicó ningún descuento');
SELECT is((SELECT count(*) FROM movimiento_inventario), (SELECT movimientos FROM antes),
          'no se movió el inventario');
SELECT is((SELECT count(*) FROM cuenta_linea),          (SELECT lineas FROM antes),
          'no se agregó ninguna línea a ninguna cuenta');
SELECT is((SELECT count(*) FROM tarea_async),           (SELECT tareas FROM antes),
          'no se encoló ningún envío');

-- --- La confirmación es de quien pidió, y una sola vez ---------------
CREATE TEMP TABLE prop AS
SELECT (ia_llamar(prueba.superadmin(), 700101, prueba.sede(), 'llamar_siguiente',
                  '{}'::jsonb)->>'accion_id')::uuid AS id;

SELECT is((ia_confirmar((SELECT id FROM prop), prueba.don_nadie())->>'mensaje'),
          'Esa confirmación no es tuya.',
          'la propuesta solo la confirma quien la pidió');

SELECT * FROM finish();
ROLLBACK;
