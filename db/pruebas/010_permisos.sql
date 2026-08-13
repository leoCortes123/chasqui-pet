-- =====================================================================
-- Invariante: NINGUNA función de escritura de negocio se ejecuta sin
-- permiso (regla C6.5). El actor es «Don Nadie»: un usuario con un rol
-- real pero sin un solo permiso asignado, así que la prueba no depende
-- de cómo estén repartidos hoy los permisos entre los roles.
--
-- El contrato que se verifica es el de `exigir_permiso`: excepción con
-- SQLSTATE 42501. No se comprueba el texto del mensaje, que es de
-- presentación y puede cambiar.
--
-- Los argumentos son deliberadamente inválidos (UUID inventado): si una
-- función valida los datos ANTES de exigir el permiso, esta prueba
-- falla, y debe fallar — es la manera de detectar que la reja quedó
-- detrás de la puerta.
-- =====================================================================
BEGIN;
SELECT plan(29);

CREATE TEMP TABLE actor AS SELECT prueba.don_nadie() AS id;
CREATE TEMP TABLE ficha AS
  SELECT prueba.sede() AS sede,
         '00000000-0000-0000-0000-000000000001'::uuid AS fantasma;

-- --- Turnos ----------------------------------------------------------
SELECT throws_ok(
  format('SELECT crear_turno_manual(%L, %L, ''general'')', a.id, f.sede),
  '42501', NULL, 'crear_turno_manual exige permiso')
  FROM actor a, ficha f;
SELECT throws_ok(format('SELECT llamar_siguiente(%L)', id), '42501', NULL,
  'llamar_siguiente exige permiso') FROM actor;
SELECT throws_ok(format('SELECT iniciar_atencion(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'iniciar_atencion exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT finalizar_turno(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'finalizar_turno exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT marcar_ausente(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'marcar_ausente exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT reencolar_turno(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'reencolar_turno exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT abrir_consultorio(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'abrir_consultorio exige permiso') FROM actor a, ficha f;

-- --- Inventario ------------------------------------------------------
SELECT throws_ok(format('SELECT crear_medicamento(%L, ''X'', 100)', id), '42501', NULL,
  'crear_medicamento exige permiso') FROM actor;
SELECT throws_ok(format('SELECT cambiar_precio_medicamento(%L, %L, 100)', a.id, f.fantasma),
  '42501', NULL, 'cambiar_precio_medicamento exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT salida_medicamento(%L, %L, 1)', a.id, f.fantasma), '42501', NULL,
  'salida_medicamento exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT ajustar_lote(%L, %L, ''ajuste_negativo'', 1, ''x'')', a.id, f.fantasma), '42501', NULL,
  'ajustar_lote exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT ingresar_lote(%L, %L, ''L1'', ''2030-01-01''::date, 1)', a.id, f.fantasma),
  '42501', NULL, 'ingresar_lote exige permiso') FROM actor a, ficha f;

-- --- Clínico ---------------------------------------------------------
SELECT throws_ok(format('SELECT crear_dueno(%L, ''Quien Sea'')', id), '42501', NULL,
  'crear_dueno exige permiso') FROM actor;
SELECT throws_ok(format('SELECT crear_paciente(%L, ''Bicho'')', id), '42501', NULL,
  'crear_paciente exige permiso') FROM actor;
SELECT throws_ok(
  format('SELECT alta_paciente(%L, ''{"mascota_nombre":"Bicho","dueno_nombre":"Quien Sea"}''::jsonb)', id),
  '42501', NULL, 'alta_paciente exige permiso') FROM actor;
SELECT throws_ok(format('SELECT registrar_consentimiento(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'registrar_consentimiento exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT abrir_consulta(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'abrir_consulta exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT guardar_consulta(%L, %L, ''motivo_consulta'', ''x'')', a.id, f.fantasma),
  '42501', NULL, 'guardar_consulta exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT firmar_consulta(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'firmar_consulta exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT anular_consulta(%L, %L, ''motivo'')', a.id, f.fantasma), '42501', NULL,
  'anular_consulta exige permiso') FROM actor a, ficha f;

-- --- Cobro -----------------------------------------------------------
SELECT throws_ok(format('SELECT agregar_linea_servicio(%L, %L, NULL, 1000, 1, ''x'')', a.id, f.fantasma),
  '42501', NULL, 'agregar_linea_servicio exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT quitar_linea(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'quitar_linea exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT aplicar_descuento(%L, %L, 100, ''x'')', a.id, f.fantasma), '42501', NULL,
  'aplicar_descuento exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT registrar_pago(%L, %L, ''efectivo'')', a.id, f.fantasma), '42501', NULL,
  'registrar_pago exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT anular_cuenta(%L, %L, ''x'')', a.id, f.fantasma), '42501', NULL,
  'anular_cuenta exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT cerrar_caja(%L, %L, 0)', a.id, f.fantasma), '42501', NULL,
  'cerrar_caja exige permiso') FROM actor a, ficha f;

-- --- Compras ---------------------------------------------------------
SELECT throws_ok(format('SELECT crear_proveedor(%L, ''Proveedor'')', id), '42501', NULL,
  'crear_proveedor exige permiso') FROM actor;
SELECT throws_ok(format('SELECT crear_entrada(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'crear_entrada exige permiso') FROM actor a, ficha f;
SELECT throws_ok(format('SELECT confirmar_entrada(%L, %L)', a.id, f.fantasma), '42501', NULL,
  'confirmar_entrada exige permiso') FROM actor a, ficha f;

SELECT * FROM finish();
ROLLBACK;
