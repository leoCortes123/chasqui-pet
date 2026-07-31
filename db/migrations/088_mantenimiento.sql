-- =====================================================================
-- Chasqui Pet — 088_mantenimiento.sql
-- La limpieza diaria (§13.7).
--
-- Tres tablas crecen para siempre si nadie las poda, y ninguna de las
-- tres aporta nada pasadas unas semanas:
--
--   · `telegram_update` guarda cada update recibido para descartar los
--     repetidos (§2.2.2). Telegram reintenta durante horas, no durante
--     meses: con una semana sobra, y el resto es peso muerto.
--   · `conversacion_estado` guarda conversaciones a medias, con su
--     propio `expira_at`. Lo vencido no lo lee nadie.
--   · `auth_challenge` guarda intentos de ingreso al portal, con TTL de
--     cinco minutos.
--
-- Lo que NO se purga nunca: `evento_auditoria` y `movimiento_inventario`.
-- Son el registro de lo que pasó y su valor está justamente en que nadie
-- —ni un job— pueda quitarles filas.
--
-- La función es SECURITY DEFINER (se marca en 090_grants.sql) porque la
-- aplicación no tiene DELETE sobre `telegram_update`: puede purgar a
-- través de esta puerta concreta y por ninguna otra.
-- =====================================================================

SET client_min_messages = warning;

INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('retencion_updates_dias', '7',  'entero',
   'Días que se conservan los updates de Telegram recibidos, para descartar repetidos', true),
  ('retencion_tareas_dias',  '30', 'entero',
   'Días que se conservan las tareas ya completadas de la cola', true)
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION mantenimiento_diario()
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_updates int;
  v_estados int;
  v_challenges int;
  v_tareas int;
  v_sesiones int;
BEGIN
  DELETE FROM telegram_update
   WHERE recibido_at < now() - make_interval(days => config_int('retencion_updates_dias', 7));
  GET DIAGNOSTICS v_updates = ROW_COUNT;

  DELETE FROM conversacion_estado WHERE expira_at < now() - interval '1 day';
  GET DIAGNOSTICS v_estados = ROW_COUNT;

  DELETE FROM auth_challenge WHERE expira_at < now() - interval '1 day';
  GET DIAGNOSTICS v_challenges = ROW_COUNT;

  DELETE FROM tarea_async
   WHERE estado = 'completada'
     AND completada_at < now() - make_interval(days => config_int('retencion_tareas_dias', 30));
  GET DIAGNOSTICS v_tareas = ROW_COUNT;

  -- Las sesiones vencidas se marcan revocadas, no se borran: la lista de
  -- «dónde estuvo abierta mi sesión» es justamente lo que hace útil la
  -- notificación de ingreso (§11.1).
  UPDATE sesion SET revocada = true, revocada_at = now()
   WHERE NOT revocada AND expires_at < now();
  GET DIAGNOSTICS v_sesiones = ROW_COUNT;

  RETURN jsonb_build_object(
    'fecha', hoy_bogota(),
    'updates_purgados', v_updates,
    'conversaciones_purgadas', v_estados,
    'challenges_purgados', v_challenges,
    'tareas_purgadas', v_tareas,
    'sesiones_vencidas', v_sesiones);
END;
$$;
