-- =====================================================================
-- Chasqui Pet — 075_prerrequisitos_ia.sql
-- Ámbito: NÚCLEO (convención de cabecera, Fase A7a del plan de
-- consolidación).
--
-- Adelanta lo que las migraciones del asistente (078–083) dan por
-- existente. No agrega funcionalidad: destraba la instalación limpia.
--
-- El problema, verificado levantando un contenedor de Postgres virgen
-- contra db/migrations: el arranque ABORTA en 078.
--   · `ia_herramienta.permiso` referencia `permiso(codigo)`, y el
--     catálogo de permisos se siembra en 100_seed_roles.sql;
--   · 078 termina con GRANT a `chasquipet_app`, rol que crea
--     090_grants.sql;
--   · 083 inserta en `rol_permiso` para 'veterinario' y 'auxiliar',
--     roles que también salen de 100.
-- Las tres dependencias apuntan a archivos con prefijo POSTERIOR. No es
-- un error de contenido: 078–083 se escribieron para aplicarse a mano
-- sobre una base ya montada, donde 090 y 100 llevaban meses corridos, y
-- su prefijo nunca se conformó al orden de initdb.
--
-- Por qué así y no de otra forma: la regla del proyecto es no editar ni
-- renumerar una migración existente (CLAUDE.md → Database). Lo único
-- aditivo posible es un archivo con un prefijo libre ANTERIOR a 078 que
-- adelante las tres dependencias. Todo aquí es idempotente y repite
-- textualmente lo que hacen 090 y 100, así que cuando esos archivos
-- corran después no encontrarán nada que hacer (`ON CONFLICT DO
-- NOTHING`) y quedan como la fuente única de esos datos: si mañana se
-- agrega un permiso, se agrega en 100 —o en una migración nueva—, no
-- aquí. Este archivo solo cubre lo que 078–083 necesitan para no
-- reventar.
--
-- Sobre una base ya inicializada este archivo no cambia absolutamente
-- nada: los roles existen, el catálogo está sembrado y todo cae en el
-- ON CONFLICT.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1. Roles de base de datos. Copia literal del bloque de 090_grants.sql:
--    aquí solo se crean, los privilegios los sigue otorgando 090.
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chasquipet_app') THEN
    -- La contraseña se fija desde docker-compose (ver .env). Aquí sólo el rol.
    CREATE ROLE chasquipet_app LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chasquipet_lectura') THEN
    CREATE ROLE chasquipet_lectura LOGIN;   -- reportes / BI, sólo lectura
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 2. Catálogo de roles de negocio. 083 cuelga permisos de 'veterinario'
--    y 'auxiliar', así que las filas tienen que existir antes.
-- ---------------------------------------------------------------------
INSERT INTO rol (codigo, nombre, descripcion, nivel, sistema) VALUES
  ('superadmin',  'Superadministrador', 'Acceso técnico total, configuración del sistema, auditoría y tareas fallidas.', 100, true),
  ('admin',       'Administrador',      'Administra la clínica: usuarios, catálogo, precios, proveedores, inventario, tarifas, caja y reportes.', 80, true),
  ('veterinario', 'Veterinario',        'Atiende turnos, crea y firma consultas, da salida a medicamentos vinculada a consulta.', 60, true),
  ('auxiliar',    'Auxiliar',           'Crea turnos, registra dueños y mascotas, recibe pagos y cierra caja.', 40, true),
  ('recepcion',   'Recepción',          'Ve la cola, crea turnos manuales y registra dueños y mascotas.', 20, true)
ON CONFLICT (codigo) DO NOTHING;

-- ---------------------------------------------------------------------
-- 3. Catálogo de permisos. `ia_herramienta.permiso` es una clave foránea
--    contra esta tabla; sin estas filas, 078 no puede registrar una sola
--    herramienta.
--
--    NOTA: aquí NO se asigna ningún permiso a ningún rol (`rol_permiso`).
--    Esa asignación la hace 100_seed_roles.sql y sigue siendo suya: si se
--    adelantara, se estaría decidiendo dos veces quién puede qué.
-- ---------------------------------------------------------------------
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
