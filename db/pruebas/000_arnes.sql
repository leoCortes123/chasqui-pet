-- =====================================================================
-- Chasqui Pet — 000_arnes.sql
-- Andamio de las pruebas de invariantes (Fase A4 del plan de
-- consolidación). NO es una migración: vive en db/pruebas/ y solo se
-- carga en la base efímera que levanta scripts/pruebas.sh.
--
-- Qué hay aquí: la extensión pgTAP y un puñado de constructores de
-- datos. Los constructores llaman a las funciones de negocio reales
-- —`crear_dueno`, `crear_paciente`, `ingresar_lote`…— en vez de meter
-- filas a mano: si mañana una de ellas cambia de contrato, las pruebas
-- se enteran, que es justamente lo que se quiere.
--
-- Cada archivo de prueba corre dentro de una transacción que termina en
-- ROLLBACK, así que todo lo que estos constructores creen desaparece al
-- terminar y las pruebas no se contaminan entre sí.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgtap;

CREATE SCHEMA IF NOT EXISTS prueba;

-- Rol de negocio sin un solo permiso. Es el actor con el que se
-- comprueba que `exigir_permiso` rechaza: no depende de qué permisos
-- tenga hoy «recepción», así que la prueba no se vuelve falsa el día que
-- alguien reparta permisos distintos.
INSERT INTO rol (codigo, nombre, descripcion, nivel, sistema)
VALUES ('prueba_sin_permisos', 'Prueba sin permisos',
        'Rol sin permisos, usado solo por la batería de pruebas', 0, false)
ON CONFLICT (codigo) DO NOTHING;

-- El superadmin que creó 900_superadmin.sh. Es el actor con el que los
-- constructores arman los datos.
CREATE OR REPLACE FUNCTION prueba.superadmin() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT u.id FROM usuario u
    JOIN usuario_rol ur ON ur.usuario_id = u.id
   WHERE ur.rol_codigo = 'superadmin' AND u.activo
   ORDER BY u.created_at LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION prueba.sede() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM sede ORDER BY created_at LIMIT 1; $$;

-- Usuario nuevo con los roles que se pidan. El telegram_user_id sale de
-- un contador para que dos llamadas seguidas no choquen contra la clave
-- única.
CREATE SEQUENCE IF NOT EXISTS prueba.telegram_id_seq START 800000000;

CREATE OR REPLACE FUNCTION prueba.usuario(p_roles text[], p_nombre text DEFAULT 'Usuario de prueba')
RETURNS uuid
LANGUAGE sql AS $$
  SELECT crear_usuario(prueba.superadmin(), nextval('prueba.telegram_id_seq'),
                       p_nombre, p_roles, prueba.sede());
$$;

-- El actor sin permisos.
CREATE OR REPLACE FUNCTION prueba.don_nadie() RETURNS uuid
LANGUAGE sql AS $$
  SELECT prueba.usuario(ARRAY['prueba_sin_permisos'], 'Don Nadie');
$$;

CREATE OR REPLACE FUNCTION prueba.dueno(p_consentimiento boolean DEFAULT false,
                                        p_chat_id bigint DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  v_id := (crear_dueno(prueba.superadmin(), 'Dueño de prueba', '3000000000')->'dueno'->>'dueno_id')::uuid;
  IF p_consentimiento THEN
    PERFORM registrar_consentimiento(prueba.superadmin(), v_id, true, p_chat_id);
  END IF;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION prueba.paciente(p_dueno_id uuid DEFAULT NULL) RETURNS uuid
LANGUAGE sql AS $$
  SELECT (crear_paciente(prueba.superadmin(), 'Mascota de prueba', 'perro',
                         COALESCE(p_dueno_id, prueba.dueno()))->'paciente'->>'paciente_id')::uuid;
$$;

CREATE OR REPLACE FUNCTION prueba.medicamento(p_nombre text DEFAULT 'Medicamento de prueba')
RETURNS uuid
LANGUAGE sql AS $$
  SELECT (crear_medicamento(prueba.superadmin(), p_nombre, 1000, 'unidad')
          ->'medicamento'->>'medicamento_id')::uuid;
$$;

-- Lote con vencimiento y cantidad a la medida, por la puerta de negocio
-- (`ingresar_lote`), para que quede su movimiento de entrada.
CREATE OR REPLACE FUNCTION prueba.lote(p_medicamento_id uuid, p_vence date, p_cantidad numeric)
RETURNS uuid
LANGUAGE sql AS $$
  SELECT (ingresar_lote(prueba.superadmin(), p_medicamento_id,
                        'L-' || nextval('prueba.telegram_id_seq')::text,
                        p_vence, p_cantidad)->>'lote_id')::uuid;
$$;
