-- =====================================================================
-- Chasqui Pet — 100_seed_roles.sql
-- Roles y permisos como datos (§4). Cambiar quién puede hacer qué es un
-- UPDATE, no un despliegue.
-- =====================================================================

SET client_min_messages = warning;

INSERT INTO rol (codigo, nombre, descripcion, nivel, sistema) VALUES
  ('superadmin',  'Superadministrador', 'Acceso técnico total, configuración del sistema, auditoría y tareas fallidas.', 100, true),
  ('admin',       'Administrador',      'Administra la clínica: usuarios, catálogo, precios, proveedores, inventario, tarifas, caja y reportes.', 80, true),
  ('veterinario', 'Veterinario',        'Atiende turnos, crea y firma consultas, da salida a medicamentos vinculada a consulta.', 60, true),
  ('auxiliar',    'Auxiliar',           'Crea turnos, registra dueños y mascotas, recibe pagos y cierra caja.', 40, true),
  ('recepcion',   'Recepción',          'Ve la cola, crea turnos manuales y registra dueños y mascotas.', 20, true)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO permiso (codigo, modulo, descripcion) VALUES
  -- Turnos
  ('turnos.ver',            'turnos',     'Ver la cola y el estado de los turnos'),
  ('turnos.crear',          'turnos',     'Crear turnos manuales y reencolar ausentes'),
  ('turnos.llamar',         'turnos',     'Llamar siguiente, iniciar atención, marcar ausente y finalizar'),
  ('turnos.priorizar',      'turnos',     'Marcar urgencia y alterar la prioridad de la cola'),
  ('turnos.cancelar',       'turnos',     'Cancelar un turno'),
  ('consultorio.abrir',     'turnos',     'Abrir y cerrar sesión de consultorio'),
  -- Inventario
  ('inventario.ver',        'inventario', 'Consultar stock, lotes y vencimientos'),
  ('inventario.salida',     'inventario', 'Registrar salida de medicamento vinculada a una consulta'),
  ('inventario.entrada',    'inventario', 'Registrar y confirmar entradas de inventario'),
  ('inventario.ajuste',     'inventario', 'Ajustes positivos/negativos y bajas por vencimiento o daño'),
  ('inventario.catalogo',   'inventario', 'Crear y editar medicamentos y precios de venta'),
  -- Clínico
  ('pacientes.ver',         'clinico',    'Ver dueños, pacientes e historia clínica'),
  ('pacientes.editar',      'clinico',    'Crear y editar dueños y pacientes'),
  ('consulta.crear',        'clinico',    'Crear y editar consultas en borrador'),
  ('consulta.firmar',       'clinico',    'Firmar una consulta y volverla registro clínico válido'),
  -- Cobro
  ('cobro.ver',             'cobro',      'Ver cuentas y su detalle'),
  ('cobro.linea',           'cobro',      'Agregar o quitar líneas de una cuenta'),
  ('cobro.pago',            'cobro',      'Registrar pagos y cerrar cuentas'),
  ('cobro.descuento',       'cobro',      'Aplicar descuentos con motivo'),
  ('cobro.anular',          'cobro',      'Anular una cuenta ya cerrada'),
  ('caja.cerrar',           'cobro',      'Abrir y cerrar caja'),
  -- Proveedores
  ('proveedores.ver',       'compras',    'Consultar proveedores y compras'),
  ('proveedores.gestionar', 'compras',    'Crear y editar proveedores'),
  -- Reportes y administración
  ('reportes.operativos',   'reportes',   'Reportes de turnos, consultas, stock y pacientes'),
  ('reportes.financieros',  'reportes',   'Reportes de caja, margen, descuentos y compras'),
  ('usuarios.gestionar',    'admin',      'Crear usuarios, asignar roles y permisos'),
  ('config.editar',         'admin',      'Editar configuración operativa, consultorios, tarifas y tipos de servicio'),
  ('auditoria.ver',         'admin',      'Consultar la auditoría y el libro de movimientos'),
  ('sistema.operar',        'admin',      'Bandeja de tareas fallidas, backups y salud del sistema')
ON CONFLICT (codigo) DO NOTHING;

-- superadmin: todo.
INSERT INTO rol_permiso (rol_codigo, permiso_codigo)
SELECT 'superadmin', codigo FROM permiso
ON CONFLICT DO NOTHING;

-- admin: todo excepto la operación técnica del sistema.
INSERT INTO rol_permiso (rol_codigo, permiso_codigo)
SELECT 'admin', codigo FROM permiso WHERE codigo <> 'sistema.operar'
ON CONFLICT DO NOTHING;

-- veterinario: atiende y da salida a medicamentos. NO entradas ni ajustes,
-- NO recibe dinero (§4, separación de funciones).
INSERT INTO rol_permiso (rol_codigo, permiso_codigo) VALUES
  ('veterinario', 'turnos.ver'),
  ('veterinario', 'turnos.crear'),
  ('veterinario', 'turnos.llamar'),
  ('veterinario', 'turnos.priorizar'),
  ('veterinario', 'consultorio.abrir'),
  ('veterinario', 'inventario.ver'),
  ('veterinario', 'inventario.salida'),
  ('veterinario', 'pacientes.ver'),
  ('veterinario', 'pacientes.editar'),
  ('veterinario', 'consulta.crear'),
  ('veterinario', 'consulta.firmar'),
  ('veterinario', 'cobro.ver'),
  ('veterinario', 'cobro.linea'),
  ('veterinario', 'reportes.operativos')
ON CONFLICT DO NOTHING;

-- auxiliar: recibe el dinero y cierra caja. NO crea ni firma diagnósticos.
-- 'inventario.entrada' y 'cobro.descuento' se otorgan uno a uno con
-- usuario_permiso cuando el admin lo habilita.
INSERT INTO rol_permiso (rol_codigo, permiso_codigo) VALUES
  ('auxiliar', 'turnos.ver'),
  ('auxiliar', 'turnos.crear'),
  ('auxiliar', 'turnos.priorizar'),
  ('auxiliar', 'turnos.cancelar'),
  ('auxiliar', 'inventario.ver'),
  ('auxiliar', 'pacientes.ver'),
  ('auxiliar', 'pacientes.editar'),
  ('auxiliar', 'cobro.ver'),
  ('auxiliar', 'cobro.linea'),
  ('auxiliar', 'cobro.pago'),
  ('auxiliar', 'caja.cerrar'),
  ('auxiliar', 'proveedores.ver'),
  ('auxiliar', 'reportes.operativos')
ON CONFLICT DO NOTHING;

-- recepción: sólo lectura de la cola y registro básico.
INSERT INTO rol_permiso (rol_codigo, permiso_codigo) VALUES
  ('recepcion', 'turnos.ver'),
  ('recepcion', 'turnos.crear'),
  ('recepcion', 'pacientes.ver'),
  ('recepcion', 'pacientes.editar'),
  ('recepcion', 'cobro.ver')
ON CONFLICT DO NOTHING;
