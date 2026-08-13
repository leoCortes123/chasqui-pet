-- =====================================================================
-- Chasqui Pet — 210_ia_metricas.sql
-- Ámbito: VERTICAL (convención de cabecera, Fase A7a).
--
-- Fase B5 del plan de consolidación —la Fase 6 del asistente, la última
-- que quedaba sin empezar—: preguntarle a Chasqui por los números.
--
-- Por qué VERTICAL aunque una de las tres métricas no lo sea: dos de
-- ellas hablan el vocabulario del vertical veterinario (turnos,
-- consultorios, consultas firmadas, veterinarios) y el día que aparezca
-- otro rubro hay que rehacerlas. `analizar_rentabilidad_lotes` es de
-- inventario y sobreviviría tal cual, pero la cabecera declara UN ámbito
-- y el que hay que poder responder es «qué se rehace»: dos de tres.
--
-- Lo que NO se hace aquí, a propósito:
--
--   · No se escribe ni un reporte nuevo. `080_reportes.sql` ya trae
--     `reporte_turnos`, `reporte_turnos_hora`,
--     `reporte_ocupacion_consultorio`, `reporte_consultas` y
--     `reporte_margen`, todos `STABLE`, todos con el mismo rango
--     (desde, hasta) y NULL = mes en curso. Estas tres operaciones los
--     juntan y los empaquetan en jsonb; no recalculan nada.
--   · No se toca el portal. Los mismos números ya se ven y se exportan
--     a CSV por `web/src/app/api/reportes/`. Aquí solo se abre la puerta
--     del chat.
--   · No se agrega ninguna escritura. Las tres son de lectura pura, así
--     que no pasan por `ia_accion_pendiente` ni por confirmación: no hay
--     nada que confirmar.
--
-- La única excepción de diseño respecto a los otros trece `op_` de
-- lectura: estas tres SÍ llaman a `exigir_permiso`. Los reportes de 080
-- deliberadamente no lo hacen —«el mismo dato se sirve por chat y por
-- web y el control tiene que estar en un solo sitio»—, y ese sitio, para
-- el chat, es `ia_llamar` mirando `ia_herramienta.permiso`. Se agrega la
-- segunda reja aquí porque lo que exponen es el margen del negocio y el
-- rendimiento de cada médico: es lo más sensible del catálogo de lectura
-- y no se quiere que dependa de una sola fila de configuración.
-- =====================================================================

SET client_min_messages = warning;


-- ---------------------------------------------------------------------
-- 1. El rango, como lo dice una persona
--
-- Por chat nadie escribe «desde 2026-08-01 hasta 2026-08-13»: dice «este
-- mes» (que es el defecto de los reportes) o «los últimos 30 días». El
-- atajo `dias` es para lo segundo, y convive con `desde`/`hasta`
-- explícitos, que mandan si vienen.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_metrica_desde(p_args jsonb)
RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(p_args->>'desde', '')::date,
    CASE WHEN NULLIF(p_args->>'dias', '') IS NOT NULL
         THEN hoy_bogota() - GREATEST((p_args->>'dias')::int, 0)
    END,
    rango_desde(NULL));
$$;

CREATE OR REPLACE FUNCTION ia_metrica_hasta(p_args jsonb)
RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(p_args->>'hasta', '')::date, hoy_bogota());
$$;

-- El rango que se le devuelve al modelo junto con los datos. Sin esto,
-- una cifra sin período es una cifra que se malinterpreta: el modelo
-- diría «se atendieron 120» sin decir de cuándo.
CREATE OR REPLACE FUNCTION ia_metrica_rango(p_args jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'desde', ia_metrica_desde(p_args),
    'hasta', ia_metrica_hasta(p_args),
    'dias', (ia_metrica_hasta(p_args) - ia_metrica_desde(p_args)) + 1);
$$;


-- ---------------------------------------------------------------------
-- 2. Ocupación: a qué hora hace falta gente
--
-- Junta las tres miradas del mismo período: por día (¿está subiendo?),
-- por hora (¿a qué hora se llena?) y por consultorio (¿quién atendió y
-- cuánto estuvo abierto?).
--
-- Sobre los promedios de espera: los de `reporte_turnos` son por día, y
-- el total se pondera por turnos emitidos en vez de promediar promedios
-- —un martes de 40 turnos no pesa lo mismo que un domingo de 3—. Es una
-- aproximación (la espera solo se mide sobre los turnos que llegaron a
-- llamarse), y por eso el resumen lo dice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION op_analizar_ocupacion(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_desde date := ia_metrica_desde(p_args);
  v_hasta date := ia_metrica_hasta(p_args);
  v_dia   jsonb;
  v_hora  jsonb;
  v_cons  jsonb;
  v_tot   jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor, 'reportes.operativos');

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.fecha DESC), '[]'::jsonb)
    INTO v_dia FROM reporte_turnos(v_desde, v_hasta) t;

  SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY h.hora), '[]'::jsonb)
    INTO v_hora FROM reporte_turnos_hora(v_desde, v_hasta) h;

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.atendidos DESC), '[]'::jsonb)
    INTO v_cons FROM reporte_ocupacion_consultorio(v_desde, v_hasta) c;

  SELECT jsonb_build_object(
           'emitidos',  COALESCE(sum(t.emitidos), 0),
           'atendidos', COALESCE(sum(t.atendidos), 0),
           'ausentes',  COALESCE(sum(t.ausentes), 0),
           'dias_con_atencion', count(*) FILTER (WHERE t.emitidos > 0),
           'espera_promedio_min',
             round(sum(t.espera_promedio_min * t.emitidos)
                   / NULLIF(sum(t.emitidos) FILTER (WHERE t.espera_promedio_min IS NOT NULL), 0), 1),
           'atencion_promedio_min',
             round(sum(t.atencion_promedio_min * t.atendidos)
                   / NULLIF(sum(t.atendidos) FILTER (WHERE t.atencion_promedio_min IS NOT NULL), 0), 1),
           'nota_promedios',
             'Los promedios se ponderan por turnos y solo cuentan los que llegaron a llamarse.')
    INTO v_tot FROM reporte_turnos(v_desde, v_hasta) t;

  RETURN jsonb_build_object('ok', true, 'datos', jsonb_build_object(
    'rango', ia_metrica_rango(p_args),
    'totales', v_tot,
    'hora_mas_ocupada', (SELECT h->>'hora' FROM jsonb_array_elements(v_hora) h
                          ORDER BY (h->>'emitidos')::bigint DESC LIMIT 1),
    'por_dia', v_dia,
    'por_hora', v_hora,
    'por_consultorio', v_cons));
END;
$$;


-- ---------------------------------------------------------------------
-- 3. Rendimiento por médico
--
-- Cruza lo clínico (`reporte_consultas`: firmadas, borradores sin cerrar,
-- pacientes distintos) con lo operativo (`reporte_ocupacion_consultorio`,
-- agregado por veterinario: cuántos atendió, cuánto duró cada atención,
-- cuántas horas tuvo consultorio abierto).
--
-- Los borradores sin firmar salen a propósito: es el número que dice si
-- alguien está dejando historias a medias, y es de lo poco que un
-- administrador no puede ver de otra forma sin abrir consulta por
-- consulta.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION op_analizar_rendimiento_medico(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_desde date := ia_metrica_desde(p_args);
  v_hasta date := ia_metrica_hasta(p_args);
  v_filas jsonb;
  v_tot   jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor, 'reportes.operativos');

  WITH turnos AS (
    SELECT o.veterinario,
           sum(o.atendidos) AS atendidos,
           round(sum(o.atencion_promedio_min * o.atendidos)
                 / NULLIF(sum(o.atendidos) FILTER (WHERE o.atencion_promedio_min IS NOT NULL), 0), 1)
             AS atencion_promedio_min,
           round(sum(o.horas_abierto), 1) AS horas_abierto
      FROM reporte_ocupacion_consultorio(v_desde, v_hasta) o
     GROUP BY o.veterinario
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'veterinario', c.veterinario,
           'consultas_firmadas', c.firmadas,
           'borradores_sin_firmar', c.borradores,
           'anuladas', c.anuladas,
           'con_remision', c.con_remision,
           'con_control_anotado', c.con_revision,
           'pacientes_distintos', c.pacientes,
           'turnos_atendidos', t.atendidos,
           'atencion_promedio_min', t.atencion_promedio_min,
           'horas_consultorio_abierto', t.horas_abierto)
           ORDER BY c.firmadas DESC), '[]'::jsonb)
    INTO v_filas
    FROM reporte_consultas(v_desde, v_hasta) c
    LEFT JOIN turnos t ON t.veterinario = c.veterinario;

  SELECT jsonb_build_object(
           'consultas_firmadas', COALESCE(sum(c.firmadas), 0),
           'borradores_sin_firmar', COALESCE(sum(c.borradores), 0),
           'medicos_con_actividad', count(*))
    INTO v_tot FROM reporte_consultas(v_desde, v_hasta) c;

  RETURN jsonb_build_object('ok', true, 'datos', jsonb_build_object(
    'rango', ia_metrica_rango(p_args),
    'totales', v_tot,
    'por_veterinario', v_filas));
END;
$$;


-- ---------------------------------------------------------------------
-- 4. Rentabilidad
--
-- `reporte_margen` ya responde «qué medicamento deja plata». Lo que no
-- existía —y lo pide el nombre de la herramienta— es el corte por LOTE:
-- dos lotes del mismo medicamento comprados con seis meses de diferencia
-- tienen costos distintos, y el margen real depende de cuál salió. El
-- dato estaba ahí (`movimiento_inventario.lote_id` + `lote.costo_unitario`,
-- que es lo mismo que ya usa `reporte_margen`); solo faltaba agruparlo
-- por lote en vez de por medicamento.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION op_analizar_rentabilidad_lotes(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_desde  date := ia_metrica_desde(p_args);
  v_hasta  date := ia_metrica_hasta(p_args);
  v_lim    int  := LEAST(GREATEST(COALESCE((p_args->>'limite')::int, 10), 1), 40);
  v_med    jsonb;
  v_lote   jsonb;
  v_tot    jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor, 'reportes.financieros');

  SELECT COALESCE(jsonb_agg(to_jsonb(m)), '[]'::jsonb) INTO v_med
    FROM (SELECT * FROM reporte_margen(v_desde, v_hasta) LIMIT v_lim) m;

  SELECT jsonb_build_object(
           'ingreso', COALESCE(sum(m.ingreso), 0),
           'costo',   COALESCE(sum(m.costo), 0),
           'margen',  COALESCE(sum(m.margen), 0),
           'margen_pct', round(100 * sum(m.margen) / NULLIF(sum(m.ingreso), 0), 1))
    INTO v_tot FROM reporte_margen(v_desde, v_hasta) m;

  SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_lote
    FROM (
      SELECT me.nombre_generico || COALESCE(' (' || me.nombre_comercial || ')', '')
               AS medicamento,
             l.numero_lote,
             l.fecha_vencimiento AS vence,
             sum(mi.cantidad) AS unidades,
             me.unidad_base AS unidad,
             round(sum(mi.cantidad * me.precio_venta), 2) AS ingreso,
             round(sum(mi.cantidad * l.costo_unitario), 2) AS costo,
             round(sum(mi.cantidad * (me.precio_venta - l.costo_unitario)), 2) AS margen,
             round(100 * sum(mi.cantidad * (me.precio_venta - l.costo_unitario))
                   / NULLIF(sum(mi.cantidad * me.precio_venta), 0), 1) AS margen_pct
        FROM movimiento_inventario mi
        JOIN lote l        ON l.id = mi.lote_id
        JOIN medicamento me ON me.id = mi.medicamento_id
       WHERE mi.tipo = 'salida'
         AND (mi.created_at AT TIME ZONE 'America/Bogota')::date BETWEEN v_desde AND v_hasta
       GROUP BY me.id, me.nombre_generico, me.nombre_comercial, me.unidad_base,
                l.id, l.numero_lote, l.fecha_vencimiento
       ORDER BY round(sum(mi.cantidad * (me.precio_venta - l.costo_unitario)), 2) DESC
       LIMIT v_lim) x;

  RETURN jsonb_build_object('ok', true, 'datos', jsonb_build_object(
    'rango', ia_metrica_rango(p_args),
    'totales', v_tot,
    'por_medicamento', v_med,
    'por_lote', v_lote,
    'nota', 'Solo cubre lo despachado de inventario. Los servicios cobrados van en ver_caja.'));
END;
$$;


-- ---------------------------------------------------------------------
-- 5. El catálogo
--
-- Las descripciones las lee el modelo, no una persona: dicen CUÁNDO usar
-- cada una, que es lo que decide si la llama en el momento correcto.
-- ---------------------------------------------------------------------
INSERT INTO ia_herramienta (nombre, permiso, escribe, critica, orden, descripcion, esquema) VALUES

('analizar_ocupacion', 'reportes.operativos', false, false, 140,
 'Cómo se ocupó la clínica en un período: turnos emitidos, atendidos y ausentes por día, '
 'la distribución por hora del día, cuánto esperó la gente y qué consultorio estuvo '
 'abierto y cuánto. Úsala para «a qué hora se llena», «cuánto están esperando», '
 '«cómo estuvo la semana», «necesitamos otro consultorio». Sin fechas, es el mes en curso.',
 '{"type":"object","properties":{"desde":{"type":"string","description":"Fecha inicial AAAA-MM-DD"},"hasta":{"type":"string","description":"Fecha final AAAA-MM-DD"},"dias":{"type":"integer","description":"Atajo: últimos N días hasta hoy. Ignora desde."}}}'::jsonb),

('analizar_rendimiento_medico', 'reportes.operativos', false, false, 141,
 'Actividad de cada veterinario en un período: consultas firmadas, borradores que dejó '
 'sin firmar, pacientes distintos, turnos atendidos, cuánto dura en promedio cada '
 'atención y cuántas horas tuvo el consultorio abierto. Úsala para «cómo va el equipo», '
 '«cuántas consultas lleva fulano», «quedan historias sin firmar». Sin fechas, el mes '
 'en curso. Son datos de gestión: preséntalos sin juzgar a nadie.',
 '{"type":"object","properties":{"desde":{"type":"string","description":"Fecha inicial AAAA-MM-DD"},"hasta":{"type":"string","description":"Fecha final AAAA-MM-DD"},"dias":{"type":"integer","description":"Atajo: últimos N días hasta hoy. Ignora desde."}}}'::jsonb),

('analizar_rentabilidad_lotes', 'reportes.financieros', false, false, 142,
 'Qué deja el inventario despachado en un período: ingreso, costo y margen, por '
 'medicamento y por lote (dos lotes del mismo medicamento pueden tener costos muy '
 'distintos). Úsala para «cuánto estamos ganando», «qué medicamento deja más», «ese '
 'lote nos costó caro». Solo cubre medicamentos despachados; los servicios cobrados '
 'están en ver_caja. Sin fechas, el mes en curso.',
 '{"type":"object","properties":{"desde":{"type":"string","description":"Fecha inicial AAAA-MM-DD"},"hasta":{"type":"string","description":"Fecha final AAAA-MM-DD"},"dias":{"type":"integer","description":"Atajo: últimos N días hasta hoy. Ignora desde."},"limite":{"type":"integer","description":"Cuántas filas por lista. Por defecto 10, máximo 40."}}}'::jsonb)

ON CONFLICT (nombre) DO NOTHING;

UPDATE ia_herramienta h
   SET funcion = r.funcion, funcion_borrador = NULL, modulo = r.modulo
  FROM (VALUES
    ('analizar_ocupacion',           'op_analizar_ocupacion',           'reportes'),
    ('analizar_rendimiento_medico',  'op_analizar_rendimiento_medico',  'reportes'),
    ('analizar_rentabilidad_lotes',  'op_analizar_rentabilidad_lotes',  'reportes')
  ) AS r(nombre, funcion, modulo)
 WHERE h.nombre = r.nombre;


-- ---------------------------------------------------------------------
-- 6. La bienvenida menciona los números
--
-- Reemplazo ADITIVO de la versión de 082:860. El cuerpo va entero y
-- palabra por palabra; se le suman dos ejemplos, cada uno tras su
-- permiso, porque una caja de texto vacía frente a un bot no le dice a
-- nadie que ahí se pueden pedir cifras.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_ia_bienvenida(p_usuario_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE v_ej text := '';
BEGIN
  IF tiene_permiso(p_usuario_id, 'turnos.ver') THEN
    v_ej := v_ej || E'\n' || '· «¿cómo va la cola?»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'inventario.ver') THEN
    v_ej := v_ej || E'\n' || '· «¿cuánta amoxicilina queda?»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'inventario.salida') THEN
    v_ej := v_ej || E'\n' || '· «despacha 2 amoxicilina y 1 metronidazol»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'cobro.ver') THEN
    v_ej := v_ej || E'\n' || '· «¿qué falta por cobrar hoy?»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'cobro.linea') THEN
    v_ej := v_ej || E'\n' || '· «cárgale a la cuenta de Luna la consulta y el antipulgas»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'cobro.descuento') THEN
    v_ej := v_ej || E'\n' || '· «aplícale un descuento del 10 % a la cuenta de Luna»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'pacientes.ver') THEN
    v_ej := v_ej || E'\n' || '· «tráeme la historia de Luna»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'consulta.crear') THEN
    v_ej := v_ej || E'\n' || '· «déjame el borrador de Luna: vómito, 4.2 kg, gastroenteritis»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'pacientes.editar') THEN
    v_ej := v_ej || E'\n' || '· «registra a Luna, gata de 2 años, dueña María Gómez»';
  END IF;
  -- Fase B5: los números también se preguntan hablando.
  IF tiene_permiso(p_usuario_id, 'reportes.operativos') THEN
    v_ej := v_ej || E'\n' || '· «¿a qué hora se llena la sala esta semana?»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'reportes.financieros') THEN
    v_ej := v_ej || E'\n' || '· «¿qué margen dejó el inventario este mes?»';
  END IF;

  RETURN '💬 <b>Habla con Chasqui</b>' || E'\n\n' ||
         'Escríbeme como le escribirías a un compañero. Consulto los datos reales de ' ||
         esc(config_txt('nombre_clinica', 'Chasqui Pet')) || ' y también te explico cómo ' ||
         'funciona algo de la clínica.' ||
         CASE WHEN v_ej <> '' THEN E'\n\n' || 'Por ejemplo:' || v_ej ELSE '' END ||
         E'\n\n' || 'Si te ayudo con algo que <b>cambia</b> datos —llamar un turno, sacar un ' ||
         'medicamento, registrar un pago— te muestro primero qué va a pasar y lo confirmas tú.' ||
         E'\n\n' || 'Para volver a los botones, escribe /menu.';
END;
$$;


-- ---------------------------------------------------------------------
-- 7. Permisos
--
-- No se crea ninguno: `reportes.operativos` y `reportes.financieros`
-- existen desde `075_prerrequisitos_ia.sql` y ya están repartidos en
-- `100_seed_roles.sql`. Quien ve los reportes en el portal es
-- exactamente quien los puede preguntar por chat, que es el punto.
-- ---------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION ia_metrica_desde(jsonb)                              TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_metrica_hasta(jsonb)                              TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_metrica_rango(jsonb)                              TO chasquipet_app;
GRANT EXECUTE ON FUNCTION op_analizar_ocupacion(uuid, uuid, jsonb)             TO chasquipet_app;
GRANT EXECUTE ON FUNCTION op_analizar_rendimiento_medico(uuid, uuid, jsonb)    TO chasquipet_app;
GRANT EXECUTE ON FUNCTION op_analizar_rentabilidad_lotes(uuid, uuid, jsonb)    TO chasquipet_app;
