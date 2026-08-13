-- =====================================================================
-- Chasqui Pet — 130_ia_purga.sql
-- Ámbito: NÚCLEO (convención de cabecera, Fase A7a).
--
-- Fase A3 del plan de consolidación: las propuestas del asistente que
-- nadie confirma ni cancela se quedan `pendiente` para siempre.
--
-- Por qué existía el goteo: la expiración de `ia_accion_pendiente` es
-- perezosa. `ia_confirmar` (078:1020-1024) marca `expirada` solo si
-- alguien toca el botón tarde; si nadie lo toca —el caso normal cuando
-- el modelo propuso tres escrituras y el bot solo mostró una tarjeta—
-- la fila se queda pendiente, con `expira_at` vencido hace semanas.
-- `mantenimiento_diario()` (088) no tocaba esta tabla.
--
-- Dos remedios, y el orden importa:
--   · el de origen está en el worker (`chasqui_responder.js`): una vez
--     que hay una propuesta en el turno, las siguientes llamadas de
--     herramienta ya no llegan a `ia_llamar`, así que la basura no se
--     crea. Eso es lo que arregla el problema.
--   · este archivo es la red: limpia lo que YA se acumuló (hay filas de
--     agosto de 2026 en la base viva) y cubre cualquier otro camino que
--     deje una propuesta sin resolver —un worker que muere entre el
--     INSERT y el envío de la tarjeta, por ejemplo—.
--
-- Qué NO se hace aquí: tocar `evento_auditoria`. La confirmación se
-- audita en `ia_accion_pendiente/<id>/confirmar` (078:1039) y esa huella
-- se queda. Lo que se purga es la propuesta, no el registro de que
-- alguien la aprobó.
-- =====================================================================

SET client_min_messages = warning;

-- Retención de las propuestas ya resueltas. El mismo criterio que usan
-- las tareas de la cola: pasadas unas semanas no le sirven a nadie y la
-- huella de lo que sí se ejecutó vive en la auditoría.
INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('retencion_ia_acciones_dias', '30', 'entero',
   'Días que se conservan las propuestas ya resueltas del asistente (confirmadas, canceladas o expiradas)', true)
ON CONFLICT (clave) DO NOTHING;

-- ---------------------------------------------------------------------
-- ia_purgar_pendientes — cierra las vencidas y borra las viejas.
--
-- Dos pasos deliberadamente distintos:
--   1. las `pendiente` con `expira_at` vencido pasan a `expirada`. No se
--      borran en el mismo paso: quedan visibles un tiempo para que se
--      pueda ver que existieron, y las barre el paso 2 cuando les toque.
--   2. las ya resueltas —confirmadas, canceladas o expiradas— más viejas
--      que la retención se borran.
--
-- Nunca borra una fila que siga `pendiente`: si su plazo no venció,
-- todavía puede confirmarse.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_purgar_pendientes()
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_expiradas int;
  v_purgadas  int;
BEGIN
  UPDATE ia_accion_pendiente
     SET estado = 'expirada', resuelta_at = now()
   WHERE estado = 'pendiente'
     AND expira_at < now();
  GET DIAGNOSTICS v_expiradas = ROW_COUNT;

  DELETE FROM ia_accion_pendiente
   WHERE estado <> 'pendiente'
     AND COALESCE(resuelta_at, created_at)
         < now() - make_interval(days => config_int('retencion_ia_acciones_dias', 30));
  GET DIAGNOSTICS v_purgadas = ROW_COUNT;

  RETURN jsonb_build_object('expiradas', v_expiradas, 'purgadas', v_purgadas);
END;
$$;

-- ---------------------------------------------------------------------
-- Enganche en la limpieza diaria.
--
-- Cambio ADITIVO: el cuerpo es el de 088_mantenimiento.sql palabra por
-- palabra, más el bloque del asistente y dos claves en el resultado. Se
-- repite entero porque no hay otra forma de extender una función en
-- Postgres, y quien compare las dos versiones tiene que poder ver que no
-- se perdió nada.
--
-- `SECURITY DEFINER` va explícito: `CREATE OR REPLACE` no conserva esa
-- propiedad, y 090_grants.sql la había puesto con un ALTER porque la
-- purga borra de `telegram_update`, tabla sobre la que la aplicación no
-- tiene DELETE. Omitirla aquí habría roto la limpieza diaria en silencio.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mantenimiento_diario()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER AS $$
DECLARE
  v_updates int;
  v_estados int;
  v_challenges int;
  v_tareas int;
  v_sesiones int;
  v_ia jsonb;
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

  -- Propuestas del asistente que nadie resolvió (Fase A3).
  v_ia := ia_purgar_pendientes();

  RETURN jsonb_build_object(
    'fecha', hoy_bogota(),
    'updates_purgados', v_updates,
    'conversaciones_purgadas', v_estados,
    'challenges_purgados', v_challenges,
    'tareas_purgadas', v_tareas,
    'sesiones_vencidas', v_sesiones,
    'ia_acciones_expiradas', v_ia->'expiradas',
    'ia_acciones_purgadas', v_ia->'purgadas');
END;
$$;
