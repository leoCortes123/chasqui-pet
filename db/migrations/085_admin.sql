-- =====================================================================
-- Chasqui Pet — 085_admin.sql
-- Lo que el portal administra y el chat no (§11.2): catálogo y precios,
-- usuarios y permisos, configuración operativa, auditoría, libro de
-- movimientos y bandeja de tareas fallidas.
--
-- Todo lo que escribe exige permiso aquí dentro, no en el portal. El
-- portal comprueba permisos para decidir qué botones pinta —eso es
-- interfaz—, pero la puerta está en la función: una llamada directa a la
-- base con la sesión de otro no puede saltarse nada.
--
-- Nada de esto se expone en el bot. Editar quince precios o repartir
-- permisos por chat es exactamente lo que §1 manda llevar al portal.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Catálogo de medicamentos
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION catalogo_medicamentos(p_texto text DEFAULT NULL)
RETURNS TABLE (
  medicamento_id uuid, nombre_generico text, nombre_comercial text,
  principio_activo text, presentacion text, concentracion text,
  categoria text, unidad_base text, requiere_receta boolean,
  precio_venta numeric, stock_minimo numeric, disponible numeric,
  costo_ultimo numeric, activo boolean
)
LANGUAGE sql STABLE AS $$
  SELECT m.id, m.nombre_generico, m.nombre_comercial, m.principio_activo,
         m.presentacion, m.concentracion, m.categoria, m.unidad_base,
         m.requiere_receta, m.precio_venta, m.stock_minimo,
         COALESCE(s.disponible, 0),
         (SELECT l.costo_unitario FROM lote l
           WHERE l.medicamento_id = m.id AND l.costo_unitario > 0
           ORDER BY l.created_at DESC LIMIT 1),
         m.activo
    FROM medicamento m
    LEFT JOIN v_stock_medicamento s ON s.medicamento_id = m.id
   WHERE p_texto IS NULL OR normalizar(p_texto) = ''
      OR m.busqueda LIKE '%' || normalizar(p_texto) || '%'
      OR m.busqueda % normalizar(p_texto)
   ORDER BY m.activo DESC, m.nombre_generico;
$$;

-- Edición desde el portal. Sólo llegan los campos que cambiaron: lo que
-- no venga en el jsonb se queda como estaba, que es lo que espera quien
-- edita una fila de una tabla larga.
CREATE OR REPLACE FUNCTION editar_medicamento(
  p_actor_id uuid, p_medicamento_id uuid, p_campos jsonb, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_antes jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'inventario.catalogo');

  v_antes := medicamento_json(p_medicamento_id);
  IF v_antes IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese medicamento no existe.');
  END IF;

  IF (p_campos ? 'precio_venta') AND (p_campos->>'precio_venta')::numeric < 0 THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'El precio no puede ser negativo.');
  END IF;

  UPDATE medicamento
     SET nombre_generico  = COALESCE(NULLIF(trim(p_campos->>'nombre_generico'), ''), nombre_generico),
         nombre_comercial = COALESCE(NULLIF(trim(COALESCE(p_campos->>'nombre_comercial', nombre_comercial, '')), ''), nombre_comercial),
         principio_activo = COALESCE(p_campos->>'principio_activo', principio_activo),
         presentacion     = COALESCE(p_campos->>'presentacion', presentacion),
         concentracion    = COALESCE(p_campos->>'concentracion', concentracion),
         categoria        = COALESCE(p_campos->>'categoria', categoria),
         unidad_base      = COALESCE(NULLIF(p_campos->>'unidad_base', ''), unidad_base),
         requiere_receta  = COALESCE((p_campos->>'requiere_receta')::boolean, requiere_receta),
         precio_venta     = COALESCE((p_campos->>'precio_venta')::numeric, precio_venta),
         stock_minimo     = COALESCE((p_campos->>'stock_minimo')::numeric, stock_minimo),
         activo           = COALESCE((p_campos->>'activo')::boolean, activo)
   WHERE id = p_medicamento_id;

  -- El precio viejo queda en la auditoría: lo ya cobrado no se recalcula.
  PERFORM auditar('medicamento', p_medicamento_id::text, 'editar', p_actor_id, p_canal,
                  v_antes, medicamento_json(p_medicamento_id));

  RETURN jsonb_build_object('ok', true, 'medicamento', medicamento_json(p_medicamento_id));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ya existe otro medicamento con ese nombre.');
END;
$$;

-- ---------------------------------------------------------------------
-- Usuarios, roles y permisos
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION usuarios_listado()
RETURNS TABLE (usuario_id uuid, nombre text, telegram_user_id bigint,
               telefono text, roles text[], permisos_extra text[],
               activo boolean, ultimo_acceso timestamptz, sesiones bigint)
LANGUAGE sql STABLE AS $$
  SELECT u.id, u.nombre_completo, u.telegram_user_id, u.telefono,
         COALESCE(array_agg(DISTINCT ur.rol_codigo)
                  FILTER (WHERE ur.rol_codigo IS NOT NULL), '{}'),
         COALESCE(array_agg(DISTINCT up.permiso_codigo)
                  FILTER (WHERE up.otorgado), '{}'),
         u.activo, u.ultimo_acceso_at,
         (SELECT count(*) FROM sesion s
           WHERE s.usuario_id = u.id AND NOT s.revocada AND s.expires_at > now())
    FROM usuario u
    LEFT JOIN usuario_rol ur ON ur.usuario_id = u.id
    LEFT JOIN usuario_permiso up ON up.usuario_id = u.id
   GROUP BY u.id
   ORDER BY u.activo DESC, u.nombre_completo;
$$;

CREATE OR REPLACE FUNCTION roles_disponibles()
RETURNS TABLE (codigo text, nombre text, descripcion text, nivel int, permisos bigint)
LANGUAGE sql STABLE AS $$
  SELECT r.codigo, r.nombre, r.descripcion, r.nivel,
         (SELECT count(*) FROM rol_permiso rp WHERE rp.rol_codigo = r.codigo)
    FROM rol r ORDER BY r.nivel DESC;
$$;

CREATE OR REPLACE FUNCTION permisos_disponibles()
RETURNS TABLE (codigo text, modulo text, descripcion text, roles text[])
LANGUAGE sql STABLE AS $$
  SELECT p.codigo, p.modulo, p.descripcion,
         COALESCE(array_agg(rp.rol_codigo ORDER BY rp.rol_codigo)
                  FILTER (WHERE rp.rol_codigo IS NOT NULL), '{}')
    FROM permiso p
    LEFT JOIN rol_permiso rp ON rp.permiso_codigo = p.codigo
   GROUP BY p.codigo, p.modulo, p.descripcion
   ORDER BY p.modulo, p.codigo;
$$;

CREATE OR REPLACE FUNCTION asignar_roles(
  p_actor_id uuid, p_usuario_id uuid, p_roles text[], p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_antes text[]; v_rol text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');

  IF p_roles IS NULL OR array_length(p_roles, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Cada persona necesita al menos un rol.');
  END IF;

  -- El superadmin sólo lo reparte un superadmin, y nadie se quita el
  -- suyo: quedarse sin superadmin deja el sistema sin quien lo arregle.
  IF 'superadmin' = ANY (p_roles)
     AND NOT EXISTS (SELECT 1 FROM usuario_rol
                      WHERE usuario_id = p_actor_id AND rol_codigo = 'superadmin') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'Sólo un superadmin puede otorgar el rol de superadmin.');
  END IF;

  IF p_actor_id = p_usuario_id AND NOT ('superadmin' = ANY (p_roles))
     AND EXISTS (SELECT 1 FROM usuario_rol
                  WHERE usuario_id = p_actor_id AND rol_codigo = 'superadmin') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'No puedes quitarte a ti mismo el rol de superadmin.');
  END IF;

  SELECT array_agg(rol_codigo ORDER BY rol_codigo) INTO v_antes
    FROM usuario_rol WHERE usuario_id = p_usuario_id;

  DELETE FROM usuario_rol WHERE usuario_id = p_usuario_id AND NOT (rol_codigo = ANY (p_roles));

  FOREACH v_rol IN ARRAY p_roles LOOP
    INSERT INTO usuario_rol (usuario_id, rol_codigo, asignado_por)
    VALUES (p_usuario_id, v_rol, p_actor_id)
    ON CONFLICT DO NOTHING;
  END LOOP;

  PERFORM auditar('usuario', p_usuario_id::text, 'asignar_roles', p_actor_id, p_canal,
                  jsonb_build_object('roles', to_jsonb(v_antes)),
                  jsonb_build_object('roles', to_jsonb(p_roles)));

  RETURN jsonb_build_object('ok', true, 'roles', to_jsonb(p_roles));
END;
$$;

-- La excepción individual de §4: el auxiliar al que el admin le habilita
-- descuentos o entradas de inventario, sin inventar un rol nuevo.
CREATE OR REPLACE FUNCTION ajustar_permiso_usuario(
  p_actor_id uuid, p_usuario_id uuid, p_permiso text,
  p_otorgado boolean, p_motivo text DEFAULT NULL, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');

  IF NOT EXISTS (SELECT 1 FROM permiso WHERE codigo = p_permiso) THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese permiso no existe.');
  END IF;

  INSERT INTO usuario_permiso (usuario_id, permiso_codigo, otorgado, motivo, asignado_por)
  VALUES (p_usuario_id, p_permiso, p_otorgado, NULLIF(trim(COALESCE(p_motivo,'')), ''), p_actor_id)
  ON CONFLICT (usuario_id, permiso_codigo) DO UPDATE
    SET otorgado = EXCLUDED.otorgado,
        motivo = EXCLUDED.motivo,
        asignado_por = EXCLUDED.asignado_por;

  PERFORM auditar('usuario', p_usuario_id::text,
                  CASE WHEN p_otorgado THEN 'otorgar_permiso' ELSE 'revocar_permiso' END,
                  p_actor_id, p_canal, NULL,
                  jsonb_build_object('permiso', p_permiso), p_motivo);

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Devuelve la excepción a lo que diga el rol: quitar la fila, no poner
-- otra que diga lo contrario.
CREATE OR REPLACE FUNCTION limpiar_permiso_usuario(
  p_actor_id uuid, p_usuario_id uuid, p_permiso text, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');

  DELETE FROM usuario_permiso
   WHERE usuario_id = p_usuario_id AND permiso_codigo = p_permiso;

  PERFORM auditar('usuario', p_usuario_id::text, 'limpiar_permiso', p_actor_id, p_canal,
                  NULL, jsonb_build_object('permiso', p_permiso));
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION reactivar_usuario(
  p_actor_id uuid, p_usuario_id uuid, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');
  UPDATE usuario SET activo = true WHERE id = p_usuario_id;
  PERFORM auditar('usuario', p_usuario_id::text, 'reactivar', p_actor_id, p_canal);
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------------------------------------------------------------------
-- Configuración operativa (§11.2)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION config_listado()
RETURNS TABLE (clave text, valor text, tipo text, descripcion text, editable boolean)
LANGUAGE sql STABLE AS $$
  SELECT clave, valor, tipo, descripcion, editable_ui
    FROM config ORDER BY editable_ui DESC, clave;
$$;

CREATE OR REPLACE FUNCTION guardar_config(
  p_actor_id uuid, p_clave text, p_valor text, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_tipo text; v_antes text; v_editable boolean;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'config.editar');

  SELECT tipo, valor, editable_ui INTO v_tipo, v_antes, v_editable
    FROM config WHERE clave = p_clave FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa clave de configuración no existe.');
  END IF;

  -- Lo no editable —la zona horaria, el símbolo de moneda— cambia el
  -- comportamiento de todo el sistema y no se toca desde una pantalla.
  IF NOT v_editable THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'Esa clave no se edita desde el portal.');
  END IF;

  IF v_tipo = 'entero' AND p_valor !~ '^-?[0-9]+$' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese valor tiene que ser un número entero.');
  END IF;
  IF v_tipo = 'booleano' AND lower(p_valor) NOT IN ('true','false') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese valor tiene que ser verdadero o falso.');
  END IF;

  UPDATE config SET valor = p_valor WHERE clave = p_clave;

  PERFORM auditar('config', p_clave, 'editar', p_actor_id, p_canal,
                  jsonb_build_object('valor', v_antes),
                  jsonb_build_object('valor', p_valor));

  RETURN jsonb_build_object('ok', true, 'clave', p_clave, 'valor', p_valor);
END;
$$;

-- Tarifas: lo que cobra la clínica. Se edita aquí y el bot lo ofrece sin
-- desplegar nada.
CREATE OR REPLACE FUNCTION guardar_tarifa(
  p_actor_id uuid, p_tarifa_id uuid, p_campos jsonb, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := p_tarifa_id;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'config.editar');

  IF v_id IS NULL THEN
    INSERT INTO tarifa (codigo, nombre, valor_sugerido, permite_valor_libre,
                        tipo_servicio_id, orden)
    VALUES (COALESCE(NULLIF(trim(p_campos->>'codigo'), ''),
                     normalizar(p_campos->>'nombre')),
            trim(p_campos->>'nombre'),
            COALESCE((p_campos->>'valor_sugerido')::numeric, 0),
            COALESCE((p_campos->>'permite_valor_libre')::boolean, false),
            NULLIF(p_campos->>'tipo_servicio_id', '')::uuid,
            COALESCE((p_campos->>'orden')::int, 99))
    RETURNING id INTO v_id;
  ELSE
    UPDATE tarifa
       SET nombre              = COALESCE(NULLIF(trim(p_campos->>'nombre'), ''), nombre),
           valor_sugerido      = COALESCE((p_campos->>'valor_sugerido')::numeric, valor_sugerido),
           permite_valor_libre = COALESCE((p_campos->>'permite_valor_libre')::boolean, permite_valor_libre),
           tipo_servicio_id    = COALESCE(NULLIF(p_campos->>'tipo_servicio_id', '')::uuid, tipo_servicio_id),
           orden               = COALESCE((p_campos->>'orden')::int, orden),
           activa              = COALESCE((p_campos->>'activa')::boolean, activa)
     WHERE id = v_id;
  END IF;

  PERFORM auditar('tarifa', v_id::text, CASE WHEN p_tarifa_id IS NULL THEN 'crear' ELSE 'editar' END,
                  p_actor_id, p_canal, NULL, p_campos);

  RETURN jsonb_build_object('ok', true, 'tarifa_id', v_id);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ya existe una tarifa con ese código.');
END;
$$;

CREATE OR REPLACE FUNCTION tarifas_listado()
RETURNS TABLE (tarifa_id uuid, codigo text, nombre text, tipo_servicio text,
               valor_sugerido numeric, permite_valor_libre boolean,
               activa boolean, orden int, usos bigint)
LANGUAGE sql STABLE AS $$
  SELECT t.id, t.codigo, t.nombre, ts.nombre, t.valor_sugerido,
         t.permite_valor_libre, t.activa, t.orden,
         (SELECT count(*) FROM cuenta_linea cl WHERE cl.referencia_id = t.id)
    FROM tarifa t
    LEFT JOIN tipo_servicio ts ON ts.id = t.tipo_servicio_id
   ORDER BY t.activa DESC, t.orden, t.nombre;
$$;

CREATE OR REPLACE FUNCTION guardar_consultorio(
  p_actor_id uuid, p_consultorio_id uuid, p_nombre text,
  p_orden int DEFAULT NULL, p_activo boolean DEFAULT NULL,
  p_sede_id uuid DEFAULT NULL, p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := p_consultorio_id;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'config.editar');

  IF v_id IS NULL THEN
    INSERT INTO consultorio (sede_id, nombre, orden)
    VALUES (COALESCE(p_sede_id, (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1)),
            trim(p_nombre), COALESCE(p_orden, 99))
    RETURNING id INTO v_id;
  ELSE
    UPDATE consultorio
       SET nombre = COALESCE(NULLIF(trim(p_nombre), ''), nombre),
           orden  = COALESCE(p_orden, orden),
           activo = COALESCE(p_activo, activo)
     WHERE id = v_id;
  END IF;

  PERFORM auditar('consultorio', v_id::text, 'guardar', p_actor_id, p_canal);
  RETURN jsonb_build_object('ok', true, 'consultorio_id', v_id);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ya hay un consultorio con ese nombre.');
END;
$$;

-- ---------------------------------------------------------------------
-- Auditoría y libro de movimientos (§11.2)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria_listado(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_entidad text DEFAULT NULL, p_usuario_id uuid DEFAULT NULL,
  p_limite int DEFAULT 200
)
RETURNS TABLE (id bigint, cuando timestamptz, entidad text, entidad_id text,
               accion text, usuario text, canal text, detalle text,
               antes jsonb, despues jsonb)
LANGUAGE sql STABLE AS $$
  SELECT e.id, e.created_at, e.entidad, e.entidad_id, e.accion,
         COALESCE(u.nombre_completo, '—'), e.canal, e.detalle,
         e.datos_antes, e.datos_despues
    FROM evento_auditoria e
    LEFT JOIN usuario u ON u.id = e.usuario_id
   WHERE (e.created_at AT TIME ZONE 'America/Bogota')::date
         BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
     AND (p_entidad IS NULL OR p_entidad = '' OR e.entidad = p_entidad)
     AND (p_usuario_id IS NULL OR e.usuario_id = p_usuario_id)
   ORDER BY e.created_at DESC
   LIMIT GREATEST(p_limite, 1);
$$;

CREATE OR REPLACE FUNCTION auditoria_entidades()
RETURNS TABLE (entidad text, eventos bigint)
LANGUAGE sql STABLE AS $$
  SELECT entidad, count(*) FROM evento_auditoria
   GROUP BY entidad ORDER BY count(*) DESC;
$$;

-- El libro de movimientos: la vista contable del inventario. Cada fila
-- es una fila real de `movimiento_inventario`, sin agregar nada, porque
-- de eso se trata el libro.
CREATE OR REPLACE FUNCTION libro_movimientos(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_medicamento_id uuid DEFAULT NULL, p_tipo text DEFAULT NULL,
  p_limite int DEFAULT 500
)
RETURNS TABLE (id bigint, cuando timestamptz, tipo text, medicamento text,
               lote text, cantidad numeric, unidad text, signo int,
               valor numeric, costo numeric, paciente text, turno text,
               usuario text, canal text, motivo text)
LANGUAGE sql STABLE AS $$
  SELECT mi.id, mi.created_at, nombre_tipo_movimiento(mi.tipo),
         m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', ''),
         l.numero_lote, mi.cantidad, m.unidad_base, signo_movimiento(mi.tipo),
         round(mi.cantidad * m.precio_venta, 2),
         round(mi.cantidad * l.costo_unitario, 2),
         pa.nombre, t.codigo,
         COALESCE(u.nombre_completo, '—'), mi.canal, mi.motivo
    FROM movimiento_inventario mi
    JOIN lote l ON l.id = mi.lote_id
    JOIN medicamento m ON m.id = mi.medicamento_id
    LEFT JOIN paciente pa ON pa.id = mi.paciente_id
    LEFT JOIN turno t ON t.id = mi.turno_id
    LEFT JOIN usuario u ON u.id = mi.usuario_id
   WHERE (mi.created_at AT TIME ZONE 'America/Bogota')::date
         BETWEEN rango_desde(p_desde) AND rango_hasta(p_hasta)
     AND (p_medicamento_id IS NULL OR mi.medicamento_id = p_medicamento_id)
     AND (p_tipo IS NULL OR p_tipo = '' OR mi.tipo = p_tipo)
   ORDER BY mi.created_at DESC, mi.id DESC
   LIMIT GREATEST(p_limite, 1);
$$;

-- ---------------------------------------------------------------------
-- Bandeja de tareas fallidas (§2.2.4)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tareas_listado(p_estado text DEFAULT 'fallida', p_limite int DEFAULT 100)
RETURNS TABLE (id bigint, tipo text, estado text, intentos int, max_intentos int,
               proxima_ejecucion timestamptz, ultimo_error text,
               payload jsonb, created_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT t.id, t.tipo, t.estado, t.intentos, t.max_intentos,
         t.proxima_ejecucion, t.ultimo_error, t.payload, t.created_at
    FROM tarea_async t
   WHERE p_estado IS NULL OR p_estado = '' OR t.estado = p_estado
   ORDER BY t.created_at DESC
   LIMIT GREATEST(p_limite, 1);
$$;

CREATE OR REPLACE FUNCTION resumen_tareas()
RETURNS TABLE (estado text, tareas bigint, mas_antigua timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT estado, count(*), min(created_at) FROM tarea_async
   GROUP BY estado ORDER BY count(*) DESC;
$$;

-- Reintentar es devolver la tarea a la cola con el contador a cero. No se
-- edita el payload: si estaba mal, la tarea se descarta y el hecho se
-- vuelve a provocar desde donde salió.
CREATE OR REPLACE FUNCTION reintentar_tarea(p_actor_id uuid, p_tarea_id bigint)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'sistema.operar');

  SELECT estado INTO v_estado FROM tarea_async WHERE id = p_tarea_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa tarea ya no está.');
  END IF;
  IF v_estado = 'procesando' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'Esa tarea la tiene un worker ahora mismo.');
  END IF;

  UPDATE tarea_async
     SET estado = 'pendiente', intentos = 0, proxima_ejecucion = now(), ultimo_error = NULL
   WHERE id = p_tarea_id;

  PERFORM auditar('tarea_async', p_tarea_id::text, 'reintentar', p_actor_id, 'web');
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION descartar_tarea(
  p_actor_id uuid, p_tarea_id bigint, p_motivo text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'sistema.operar');

  UPDATE tarea_async
     SET estado = 'completada', completada_at = now(),
         resultado = jsonb_build_object('descartada', true, 'motivo', p_motivo)
   WHERE id = p_tarea_id AND estado <> 'procesando';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'No se pudo descartar esa tarea.');
  END IF;

  PERFORM auditar('tarea_async', p_tarea_id::text, 'descartar', p_actor_id, 'web',
                  NULL, NULL, p_motivo);
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------------------------------------------------------------------
-- Salud del sistema, para el /health del portal y la vista de operación
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION salud_sistema()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'hora', now(),
    'fecha_operativa', hoy_bogota(),
    'tareas', jsonb_build_object(
      'pendientes',  (SELECT count(*) FROM tarea_async WHERE estado = 'pendiente'),
      'procesando',  (SELECT count(*) FROM tarea_async WHERE estado = 'procesando'),
      'fallidas',    (SELECT count(*) FROM tarea_async WHERE estado = 'fallida'),
      -- Una tarea pendiente muy vieja significa que el worker no está
      -- corriendo, aunque el contenedor diga que sí.
      'atraso_seg',  COALESCE((SELECT round(extract(epoch FROM (now() - min(proxima_ejecucion))))
                                 FROM tarea_async
                                WHERE estado = 'pendiente' AND proxima_ejecucion < now()), 0)),
    'telegram', jsonb_build_object(
      'ultimo_update', (SELECT max(recibido_at) FROM telegram_update),
      'sin_procesar',  (SELECT count(*) FROM telegram_update
                         WHERE NOT procesado AND recibido_at > now() - interval '1 day')),
    'sesiones_activas', (SELECT count(*) FROM sesion
                          WHERE NOT revocada AND expires_at > now()),
    'caja_abierta', (SELECT count(*) FROM cierre_caja WHERE estado = 'abierto'));
$$;
