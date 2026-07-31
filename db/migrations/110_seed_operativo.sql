-- =====================================================================
-- Chasqui Pet — 110_seed_operativo.sql
-- Configuración, sede, consultorios, tipos de servicio y superadmin.
-- =====================================================================

SET client_min_messages = warning;

INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('timeout_llamado_seg',    '180', 'entero',  'Segundos que espera un turno llamado antes de sugerir marcarlo ausente', true),
  ('max_reencolados',        '1',   'entero',  'Veces que un turno ausente puede volver a la cola', true),
  ('duracion_atencion_min',  '15',  'entero',  'Duración promedio de atención, para estimar la espera', true),
  ('prioridad_urgencia',     '100', 'entero',  'Prioridad que se asigna al marcar un turno como urgencia', true),
  ('rate_limit_turno_seg',   '60',  'entero',  'Segundos entre solicitudes de turno del mismo chat de Telegram', true),
  ('aviso_faltan_turnos',    '2',   'entero',  'A cuántos turnos de distancia se avisa al dueño por Telegram', true),
  ('alerta_vencimiento_dias','30',  'entero',  'Días de anticipación para la primera alerta de vencimiento de lote', true),
  ('alerta_vencimiento_dias_critico','7','entero','Días para la alerta crítica de vencimiento', true),
  ('cantidades_frecuentes',  '1,2,3,5,10', 'texto', 'Cantidades que el bot ofrece como botones al dar salida a un medicamento', true),
  ('cantidades_entrada',     '10,20,50,100', 'texto', 'Cantidades que el bot ofrece como botones al registrar una entrada de compra', true),
  ('moneda_simbolo',         '$',   'texto',   'Símbolo de moneda en mensajes y recibos', false),
  ('zona_horaria',           'America/Bogota', 'texto', 'Zona horaria operativa de la clínica', false),
  ('nombre_clinica',         'Chasqui Pet',    'texto', 'Nombre que aparece en mensajes del bot y recibos', true),
  ('politica_datos_url',     '',    'texto',   'URL de la política de tratamiento de datos (Ley 1581 de 2012)', true),
  ('recibo_leyenda',         'Documento interno de la clínica. No es factura electrónica.',
                                    'texto',   'Leyenda al pie del recibo. El MVP no emite factura electrónica DIAN (§7.4)', true)
ON CONFLICT (clave) DO NOTHING;

-- Tipos de servicio con sus prefijos de turno (§5.2).
INSERT INTO tipo_servicio (codigo, nombre, prefijo, prioridad_base, duracion_estimada_min, visible_qr, orden) VALUES
  ('general',    'Consulta general',    'A', 0,   15, true,  1),
  ('vacunacion', 'Vacunación',          'V', 0,   10, true,  2),
  ('control',    'Control / curación',  'C', 0,   10, true,  3),
  ('urgencia',   'Urgencia',            'U', 100, 30, false, 4)   -- nunca por QR
ON CONFLICT (codigo) DO NOTHING;

-- Tarifas iniciales (§7.1). Los valores son de arranque y se ajustan desde
-- el portal: lo que importa aquí es que el bot tenga qué ofrecer el primer
-- día. `permite_valor_libre` marca lo que se cobra por peso, por dosis o
-- por acuerdo, donde el bot pregunta el valor en vez de suponerlo.
INSERT INTO tarifa (codigo, tipo_servicio_id, nombre, valor_sugerido, permite_valor_libre, orden)
SELECT v.codigo, ts.id, v.nombre, v.valor, v.libre, v.orden
  FROM (VALUES
    ('consulta_general', 'general',    'Consulta general',        60000, false, 1),
    ('consulta_urgencia','urgencia',   'Consulta de urgencia',    90000, false, 2),
    ('control',          'control',    'Control / curación',      30000, false, 3),
    ('vacuna',           'vacunacion', 'Aplicación de vacuna',    25000, false, 4),
    ('desparasitacion',  NULL,         'Desparasitación',             0,  true, 5),
    ('procedimiento',    NULL,         'Procedimiento menor',         0,  true, 6),
    ('certificado',      NULL,         'Certificado de salud',    40000, false, 7),
    ('otro',             NULL,         'Otro cobro',                  0,  true, 9)
  ) AS v(codigo, tipo_codigo, nombre, valor, libre, orden)
  LEFT JOIN tipo_servicio ts ON ts.codigo = v.tipo_codigo
ON CONFLICT (codigo) DO NOTHING;

-- Sede y consultorios iniciales. El nombre real se ajusta desde el portal.
INSERT INTO sede (nombre, ciudad, direccion)
SELECT 'Sede principal', 'Bogotá', NULL
WHERE NOT EXISTS (SELECT 1 FROM sede);

INSERT INTO consultorio (sede_id, nombre, orden)
SELECT s.id, v.nombre, v.orden
  FROM sede s
  CROSS JOIN (VALUES ('Consultorio 1', 1), ('Consultorio 2', 2)) AS v(nombre, orden)
 WHERE s.nombre = 'Sede principal'
ON CONFLICT (sede_id, nombre) DO NOTHING;

-- ---------------------------------------------------------------------
-- Superadmin inicial (§4). El telegram_user_id llega por variable de
-- entorno; docker-entrypoint la expone como setting de sesión.
-- Si no está definida, el sistema queda sin superadmin y hay que crearlo
-- con: SELECT crear_superadmin_inicial(<telegram_user_id>, '<nombre>');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_superadmin_inicial(
  p_telegram_user_id bigint,
  p_nombre text DEFAULT 'Superadministrador'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  IF p_telegram_user_id IS NULL OR p_telegram_user_id = 0 THEN
    RAISE NOTICE 'Sin SUPERADMIN_TELEGRAM_USER_ID: no se creó el superadmin inicial.';
    RETURN NULL;
  END IF;

  SELECT id INTO v_id FROM usuario WHERE telegram_user_id = p_telegram_user_id;

  IF v_id IS NULL THEN
    INSERT INTO usuario (telegram_user_id, nombre_completo, sede_id)
    VALUES (p_telegram_user_id, p_nombre,
            (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1))
    RETURNING id INTO v_id;
  END IF;

  INSERT INTO usuario_rol (usuario_id, rol_codigo) VALUES (v_id, 'superadmin')
  ON CONFLICT DO NOTHING;

  PERFORM auditar('usuario', v_id::text, 'seed_superadmin', v_id, 'sistema');
  RETURN v_id;
END;
$$;

-- La invocación con el ID real vive en 900_superadmin.sh, que lee la
-- variable de entorno SUPERADMIN_TELEGRAM_USER_ID del contenedor.
