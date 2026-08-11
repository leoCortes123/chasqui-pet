-- =====================================================================
-- Chasqui Pet — 078_chasqui_ia.sql
-- «Habla con Chasqui»: conversación en lenguaje natural sobre la clínica.
--
-- Qué es y qué NO es
-- ------------------
-- Es una puerta más al mismo sistema, no un sistema paralelo. El asistente
-- no tiene acceso a la base: tiene una lista cerrada de herramientas —las
-- de este archivo— y cada una llama a las MISMAS funciones que ya usan los
-- botones del menú. Por eso hereda gratis todo lo que ya está probado:
-- permisos (`exigir_permiso`), auditoría, append-only del inventario y la
-- caja, y los mensajes de error en español que ya escribimos.
--
-- Las tres reglas que ordenan el diseño:
--
--   1. NADA de SQL libre. El modelo no escribe consultas; escoge una
--      herramienta de un catálogo y le pasa argumentos tipados. Lo que no
--      esté en la tabla `ia_herramienta` sencillamente no existe para él.
--
--   2. Los permisos son los del USUARIO, no los del asistente. El catálogo
--      que se le manda al modelo ya viene filtrado por `tiene_permiso`, y
--      además la función de negocio vuelve a exigirlos por dentro. Que la
--      lista esté filtrada es comodidad; que la función exija es la
--      seguridad. Un auxiliar no puede cobrar por chat porque no puede
--      cobrar, y punto.
--
--   3. Leer se hace solo; ESCRIBIR se confirma con un botón. Cualquier
--      herramienta con `escribe = true` no se ejecuta al invocarla: deja
--      una propuesta en `ia_accion_pendiente` y el bot muestra al usuario
--      exactamente qué va a pasar. La acción la dispara la persona, no el
--      modelo. Lo crítico —dinero e inventario— además enseña las cifras
--      concretas en la tarjeta de confirmación.
--
-- Reparto con el resto del sistema (§2.1, §2.2): la base decide QUÉ se
-- puede hacer y arma los textos; el worker solo habla con la API del
-- modelo, que es I/O lento y no cabe dentro del segundo que Telegram le
-- da al webhook. Por eso el texto del usuario se encola como tarea
-- `chasqui_responder` en vez de responderse en línea.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1. Configuración
-- ---------------------------------------------------------------------
INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('ia_activa', 'true', 'booleano',
   'Habilita «Habla con Chasqui», el asistente en lenguaje natural del bot', true),
  ('ia_modelo', 'nemotron-3-ultra-free', 'texto',
   'Modelo de IA que responde (ej: nemotron-3-ultra-free para OpenCode, o deepseek-v4-pro)', true),
  ('ia_temperatura', '0.3', 'texto',
   'Qué tan suelto responde el modelo, de 0 a 1. Bajo = más literal y predecible', true),
  ('ia_turnos_memoria', '20', 'entero',
   'Cuántos mensajes recuerda la conversación con Chasqui antes de olvidar los viejos', true),
  ('ia_limite_hora', '60', 'entero',
   'Máximo de mensajes por usuario y por hora en «Habla con Chasqui»', true),
  ('ia_sobre_el_negocio', '', 'texto',
   'Notas libres sobre la clínica que Chasqui puede usar para responder dudas del negocio', true)
ON CONFLICT (clave) DO NOTHING;


-- ---------------------------------------------------------------------
-- 2. Memoria de la conversación
--
-- Se guarda solo lo que se dijeron: la pregunta y la respuesta final, como
-- texto. Las consultas a herramientas que el modelo haya hecho para llegar
-- a esa respuesta viven únicamente durante esa tarea y no se persisten —los
-- datos que sacó ya están dentro de lo que contestó, y guardar llamadas a
-- herramientas a medias es la forma más fácil de mandarle a la API un
-- historial que ella misma rechaza.
--
-- La poda la hace `ia_historial` al leer, no un job.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ia_mensaje (
  id          bigserial PRIMARY KEY,
  chat_id     bigint NOT NULL,
  usuario_id  uuid REFERENCES usuario(id) ON DELETE SET NULL,
  rol         text NOT NULL CHECK (rol IN ('user', 'assistant')),
  contenido   jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ia_mensaje_chat ON ia_mensaje (chat_id, id DESC);


-- Propuestas de escritura a la espera del botón de confirmación.
--
-- Viven 10 minutos: una propuesta vieja se hizo sobre un stock o una
-- cuenta que ya cambió, y confirmarla a ciegas media hora después es
-- justamente lo que la confirmación pretende evitar.
CREATE TABLE IF NOT EXISTS ia_accion_pendiente (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id      bigint NOT NULL,
  usuario_id   uuid NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
  sede_id      uuid REFERENCES sede(id),
  herramienta  text NOT NULL,
  argumentos   jsonb NOT NULL DEFAULT '{}'::jsonb,
  resumen      text NOT NULL,
  estado       text NOT NULL DEFAULT 'pendiente'
                 CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'expirada')),
  resultado    jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  expira_at    timestamptz NOT NULL DEFAULT now() + interval '10 minutes',
  resuelta_at  timestamptz
);

CREATE INDEX IF NOT EXISTS idx_ia_pendiente_chat
  ON ia_accion_pendiente (chat_id) WHERE estado = 'pendiente';


-- ---------------------------------------------------------------------
-- 3. Catálogo de herramientas
--
-- Una tabla y no un CASE gigante: el catálogo se consulta para armar lo
-- que se le manda al modelo, y se consulta otra vez para decidir si algo
-- escribe. Con dos listas separadas acabarían desincronizadas, y la que
-- se desincronizaría es la que dice «esto escribe» — la que importa.
--
--   permiso  NULL = disponible para cualquier miembro del personal.
--   escribe  true = no se ejecuta sola, deja propuesta y espera el botón.
--   critica  true = la confirmación muestra las cifras exactas (dinero,
--            existencias). Todo lo que toca plata o inventario lo es.
--   esquema  JSON Schema de los argumentos, tal cual lo pide la API.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ia_herramienta (
  nombre      text PRIMARY KEY,
  permiso     text REFERENCES permiso(codigo),
  escribe     boolean NOT NULL DEFAULT false,
  critica     boolean NOT NULL DEFAULT false,
  descripcion text NOT NULL,
  esquema     jsonb NOT NULL DEFAULT '{"type":"object","properties":{}}'::jsonb,
  orden       int NOT NULL DEFAULT 100,
  activa      boolean NOT NULL DEFAULT true
);

-- Nota sobre las descripciones: las lee el modelo, no una persona. Dicen
-- CUÁNDO usar la herramienta, no solo qué hace — es lo que decide si la
-- llama en el momento correcto.
INSERT INTO ia_herramienta (nombre, permiso, escribe, critica, orden, descripcion, esquema) VALUES

-- --- Lectura ---------------------------------------------------------
('ver_cola', 'turnos.ver', false, false, 10,
 'Lista los pacientes que esperan turno ahora mismo, con su código, tipo de servicio, '
 'minutos esperando y si son urgencia. Úsala cuando pregunten por la cola, la sala de '
 'espera, cuánta gente hay o a quién sigue atender. Devuelve el turno_id de cada uno, '
 'que sirve para cambiar_estado_turno.',
 '{"type":"object","properties":{}}'::jsonb),

('resumen_dia', 'turnos.ver', false, false, 20,
 'Resumen operativo de la jornada de hoy: turnos en espera, atendidos y ausentes, '
 'consultorios abiertos, alertas de inventario y estado de la caja. Úsala para '
 'preguntas amplias como «cómo va el día» o «cómo vamos».',
 '{"type":"object","properties":{}}'::jsonb),

('informacion_clinica', NULL, false, false, 30,
 'Datos de la propia clínica: nombre, sedes, consultorios, tipos de servicio que se '
 'atienden, parámetros de operación configurados y notas del negocio. Úsala cuando '
 'pregunten cómo funciona la clínica, qué servicios hay, cómo está configurado algo, '
 'o cualquier duda sobre el negocio mismo en vez de sobre un dato del día.',
 '{"type":"object","properties":{}}'::jsonb),

('buscar_medicamento', 'inventario.ver', false, false, 40,
 'Busca medicamentos por nombre o presentación y devuelve existencias totales, precio '
 'de venta y los lotes disponibles ordenados por vencimiento (el primero que debe '
 'salir va de primero). Úsala para «cuánto queda de X», «tenemos Y», «a cómo está Z». '
 'Devuelve el lote_id que necesita registrar_salida_medicamento.',
 '{"type":"object","properties":{"texto":{"type":"string","description":"Nombre o parte del nombre del medicamento"}},"required":["texto"]}'::jsonb),

('alertas_inventario', 'inventario.ver', false, false, 50,
 'Medicamentos bajo el mínimo, lotes vencidos y lotes por vencer. Úsala cuando '
 'pregunten qué falta, qué hay que pedir o qué está por vencerse.',
 '{"type":"object","properties":{}}'::jsonb),

('ver_caja', 'cobro.ver', false, false, 60,
 'Estado de la caja de un día: si está abierta, cuánto se recaudó por cada medio de '
 'pago, cuánto se facturó y cuánto queda por cobrar. Sin fecha, es el día de hoy.',
 '{"type":"object","properties":{"fecha":{"type":"string","description":"Fecha en formato AAAA-MM-DD. Omitir para hoy."}}}'::jsonb),

('cuentas_por_cobrar', 'cobro.ver', false, false, 70,
 'Cuentas abiertas con saldo pendiente: paciente, total, abonado y lo que falta. '
 'Devuelve el cuenta_id que necesitan cobrar_cuenta y agregar_servicio_a_cuenta.',
 '{"type":"object","properties":{}}'::jsonb),

('ver_tarifas', 'cobro.ver', false, false, 80,
 'Lista de servicios con su precio vigente. Úsala para «cuánto vale una consulta» o '
 'antes de agregar un servicio a una cuenta. Devuelve el tarifa_id.',
 '{"type":"object","properties":{}}'::jsonb),

('buscar_paciente', 'pacientes.ver', false, false, 90,
 'Busca pacientes por nombre del animal, nombre del dueño o documento. Devuelve '
 'especie, raza, edad, dueño y el paciente_id.',
 '{"type":"object","properties":{"texto":{"type":"string","description":"Nombre del paciente, del dueño o documento"}},"required":["texto"]}'::jsonb),

('historia_paciente', 'pacientes.ver', false, false, 100,
 'Historia clínica de un paciente: consultas firmadas con fecha, motivo, diagnóstico y '
 'veterinario. Necesita el paciente_id, que sale de buscar_paciente.',
 '{"type":"object","properties":{"paciente_id":{"type":"string","description":"UUID del paciente"},"limite":{"type":"integer","description":"Cuántas consultas traer (por defecto 10)"}},"required":["paciente_id"]}'::jsonb),

('buscar_dueno', 'pacientes.ver', false, false, 110,
 'Busca dueños por nombre, teléfono o documento, con sus pacientes asociados.',
 '{"type":"object","properties":{"texto":{"type":"string","description":"Nombre, teléfono o documento del dueño"}},"required":["texto"]}'::jsonb),

('buscar_proveedor', 'proveedores.ver', false, false, 120,
 'Proveedores registrados con su última compra. Sin texto, devuelve los más '
 'frecuentes.',
 '{"type":"object","properties":{"texto":{"type":"string","description":"Nombre del proveedor. Omitir para ver los frecuentes."}}}'::jsonb),

('enlace_portal', NULL, false, false, 130,
 'Genera un enlace de un solo uso para que quien está hablando entre al portal web '
 'desde el navegador. Sirve 5 minutos y solo funciona para su propio usuario.',
 '{"type":"object","properties":{}}'::jsonb),

-- --- Escritura (todas piden confirmación con botón) -------------------
('llamar_siguiente', 'turnos.llamar', true, false, 200,
 'Llama al siguiente paciente de la cola al consultorio donde está atendiendo quien '
 'habla. Requiere tener un consultorio abierto.',
 '{"type":"object","properties":{}}'::jsonb),

('crear_turno', 'turnos.crear', true, false, 210,
 'Crea un turno manual para alguien que llegó sin escanear el código QR.',
 '{"type":"object","properties":{"tipo":{"type":"string","description":"Código del tipo de servicio, por ejemplo general o urgencia"},"urgencia":{"type":"boolean","description":"true si es una urgencia y debe pasar de primero"},"notas":{"type":"string","description":"Nota corta sobre el paciente"}}}'::jsonb),

('cambiar_estado_turno', 'turnos.llamar', true, false, 220,
 'Cambia el estado de un turno concreto: marcar que el paciente llegó y entra a '
 'atención, que no se presentó, que la atención terminó, o devolver un ausente a la '
 'cola. Necesita el turno_id, que sale de ver_cola.',
 '{"type":"object","properties":{"turno_id":{"type":"string","description":"UUID del turno"},"accion":{"type":"string","enum":["presento","ausente","finalizar","reencolar"],"description":"presento = ya llegó y entra; ausente = no se presentó; finalizar = terminó la atención; reencolar = devolver un ausente a la cola"}},"required":["turno_id","accion"]}'::jsonb),

('registrar_salida_medicamento', 'inventario.salida', true, true, 230,
 'Descuenta del inventario una cantidad de un lote concreto. Antes llama siempre a '
 'buscar_medicamento para obtener el lote_id correcto y ver cuánto hay.',
 '{"type":"object","properties":{"lote_id":{"type":"string","description":"UUID del lote del que sale"},"cantidad":{"type":"number","description":"Cantidad a descontar, en la unidad del medicamento"},"motivo":{"type":"string","description":"Para qué salió"}},"required":["lote_id","cantidad"]}'::jsonb),

('agregar_servicio_a_cuenta', 'cobro.linea', true, true, 240,
 'Agrega un servicio a una cuenta abierta. Usa tarifa_id cuando el servicio esté en la '
 'lista de tarifas; solo si no está, usa descripcion y valor.',
 '{"type":"object","properties":{"cuenta_id":{"type":"string","description":"UUID de la cuenta"},"tarifa_id":{"type":"string","description":"UUID de la tarifa, si el servicio ya está tarifado"},"descripcion":{"type":"string","description":"Descripción del servicio si no hay tarifa"},"valor":{"type":"number","description":"Valor unitario en pesos si no hay tarifa"},"cantidad":{"type":"number","description":"Cantidad, por defecto 1"}},"required":["cuenta_id"]}'::jsonb),

 ('cobrar_cuenta', 'cobro.pago', true, true, 250,
  'Registra un pago sobre una cuenta abierta. Sin valor, se toma el saldo completo que '
  'falta. Necesita el cuenta_id, que sale de cuentas_por_cobrar.',
  '{"type":"object","properties":{"cuenta_id":{"type":"string","description":"UUID de la cuenta"},"medio":{"type":"string","enum":["efectivo","tarjeta","transferencia","otro"],"description":"Medio de pago"},"valor":{"type":"number","description":"Valor en pesos. Omitir para cobrar todo el saldo."},"referencia":{"type":"string","description":"Número de aprobación o referencia de la transferencia"}},"required":["cuenta_id","medio"]}'::jsonb),

('preparar_alta_paciente', 'pacientes.editar', true, false, 260,
 'Prepara el registro de una mascota nueva junto con su dueño. Úsala cuando pidan dar de '
 'alta o registrar un paciente nuevo. Si el dueño ya está registrado, primero llama a '
 'buscar_dueno y pasa su dueno_id; si no, entrega sus datos y se crea con la mascota. '
 'Entiende la especie, la raza y la edad (por ejemplo «3 años» o «8 meses»).',
 '{"type":"object","properties":{"mascota_nombre":{"type":"string","description":"Nombre de la mascota"},"especie":{"type":"string","description":"Especie: perro, gato, ave, conejo, roedor, reptil, equino u otro"},"raza":{"type":"string","description":"Raza de la mascota, si se sabe"},"sexo":{"type":"string","description":"macho, hembra o desconocido"},"edad":{"type":"string","description":"Edad aproximada, por ejemplo «3 años», «8 meses» o «10 días». Alternativa a fecha_nacimiento_aprox"},"fecha_nacimiento_aprox":{"type":"string","description":"Fecha de nacimiento aproximada en formato AAAA-MM-DD, si se sabe"},"color_senas":{"type":"string","description":"Color o señas particulares"},"alergias":{"type":"string","description":"Alergias conocidas"},"notas":{"type":"string","description":"Notas sobre la mascota"},"dueno_id":{"type":"string","description":"UUID del dueño si ya existe (sale de buscar_dueno)"},"dueno_nombre":{"type":"string","description":"Nombre completo del dueño, obligatorio si no se pasa dueno_id"},"dueno_telefono":{"type":"string","description":"Teléfono del dueño"},"dueno_tipo_documento":{"type":"string","description":"cc, ce, ti, nit o pasaporte"},"dueno_numero_documento":{"type":"string","description":"Número del documento del dueño"},"dueno_direccion":{"type":"string","description":"Dirección del dueño"},"dueno_barrio":{"type":"string","description":"Barrio del dueño"}},"required":["mascota_nombre"]}'::jsonb)

ON CONFLICT (nombre) DO UPDATE
  SET permiso = EXCLUDED.permiso, escribe = EXCLUDED.escribe, critica = EXCLUDED.critica,
      descripcion = EXCLUDED.descripcion, esquema = EXCLUDED.esquema, orden = EXCLUDED.orden;


-- ---------------------------------------------------------------------
-- 4. Lo que el worker le manda al modelo
-- ---------------------------------------------------------------------

-- ¿Está disponible el asistente para este usuario?
CREATE OR REPLACE FUNCTION ia_disponible(p_usuario_id uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT config_bool('ia_activa', true) AND p_usuario_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM usuario WHERE id = p_usuario_id AND activo);
$$;

-- Catálogo filtrado por los permisos reales del usuario. Lo que no puede
-- hacer, no lo ve.
--
-- Sale ya en el formato de «funciones» que espera la API de DeepSeek —el
-- mismo de OpenAI—, porque es el único que lo consume. Si algún día se
-- cambia de proveedor, se cambia este jsonb_build_object y nada más: el
-- worker solo reenvía lo que salga de aquí.
CREATE OR REPLACE FUNCTION ia_herramientas(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'type', 'function',
           'function', jsonb_build_object(
             'name', nombre,
             'description', descripcion,
             'parameters', esquema)) ORDER BY orden), '[]'::jsonb)
    FROM ia_herramienta
   WHERE activa
     AND (permiso IS NULL OR tiene_permiso(p_usuario_id, permiso));
$$;

-- Contexto que va en el prompt de sistema: quién habla, dónde está parado
-- y qué día es. Sin esto el modelo responde en abstracto y pregunta cosas
-- que ya sabemos.
CREATE OR REPLACE FUNCTION ia_contexto(p_usuario_id uuid, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_usuario record;
  v_consultorio text;
BEGIN
  SELECT nombre_completo INTO v_usuario FROM usuario WHERE id = p_usuario_id;

  SELECT c.nombre INTO v_consultorio
    FROM sesion_consultorio sc JOIN consultorio c ON c.id = sc.consultorio_id
   WHERE sc.usuario_id = p_usuario_id AND sc.cerrada_at IS NULL;

  RETURN jsonb_build_object(
    'clinica',        config_txt('nombre_clinica', 'Chasqui Pet'),
    'usuario',        v_usuario.nombre_completo,
    'roles',          (SELECT COALESCE(jsonb_agg(rol_codigo), '[]'::jsonb)
                         FROM usuario_rol WHERE usuario_id = p_usuario_id),
    'consultorio_abierto', v_consultorio,
    'sede',           (SELECT nombre FROM sede WHERE id = p_sede_id),
    'fecha_hoy',      hoy_bogota(),
    'hora_local',     to_char(ahora_bogota(), 'HH24:MI'),
    'moneda',         'peso colombiano (COP)',
    'sobre_el_negocio', NULLIF(config_txt('ia_sobre_el_negocio', ''), ''));
END;
$$;

-- Historial reciente, del más viejo al más nuevo, podado al tamaño
-- configurado. Se corta por número de mensajes y no por tokens a
-- propósito: es un número que una persona de la clínica puede entender y
-- ajustar desde el portal sin saber qué es un token.
CREATE OR REPLACE FUNCTION ia_historial(p_chat_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('role', rol, 'content', contenido)
                            ORDER BY id), '[]'::jsonb)
    FROM (SELECT id, rol, contenido
            FROM ia_mensaje
           WHERE chat_id = p_chat_id
           ORDER BY id DESC
           LIMIT GREATEST(config_int('ia_turnos_memoria', 20), 2)) m;
$$;

CREATE OR REPLACE FUNCTION ia_registrar(
  p_chat_id bigint, p_usuario_id uuid, p_rol text, p_contenido jsonb)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO ia_mensaje (chat_id, usuario_id, rol, contenido)
  VALUES (p_chat_id, p_usuario_id, p_rol, p_contenido);
$$;

CREATE OR REPLACE FUNCTION ia_olvidar(p_chat_id bigint)
RETURNS void
LANGUAGE sql AS $$
  DELETE FROM ia_mensaje WHERE chat_id = p_chat_id;
$$;


-- ---------------------------------------------------------------------
-- 5. Ejecución de herramientas de LECTURA
--
-- Todo lo que devuelve es jsonb y va derecho al modelo como resultado de
-- la herramienta. Se devuelven los identificadores (turno_id, lote_id,
-- cuenta_id) porque son los que después necesita para proponer una
-- escritura: sin ellos el modelo tendría que adivinarlos, y adivinar un
-- UUID es exactamente lo que no queremos que intente.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_leer(
  p_usuario_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v jsonb;
BEGIN
  CASE p_nombre

    WHEN 'ver_cola' THEN
      SELECT jsonb_build_object(
               'en_espera', count(*),
               'turnos', COALESCE(jsonb_agg(jsonb_build_object(
                 'turno_id', id, 'codigo', codigo, 'tipo', tipo,
                 'minutos_esperando', minutos_esperando,
                 'urgencia', prioridad > 0) ORDER BY prioridad DESC, numero_secuencial),
                 '[]'::jsonb))
        INTO v
        FROM v_cola_actual WHERE sede_id = p_sede_id;

    WHEN 'resumen_dia' THEN
      v := dashboard(p_sede_id);

    WHEN 'informacion_clinica' THEN
      v := jsonb_build_object(
        'clinica', config_txt('nombre_clinica', 'Chasqui Pet'),
        'sedes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'nombre', nombre, 'direccion', direccion, 'telefono', telefono))
                    , '[]'::jsonb) FROM sede WHERE activa),
        'consultorios', (SELECT COALESCE(jsonb_agg(nombre ORDER BY orden), '[]'::jsonb)
                           FROM consultorio WHERE sede_id = p_sede_id AND activo),
        'tipos_de_servicio', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                'codigo', codigo, 'nombre', nombre,
                                'prioridad_base', prioridad_base) ORDER BY orden), '[]'::jsonb)
                                FROM tipo_servicio WHERE activo),
        -- Solo la configuración pensada para que la vea gente, no las
        -- claves internas: `editable_ui` ya marca esa frontera.
        'parametros', (SELECT COALESCE(jsonb_object_agg(clave, valor), '{}'::jsonb)
                         FROM config WHERE editable_ui AND clave NOT LIKE 'ia_%'),
        'notas_del_negocio', NULLIF(config_txt('ia_sobre_el_negocio', ''), ''));

    WHEN 'buscar_medicamento' THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'medicamento_id', m.medicamento_id,
               'nombre', m.nombre,
               'presentacion', m.presentacion,
               'disponible', m.disponible,
               'unidad', m.unidad_base,
               'bajo_minimo', m.bajo_minimo,
               'precio_venta', m.precio_venta,
               'lotes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                           'lote_id', l.lote_id, 'numero_lote', l.numero_lote,
                           'cantidad', l.cantidad_actual,
                           'vence', l.fecha_vencimiento,
                           'dias_para_vencer', l.dias_para_vencer,
                           'sugerido', l.es_sugerido)), '[]'::jsonb)
                           FROM lotes_fefo(m.medicamento_id, 5) l))), '[]'::jsonb)
        INTO v
        FROM buscar_medicamento(p_args->>'texto', 5) m;

    WHEN 'alertas_inventario' THEN
      v := alertas_inventario();

    WHEN 'ver_caja' THEN
      v := resumen_caja_dia(p_sede_id, NULLIF(p_args->>'fecha', '')::date);

    WHEN 'cuentas_por_cobrar' THEN
      SELECT COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb) INTO v
        FROM cuentas_abiertas(p_sede_id, 20) c;

    WHEN 'ver_tarifas' THEN
      SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO v
        FROM tarifas_activas(40) t;

    WHEN 'buscar_paciente' THEN
      SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v
        FROM buscar_paciente(p_args->>'texto', 8) x;

    WHEN 'historia_paciente' THEN
      SELECT jsonb_build_object(
               'paciente', paciente_json((p_args->>'paciente_id')::uuid),
               'consultas', COALESCE(jsonb_agg(to_jsonb(h)), '[]'::jsonb))
        INTO v
        FROM historia_paciente((p_args->>'paciente_id')::uuid,
                               COALESCE((p_args->>'limite')::int, 10)) h;

    WHEN 'buscar_dueno' THEN
      SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v
        FROM buscar_dueno(p_args->>'texto', 8) x;

    WHEN 'buscar_proveedor' THEN
      IF COALESCE(p_args->>'texto', '') = '' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v
          FROM proveedores_frecuentes(8) x;
      ELSE
        SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v
          FROM buscar_proveedor(p_args->>'texto', 8) x;
      END IF;

    WHEN 'enlace_portal' THEN
      v := crear_enlace_portal(p_usuario_id);

    ELSE
      RETURN jsonb_build_object('ok', false,
        'error', format('La herramienta %s no existe.', p_nombre));
  END CASE;

  RETURN jsonb_build_object('ok', true, 'datos', COALESCE(v, 'null'::jsonb));
END;
$$;


-- ---------------------------------------------------------------------
-- 6. Ejecución de herramientas de ESCRITURA
--
-- Esta función NO la llama el modelo: la llama `ia_confirmar` después de
-- que la persona tocó el botón. Es el único camino por el que una
-- conversación puede cambiar algo en la base.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_escribir(
  p_usuario_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v jsonb;
BEGIN
  CASE p_nombre

    WHEN 'llamar_siguiente' THEN
      v := llamar_siguiente(p_usuario_id);

    WHEN 'crear_turno' THEN
      v := crear_turno_manual(
             p_usuario_id, p_sede_id,
             COALESCE(NULLIF(p_args->>'tipo', ''), 'general'),
             COALESCE((p_args->>'urgencia')::boolean, false),
             NULL, NULL, NULLIF(p_args->>'notas', ''));

    WHEN 'cambiar_estado_turno' THEN
      v := CASE p_args->>'accion'
             WHEN 'presento'  THEN iniciar_atencion(p_usuario_id, (p_args->>'turno_id')::uuid)
             WHEN 'ausente'   THEN marcar_ausente(p_usuario_id, (p_args->>'turno_id')::uuid)
             WHEN 'finalizar' THEN finalizar_turno(p_usuario_id, (p_args->>'turno_id')::uuid)
             WHEN 'reencolar' THEN reencolar_turno(p_usuario_id, (p_args->>'turno_id')::uuid)
             ELSE jsonb_build_object('ok', false, 'mensaje', 'Esa acción sobre el turno no existe.')
           END;

    WHEN 'registrar_salida_medicamento' THEN
      v := salida_medicamento(
             p_usuario_id, (p_args->>'lote_id')::uuid, (p_args->>'cantidad')::numeric,
             NULLIF(p_args->>'motivo', ''));

    WHEN 'agregar_servicio_a_cuenta' THEN
      v := agregar_linea_servicio(
             p_usuario_id, (p_args->>'cuenta_id')::uuid,
             NULLIF(p_args->>'tarifa_id', '')::uuid,
             NULLIF(p_args->>'valor', '')::numeric,
             COALESCE((p_args->>'cantidad')::numeric, 1),
             NULLIF(p_args->>'descripcion', ''));

    WHEN 'cobrar_cuenta' THEN
      v := registrar_pago(
             p_usuario_id, (p_args->>'cuenta_id')::uuid, p_args->>'medio',
             NULLIF(p_args->>'valor', '')::numeric,
             NULLIF(p_args->>'referencia', ''));

    WHEN 'preparar_alta_paciente' THEN
      v := ia_alta_paciente_ejecutar(p_usuario_id, p_args);

    ELSE
      RETURN jsonb_build_object('ok', false,
        'mensaje', format('La herramienta %s no existe.', p_nombre));
  END CASE;

  RETURN v;
END;
$$;


-- ---------------------------------------------------------------------
-- 6.5 Alta asistida de paciente y dueño
--
-- El alta es la única herramienta cuya propuesta no se arma con un único
-- resumen fijo: lo que el modelo manda es lenguaje de mostrador («una
-- gata de 2 años llamada Luna»), y ese texto hay que aterrizarlo a los
-- códigos que entiende la base (especie, sexo, fecha de nacimiento)
-- antes de mostrarlo como tarjeta. Eso lo hace `ia_alta_paciente_borrador`,
-- que además re-exige permiso, avisa de posibles duplicados y deja la
-- propuesta en `ia_accion_pendiente`. La confirmación ejecuta luego la
-- misma transacción que usa el menú: `crear_dueno` + `crear_paciente`,
-- cada una con su auditoría.
-- ---------------------------------------------------------------------

-- La especie que dice una persona no siempre es la del catálogo: «perrito»
-- y «canino» son perro, «hamster» es roedor. Se normaliza para no guardar
-- cinco formas de decir lo mismo.
CREATE OR REPLACE FUNCTION ia_normalizar_especie(p_especie text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN normalizar(p_especie) IN ('perro','perra','canino','canina','can','perrito','perrita','cachorro','cachorra') THEN 'perro'
    WHEN normalizar(p_especie) IN ('gato','gata','felino','felina','gatito','gatita','minino','minina') THEN 'gato'
    WHEN normalizar(p_especie) IN ('ave','pajaro','pajara','pajarito','canario') THEN 'ave'
    WHEN normalizar(p_especie) IN ('conejo','coneja','conejito','conejita') THEN 'conejo'
    WHEN normalizar(p_especie) IN ('roedor','roedores','hamster','hamsters','cuy','cuyo','cobaya','cobayo','rata','raton','criceto') THEN 'roedor'
    WHEN normalizar(p_especie) IN ('reptil','reptiles','tortuga','iguana','serpiente','lagartija') THEN 'reptil'
    WHEN normalizar(p_especie) IN ('equino','caballo','yegua','potro','potra') THEN 'equino'
    ELSE 'otro'
  END;
$$;

CREATE OR REPLACE FUNCTION ia_normalizar_sexo(p_sexo text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN normalizar(p_sexo) = 'macho'  THEN 'macho'
    WHEN normalizar(p_sexo) = 'hembra' THEN 'hembra'
    ELSE 'desconocido'
  END;
$$;

-- «2 años», «8 meses», «3 semanas», «10 días», «1.5 años» → fecha de
-- nacimiento aproximada. Si lo que llega es una fecha, se usa tal cual.
CREATE OR REPLACE FUNCTION ia_edad_a_fecha(p_edad text)
RETURNS date
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_t       text := normalizar(p_edad);
  v_n       numeric;
  v_unidad  text;
  v_tmp     text[];
BEGIN
  IF v_t IS NULL OR v_t = '' THEN RETURN NULL; END IF;

  IF parse_fecha(v_t) IS NOT NULL THEN RETURN parse_fecha(v_t); END IF;

  -- «3 años», «8 meses», «2 semanas», «10 días», «1.5 años».
  v_tmp := regexp_match(replace(v_t, ',', '.'),
    '^(\d+(?:\.\d+)?)\s*(anos?|mes(?:es)?|semanas?|dias?)$');
  IF v_tmp IS NOT NULL THEN
    v_n      := v_tmp[1]::numeric;
    v_unidad := v_tmp[2];
  ELSE
    -- «un mes», «una semana»: las palabras con «un» no tienen dígitos.
    v_tmp := regexp_match(v_t, '^(?:un|una)\s*(anos?|mes(?:es)?|semanas?|dias?)$');
    IF v_tmp IS NULL THEN RETURN NULL; END IF;
    v_n      := 1;
    v_unidad := v_tmp[1];
  END IF;

  RETURN CASE
    WHEN v_unidad LIKE 'an%'     THEN (hoy_bogota() - v_n * interval '1 year')::date
    WHEN v_unidad LIKE 'mes%'    THEN (hoy_bogota() - v_n * interval '1 month')::date
    WHEN v_unidad LIKE 'semana%' THEN (hoy_bogota() - v_n * interval '1 week')::date
    ELSE (hoy_bogota() - v_n * interval '1 day')::date
  END;
END;
$$;

-- Prepara el alta: valida, normaliza, avisa de duplicados y deja la
-- propuesta en `ia_accion_pendiente`. Es lo que llama `ia_llamar` cuando
-- el modelo escoge la herramienta; la confirmación no vuelve a pasar por
-- aquí.
CREATE OR REPLACE FUNCTION ia_alta_paciente_borrador(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_nombre         text := trim(COALESCE(p_args->>'mascota_nombre', ''));
  v_especie        text := ia_normalizar_especie(p_args->>'especie');
  v_raza           text := NULLIF(trim(COALESCE(p_args->>'raza', '')), '');
  v_sexo           text := ia_normalizar_sexo(p_args->>'sexo');
  v_nacimiento     date := NULLIF(p_args->>'fecha_nacimiento_aprox', '')::date;
  v_color_senas    text := NULLIF(trim(COALESCE(p_args->>'color_senas', '')), '');
  v_alergias       text := NULLIF(trim(COALESCE(p_args->>'alergias', '')), '');
  v_notas          text := NULLIF(trim(COALESCE(p_args->>'notas', '')), '');

  v_dueno_id       uuid := NULLIF(p_args->>'dueno_id', '')::uuid;
  v_dueno_nombre   text := trim(COALESCE(p_args->>'dueno_nombre', ''));
  v_dueno_telefono text := NULLIF(trim(COALESCE(p_args->>'dueno_telefono', '')), '');
  v_dueno_tipo     text := NULLIF(p_args->>'dueno_tipo_documento', '');
  v_dueno_numero   text := NULLIF(trim(COALESCE(p_args->>'dueno_numero_documento', '')), '');
  v_dueno_dir      text := NULLIF(trim(COALESCE(p_args->>'dueno_direccion', '')), '');
  v_dueno_barrio   text := NULLIF(trim(COALESCE(p_args->>'dueno_barrio', '')), '');

  v_argumentos     jsonb;
  v_resumen        text;
  v_accion_id      uuid;
  v_aviso_dup      text := '';
  v_edad_txt       text;
  v_dup            record;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'pacientes.editar');

  -- Lo único que no se puede deducir ni adivinar es el nombre de la mascota.
  IF v_nombre = '' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta el nombre de la mascota. Pídelo antes de preparar el alta.');
  END IF;

  -- Dueño: o el que ya está registrado (dueno_id), o sus datos para crearlo.
  IF v_dueno_id IS NULL AND v_dueno_nombre = '' THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta el dueño. Busca el que ya existe con buscar_dueno y pasa su dueno_id, '
      'o pasa el nombre del dueño nuevo para crearlo con la mascota.');
  END IF;

  -- Si el dueño existe, su tarjeta muestra sus datos reales, no lo que el
  -- modelo recuerde de él.
  IF v_dueno_id IS NOT NULL THEN
    SELECT nombre_completo, telefono, tipo_documento, numero_documento
      INTO v_dueno_nombre, v_dueno_telefono, v_dueno_tipo, v_dueno_numero
      FROM dueno WHERE id = v_dueno_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error',
        'Ese dueño ya no existe. Vuelve a buscarlo con buscar_dueno y pasa su dueno_id.');
    END IF;
  END IF;

  IF v_nacimiento IS NULL THEN
    v_nacimiento := ia_edad_a_fecha(p_args->>'edad');
  END IF;
  v_edad_txt := edad_texto(v_nacimiento);

  v_argumentos := jsonb_build_object(
    'mascota_nombre', v_nombre, 'especie', v_especie, 'raza', v_raza,
    'sexo', v_sexo, 'fecha_nacimiento_aprox', v_nacimiento,
    'color_senas', v_color_senas, 'alergias', v_alergias, 'notas', v_notas,
    'dueno_id', v_dueno_id, 'dueno_nombre', v_dueno_nombre,
    'dueno_telefono', v_dueno_telefono, 'dueno_tipo_documento', v_dueno_tipo,
    'dueno_numero_documento', v_dueno_numero, 'dueno_direccion', v_dueno_dir,
    'dueno_barrio', v_dueno_barrio);

  -- Antes de crear se busca (§8.1): dos veces el mismo perro son dos
  -- historias que nadie sabe cuál mirar.
  FOR v_dup IN SELECT * FROM posibles_duplicados(v_nombre, v_dueno_nombre, v_dueno_telefono) LOOP
    v_aviso_dup := v_aviso_dup || E'\n⚠️ Ya existe <b>' || esc(v_dup.nombre) ||
                   '</b> de <b>' || esc(COALESCE(v_dup.dueno, 'sin dueño')) ||
                   '</b> (' || esc(v_dup.motivo) || '). ¿Será el mismo?';
  END LOOP;

  v_resumen := '🐾 <b>Alta de paciente</b>' || E'\n' ||
               esc(v_nombre) || ' · ' || esc(emoji_especie(v_especie)) || ' ' ||
               esc(nombre_especie(v_especie)) ||
               CASE WHEN v_raza IS NOT NULL
                    THEN E'\n' || 'Raza: <b>' || esc(v_raza) || '</b>' ELSE '' END ||
               CASE WHEN v_sexo <> 'desconocido'
                    THEN E'\n' || 'Sexo: ' ||
                         esc(CASE v_sexo WHEN 'macho' THEN '♂️ macho' ELSE '♀️ hembra' END)
                    ELSE '' END ||
               CASE WHEN v_edad_txt IS NOT NULL
                    THEN E'\n' || 'Edad: <b>' || esc(v_edad_txt) || '</b>' ||
                         ' (nacimiento aprox. ' || to_char(v_nacimiento, 'DD/MM/YYYY') || ')'
                    ELSE '' END ||
               CASE WHEN v_color_senas IS NOT NULL
                    THEN E'\n' || 'Señas: ' || esc(v_color_senas) ELSE '' END ||
               CASE WHEN v_alergias IS NOT NULL
                    THEN E'\n' || '⚠️ Alergias: ' || esc(v_alergias) ELSE '' END ||
               E'\n' ||
               E'\n' || '👤 Dueño: <b>' || esc(v_dueno_nombre) || '</b>' ||
               CASE WHEN v_dueno_telefono IS NOT NULL
                    THEN E'\n' || 'Tel: ' || esc(v_dueno_telefono) ELSE '' END ||
               CASE WHEN v_dueno_numero IS NOT NULL AND v_dueno_tipo IS NOT NULL
                    THEN E'\n' || esc(upper(v_dueno_tipo)) || ' ' || esc(v_dueno_numero)
                    ELSE '' END ||
               CASE WHEN v_notas IS NOT NULL
                    THEN E'\n' || E'\n' || '📝 ' || esc(v_notas) ELSE '' END ||
               v_aviso_dup;

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, 'preparar_alta_paciente', v_argumentos, v_resumen)
  RETURNING id INTO v_accion_id;

  RETURN jsonb_build_object(
    'ok', true, 'requiere_confirmacion', true,
    'accion_id', v_accion_id, 'critica', false, 'resumen', v_resumen);
END;
$$;

-- Ejecuta el alta real al confirmar. Reutiliza un dueño que ya exista con
-- ese documento o teléfono antes de crear otro: la deduplicación del
-- borrador avisa, y esta segunda reja evita el duplicado si el dato cambió
-- entre la propuesta y el botón.
CREATE OR REPLACE FUNCTION ia_alta_paciente_ejecutar(p_usuario_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_dueno      uuid := NULLIF(p_args->>'dueno_id', '')::uuid;
  v_dueno_hall uuid;
  v_r          jsonb;
  v_tel        text := NULLIF(p_args->>'dueno_telefono', '');
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'pacientes.editar');

  IF v_dueno IS NULL THEN
    IF NULLIF(p_args->>'dueno_numero_documento', '') IS NOT NULL
       AND NULLIF(p_args->>'dueno_tipo_documento', '') IS NOT NULL THEN
      SELECT id INTO v_dueno_hall FROM dueno
       WHERE tipo_documento = p_args->>'dueno_tipo_documento'
         AND numero_documento = p_args->>'dueno_numero_documento'
         AND activo
       LIMIT 1;
    END IF;
    IF v_dueno_hall IS NULL AND v_tel IS NOT NULL THEN
      SELECT id INTO v_dueno_hall FROM dueno
       WHERE telefono_digitos = regexp_replace(v_tel, '\D', '', 'g') AND activo
       LIMIT 1;
    END IF;
    v_dueno := v_dueno_hall;
  END IF;

  IF v_dueno IS NULL THEN
    IF NULLIF(p_args->>'dueno_nombre', '') IS NULL THEN
      RETURN jsonb_build_object('ok', false,
        'mensaje', 'Falta el dueño: no existe con ese documento o teléfono y no se '
                   'dio su nombre para crearlo.');
    END IF;
    v_r := crear_dueno(p_usuario_id, p_args->>'dueno_nombre',
                       v_tel, NULLIF(p_args->>'dueno_tipo_documento', ''),
                       NULLIF(p_args->>'dueno_numero_documento', ''),
                       NULLIF(p_args->>'dueno_direccion', ''),
                       NULLIF(p_args->>'dueno_barrio', ''),
                       NULL, 'telegram');
    IF NOT (v_r->>'ok')::boolean THEN RETURN v_r; END IF;
    v_dueno := (v_r->'dueno'->>'dueno_id')::uuid;
  END IF;

  RETURN crear_paciente(
    p_usuario_id,
    p_args->>'mascota_nombre',
    COALESCE(NULLIF(p_args->>'especie', ''), 'otro'),
    v_dueno,
    COALESCE(NULLIF(p_args->>'sexo', ''), 'desconocido'),
    NULLIF(p_args->>'raza', ''),
    NULLIF(p_args->>'fecha_nacimiento_aprox', '')::date,
    NULLIF(p_args->>'color_senas', ''),
    NULLIF(p_args->>'alergias', ''),
    NULLIF(p_args->>'notas', ''),
    'telegram');
END;
$$;


-- ---------------------------------------------------------------------
-- 7. La tarjeta de confirmación
--
-- Se arma en SQL, con los datos frescos de la base y no con lo que el
-- modelo crea recordar. Es la diferencia entre «confirma que vas a sacar
-- 2 cajas» y «confirma que vas a sacar 2 cajas de Amoxicilina 500 mg del
-- lote L-241, quedarían 7». Lo segundo se puede revisar; lo primero se
-- aprueba sin leer.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_resumen_accion(
  p_usuario_id uuid, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_txt text;
  r     record;
BEGIN
  CASE p_nombre

    WHEN 'llamar_siguiente' THEN
      SELECT c.nombre INTO v_txt
        FROM sesion_consultorio sc JOIN consultorio c ON c.id = sc.consultorio_id
       WHERE sc.usuario_id = p_usuario_id AND sc.cerrada_at IS NULL;
      -- Sin consultorio abierto la función de negocio va a rechazar; se
      -- dice aquí para no gastarle a nadie un toque de botón.
      IF v_txt IS NULL THEN
        RETURN '📢 <b>Llamar al siguiente</b>' || E'\n' ||
               '🚫 No tienes un consultorio abierto: esto va a fallar. ' ||
               'Abre uno desde el menú primero.';
      END IF;
      RETURN '📢 <b>Llamar al siguiente</b>' || E'\n' ||
             'Se llama al primero de la cola a <b>' || esc(v_txt) || '</b>.';

    WHEN 'crear_turno' THEN
      RETURN '➕ <b>Crear turno manual</b>' || E'\n' ||
             'Servicio: <b>' || esc(COALESCE(NULLIF(p_args->>'tipo', ''), 'general')) || '</b>' ||
             CASE WHEN COALESCE((p_args->>'urgencia')::boolean, false)
                  THEN E'\n' || '🚨 Marcado como <b>urgencia</b>: pasa de primero.' ELSE '' END ||
             CASE WHEN NULLIF(p_args->>'notas', '') IS NOT NULL
                  THEN E'\n' || '📝 ' || esc(p_args->>'notas') ELSE '' END;

    WHEN 'cambiar_estado_turno' THEN
      SELECT codigo, estado INTO r FROM turno WHERE id = (p_args->>'turno_id')::uuid;
      IF r.codigo IS NULL THEN RETURN '⚠️ Ese turno ya no existe.'; END IF;
      RETURN '🎫 <b>Turno ' || esc(r.codigo) || '</b>' || E'\n' ||
             'Hoy está en <b>' || esc(r.estado) || '</b> y pasaría a: <b>' ||
             esc(CASE p_args->>'accion'
                   WHEN 'presento'  THEN 'en atención'
                   WHEN 'ausente'   THEN 'no se presentó'
                   WHEN 'finalizar' THEN 'finalizado'
                   WHEN 'reencolar' THEN 'de vuelta en la cola'
                   ELSE p_args->>'accion' END) || '</b>.';

    WHEN 'registrar_salida_medicamento' THEN
      SELECT m.nombre_generico || COALESCE(' (' || m.nombre_comercial || ')', '') AS nombre,
             m.presentacion, m.unidad_base,
             l.numero_lote, l.cantidad_actual, l.fecha_vencimiento, l.bloqueado
        INTO r
        FROM lote l JOIN medicamento m ON m.id = l.medicamento_id
       WHERE l.id = (p_args->>'lote_id')::uuid;
      IF r.nombre IS NULL THEN RETURN '⚠️ Ese lote ya no existe.'; END IF;
      RETURN '💊 <b>Salida de inventario</b>' || E'\n' ||
             esc(r.nombre) || ' ' || esc(COALESCE(r.presentacion, '')) || E'\n' ||
             'Lote <b>' || esc(r.numero_lote) || '</b> · vence ' ||
             to_char(r.fecha_vencimiento, 'DD/MM/YYYY') || E'\n' ||
             'Sale: <b>' || fmt_cant((p_args->>'cantidad')::numeric) || ' ' ||
             esc(r.unidad_base) || '</b>' || E'\n' ||
             'Hay ' || fmt_cant(r.cantidad_actual) || ' → quedarían <b>' ||
             fmt_cant(r.cantidad_actual - (p_args->>'cantidad')::numeric) || '</b>' ||
             -- Se avisa aquí lo que de todas formas rechazaría la función:
             -- mejor verlo antes de confirmar que después de confirmar.
             CASE WHEN r.cantidad_actual < (p_args->>'cantidad')::numeric
                  THEN E'\n' || '🚫 <b>No alcanza</b>: esto va a fallar.' ELSE '' END ||
             CASE WHEN r.bloqueado
                  THEN E'\n' || '🚫 <b>Lote bloqueado</b>: no se puede despachar.' ELSE '' END ||
             CASE WHEN NULLIF(p_args->>'motivo', '') IS NOT NULL
                  THEN E'\n' || '📝 ' || esc(p_args->>'motivo') ELSE '' END;

    WHEN 'agregar_servicio_a_cuenta' THEN
      SELECT c.total, c.pagado, c.estado, p.nombre AS paciente,
             COALESCE(t.nombre, NULLIF(p_args->>'descripcion', '')) AS servicio,
             COALESCE(NULLIF(p_args->>'valor', '')::numeric, t.valor_sugerido) AS valor
        INTO r
        FROM cuenta c
        LEFT JOIN paciente p ON p.id = c.paciente_id
        LEFT JOIN tarifa t ON t.id = NULLIF(p_args->>'tarifa_id', '')::uuid
       WHERE c.id = (p_args->>'cuenta_id')::uuid;
      IF r.estado IS NULL THEN RETURN '⚠️ Esa cuenta ya no existe.'; END IF;
      RETURN '🧾 <b>Agregar a la cuenta</b>' ||
             CASE WHEN r.paciente IS NULL THEN '' ELSE ' · ' || esc(r.paciente) END || E'\n' ||
             esc(COALESCE(r.servicio, 'servicio sin nombre')) || ' × ' ||
             fmt_cant(COALESCE((p_args->>'cantidad')::numeric, 1)) || E'\n' ||
             'Suma <b>' || pesos(COALESCE(r.valor, 0) *
                                 COALESCE((p_args->>'cantidad')::numeric, 1)) || '</b>' || E'\n' ||
             'La cuenta va en ' || pesos(r.total) || ' y quedaría en <b>' ||
             pesos(r.total + COALESCE(r.valor, 0) *
                             COALESCE((p_args->>'cantidad')::numeric, 1)) || '</b>.';

    WHEN 'cobrar_cuenta' THEN
      SELECT c.total, c.pagado, GREATEST(c.total - c.pagado, 0) AS saldo,
             c.estado, p.nombre AS paciente
        INTO r
        FROM cuenta c LEFT JOIN paciente p ON p.id = c.paciente_id
       WHERE c.id = (p_args->>'cuenta_id')::uuid;
      IF r.estado IS NULL THEN RETURN '⚠️ Esa cuenta ya no existe.'; END IF;
      RETURN '💰 <b>Registrar pago</b>' ||
             CASE WHEN r.paciente IS NULL THEN '' ELSE ' · ' || esc(r.paciente) END || E'\n' ||
             'Total ' || pesos(r.total) || ' · abonado ' || pesos(r.pagado) ||
             ' · falta <b>' || pesos(r.saldo) || '</b>' || E'\n' ||
             'Se registra: <b>' ||
             pesos(COALESCE(NULLIF(p_args->>'valor', '')::numeric, r.saldo)) ||
             '</b> en <b>' || esc(nombre_medio_pago(p_args->>'medio')) || '</b>' ||
             CASE WHEN NULLIF(p_args->>'referencia', '') IS NOT NULL
                  THEN E'\n' || 'Referencia: ' || esc(p_args->>'referencia') ELSE '' END;

    ELSE
      RETURN 'Acción: ' || esc(p_nombre);
  END CASE;
END;
$$;


-- ---------------------------------------------------------------------
-- 8. La puerta única: lo que el worker llama por cada herramienta
--
-- Devuelve o el dato (lectura) o una propuesta con su identificador
-- (escritura). El worker no decide nada de esto: pregunta y obedece.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_llamar(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_nombre text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  h        ia_herramienta%ROWTYPE;
  v_id     uuid;
  v_resumen text;
BEGIN
  SELECT * INTO h FROM ia_herramienta WHERE nombre = p_nombre AND activa;

  IF h.nombre IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'error', format('No existe una herramienta llamada %s.', p_nombre));
  END IF;

  -- Segunda reja. La primera fue no ponerla en el catálogo; la tercera es
  -- el exigir_permiso de la propia función de negocio. Tres, porque una
  -- sola se puede olvidar al agregar la herramienta número quince.
  IF h.permiso IS NOT NULL AND NOT tiene_permiso(p_usuario_id, h.permiso) THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'El usuario no tiene permiso para esto. Díselo con naturalidad y ofrécele '
               'otra cosa; no lo intentes por otro camino.');
  END IF;

  -- El alta de un paciente no se propone con un resumen y unos argumentos
  -- fijos: la especie, la edad y el dueño que llegan del chat hay que
  -- normalizarlos antes de que valgan. Su función hace eso y además deja
  -- la propuesta en `ia_accion_pendiente`, así que se escapa del camino
  -- genérico de escritura.
  IF p_nombre = 'preparar_alta_paciente' THEN
    RETURN ia_alta_paciente_borrador(p_usuario_id, p_chat_id, p_sede_id,
                                     COALESCE(p_args, '{}'::jsonb));
  END IF;

  IF NOT h.escribe THEN
    BEGIN
      RETURN ia_leer(p_usuario_id, p_sede_id, p_nombre, COALESCE(p_args, '{}'::jsonb));
    EXCEPTION WHEN others THEN
      -- Un argumento mal formado (un UUID inventado, una fecha rara) no
      -- puede tumbar la tarea: se le devuelve al modelo como resultado
      -- para que corrija y vuelva a intentar.
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  -- Escritura: no se ejecuta, se propone.
  --
  -- El resumen se calcula ANTES de guardar y con los datos de este
  -- instante. Si entre la propuesta y el botón alguien más despacha ese
  -- lote, la tarjeta dirá lo que era cierto cuando se propuso y la
  -- función de negocio rechazará al confirmar: se falla, no se adivina.
  v_resumen := ia_resumen_accion(p_usuario_id, p_sede_id, p_nombre, COALESCE(p_args, '{}'::jsonb));

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, p_nombre, COALESCE(p_args, '{}'::jsonb), v_resumen)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'requiere_confirmacion', true,
    'accion_id', v_id,
    'critica', h.critica,
    'resumen', v_resumen);
END;
$$;

-- Ejecuta la propuesta. Aquí es donde por fin cambia algo.
CREATE OR REPLACE FUNCTION ia_confirmar(p_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  a ia_accion_pendiente%ROWTYPE;
  v jsonb;
BEGIN
  -- FOR UPDATE y el filtro por estado: dos toques rápidos al mismo botón
  -- no pueden cobrar dos veces.
  SELECT * INTO a FROM ia_accion_pendiente
   WHERE id = p_id AND estado = 'pendiente' FOR UPDATE;

  IF a.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa confirmación ya no está disponible.');
  END IF;

  -- Que confirme el mismo que pidió. El callback ya viene autenticado por
  -- Telegram, pero un botón reenviado a otro chat no debe servir.
  IF a.usuario_id <> p_usuario_id THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa confirmación no es tuya.');
  END IF;

  IF a.expira_at < now() THEN
    UPDATE ia_accion_pendiente SET estado = 'expirada', resuelta_at = now() WHERE id = p_id;
    RETURN jsonb_build_object('ok', false,
      'mensaje', 'Pasaron más de 10 minutos y los datos pudieron cambiar. Pídemelo otra vez.');
  END IF;

  BEGIN
    v := ia_escribir(a.usuario_id, a.sede_id, a.herramienta, a.argumentos);
  EXCEPTION
    WHEN insufficient_privilege THEN
      v := jsonb_build_object('ok', false, 'mensaje', 'No tienes permiso para esa acción.');
    WHEN others THEN
      v := jsonb_build_object('ok', false, 'mensaje', SQLERRM);
  END;

  UPDATE ia_accion_pendiente
     SET estado = 'confirmada', resultado = v, resuelta_at = now()
   WHERE id = p_id;

  PERFORM auditar('ia_accion_pendiente', p_id::text, 'confirmar', p_usuario_id, 'telegram',
                  NULL, jsonb_build_object('herramienta', a.herramienta,
                                           'argumentos', a.argumentos,
                                           'ok', v->'ok'));

  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION ia_cancelar(p_id uuid, p_usuario_id uuid)
RETURNS void
LANGUAGE sql AS $$
  UPDATE ia_accion_pendiente
     SET estado = 'cancelada', resuelta_at = now()
   WHERE id = p_id AND usuario_id = p_usuario_id AND estado = 'pendiente';
$$;


-- ---------------------------------------------------------------------
-- 9. El lado del bot
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_ia_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN ia_disponible(p_usuario_id)
    THEN jsonb_build_array(jsonb_build_array(
           jsonb_build_object('t', '💬 Habla con Chasqui', 'd', 'ia:abrir')))
    ELSE '[]'::jsonb END;
$$;

-- Texto de bienvenida del modo conversación. Dice de entrada lo que sí
-- puede hacer, porque una caja de texto vacía frente a un bot no le dice
-- a nadie qué se puede escribir ahí.
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
  IF tiene_permiso(p_usuario_id, 'cobro.ver') THEN
    v_ej := v_ej || E'\n' || '· «¿qué falta por cobrar hoy?»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'pacientes.ver') THEN
    v_ej := v_ej || E'\n' || '· «tráeme la historia de Luna»';
  END IF;
  IF tiene_permiso(p_usuario_id, 'pacientes.editar') THEN
    v_ej := v_ej || E'\n' || '· «registra a Luna, gata de 2 años, dueña María Gómez»';
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

-- Qué se le dice al usuario después de confirmar. Las funciones de negocio
-- devuelven `mensaje` cuando algo salió mal, pero cuando salen bien cada
-- una devuelve lo suyo; aquí se rescata el dato que a una persona le
-- importa ver («quedó el turno A-014», «faltan $20.600»).
CREATE OR REPLACE FUNCTION ia_texto_resultado(p_herramienta text, p_resultado jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(esc(p_resultado->>'mensaje'), ''),
    CASE p_herramienta
      WHEN 'crear_turno' THEN
        'Turno <b>' || esc(p_resultado->'turno'->>'codigo') || '</b> creado.'
      WHEN 'llamar_siguiente' THEN
        'Llamaste el turno <b>' || esc(p_resultado->'turno'->>'codigo') || '</b>.'
      WHEN 'registrar_salida_medicamento' THEN
        esc(p_resultado->'movimiento'->>'medicamento') || ': quedan <b>' ||
        fmt_cant((p_resultado->'movimiento'->>'restante')::numeric) || ' ' ||
        esc(p_resultado->'movimiento'->>'unidad') || '</b>.'
      WHEN 'agregar_servicio_a_cuenta' THEN
        'La cuenta va en <b>' || pesos((p_resultado->'cuenta'->>'total')::numeric) || '</b>.'
      WHEN 'cobrar_cuenta' THEN
        CASE WHEN COALESCE((p_resultado->'cuenta'->>'pendiente')::numeric, 0) > 0
             THEN 'Falta <b>' || pesos((p_resultado->'cuenta'->>'pendiente')::numeric) || '</b>.'
             ELSE 'Cuenta saldada.' END ||
        CASE WHEN COALESCE((p_resultado->>'vuelto')::numeric, 0) > 0
             THEN ' Devuelve <b>' || pesos((p_resultado->>'vuelto')::numeric) || '</b>.'
             ELSE '' END
      WHEN 'preparar_alta_paciente' THEN
        'Quedó registrada <b>' || esc(p_resultado->'paciente'->>'nombre') || '</b>' ||
        ' (' || esc(nombre_especie(p_resultado->'paciente'->>'especie')) || ').'
      ELSE NULL
    END);
$$;

CREATE OR REPLACE FUNCTION bot_ia_tarjeta_confirmacion(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE a ia_accion_pendiente%ROWTYPE;
BEGIN
  SELECT * INTO a FROM ia_accion_pendiente WHERE id = p_id;
  IF a.id IS NULL THEN
    RETURN jsonb_build_object('texto', 'Esa acción ya no está disponible.', 'botones', '[]'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'texto', a.resumen || E'\n\n' || '¿Lo hago?',
    'botones', jsonb_build_array(
      jsonb_build_array(
        jsonb_build_object('t', '✅ Sí, hazlo', 'd', 'ia:ok:' || a.id),
        jsonb_build_object('t', '✖️ No', 'd', 'ia:no:' || a.id))));
END;
$$;

CREATE OR REPLACE FUNCTION bot_ia_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_partes text[] := string_to_array(p_data, ':');
  v_r      jsonb;
  v_texto  text;
  v_txt    text;
BEGIN
  IF v_partes[1] <> 'ia' THEN RETURN NULL; END IF;

  -- Entrar al modo conversación. El estado es el que hace que el
  -- enrutador mande el texto suelto aquí y no al menú principal.
  IF p_data = 'ia:abrir' THEN
    IF NOT ia_disponible(p_usuario_id) THEN
      RETURN jsonb_build_object('alerta', 'No disponible', 'acciones', jsonb_build_array(
        accion_editar(p_chat_id, p_mensaje_id,
          '💬 Chasqui está apagado ahora mismo. Habla con el administrador.',
          jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Menú', 'd', 'menu'))))));
    END IF;

    PERFORM estado_guardar(p_chat_id, 'ia', 'conversando', '{}'::jsonb, p_usuario_id, p_mensaje_id);

    RETURN jsonb_build_object('alerta', 'Cuéntame', 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, bot_ia_bienvenida(p_usuario_id),
        jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '🧹 Olvidar lo hablado', 'd', 'ia:limpiar'),
          jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
  END IF;

  IF p_data = 'ia:salir' THEN
    PERFORM estado_limpiar(p_chat_id);
    v_r := bot_menu_principal(p_usuario_id);
    RETURN jsonb_build_object('alerta', NULL, 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_r->>'texto', v_r->'botones')));
  END IF;

  IF p_data = 'ia:limpiar' THEN
    PERFORM ia_olvidar(p_chat_id);
    RETURN jsonb_build_object('alerta', 'Listo, empezamos de cero', 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, bot_ia_bienvenida(p_usuario_id),
        jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
  END IF;

  -- Confirmar / cancelar una propuesta.
  IF v_partes[2] IN ('ok', 'no') AND v_partes[3] IS NOT NULL THEN
    IF v_partes[2] = 'no' THEN
      PERFORM ia_cancelar(v_partes[3]::uuid, p_usuario_id);
      RETURN jsonb_build_object('alerta', 'Cancelado', 'acciones', jsonb_build_array(
        accion_editar(p_chat_id, p_mensaje_id,
          '✖️ Listo, no hice nada. Dime otra cosa.',
          jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
    END IF;

    v_r := ia_confirmar(v_partes[3]::uuid, p_usuario_id);

    SELECT herramienta INTO v_txt FROM ia_accion_pendiente WHERE id = v_partes[3]::uuid;

    v_texto := CASE WHEN COALESCE((v_r->>'ok')::boolean, false)
                    THEN '✅ Hecho.' ELSE '⚠️ No se pudo.' END
               || COALESCE(E'\n' || ia_texto_resultado(v_txt, v_r), '');

    -- Queda en la memoria de la conversación para que el modelo sepa que
    -- eso ya pasó y no vuelva a proponerlo en el siguiente mensaje.
    PERFORM ia_registrar(p_chat_id, p_usuario_id, 'user',
      to_jsonb('[El usuario confirmó la acción y el sistema respondió: ' ||
               COALESCE(v_r::text, 'sin respuesta') || ']'));

    RETURN jsonb_build_object('alerta', NULL, 'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_texto,
        jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '💬 Seguir hablando', 'd', 'ia:abrir'),
          jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
  END IF;

  RETURN NULL;
END;
$$;

-- Texto suelto dentro del modo conversación: se encola y el worker
-- responde. Aquí no se llama a nadie por internet: el webhook tiene que
-- devolverle algo a Telegram en menos de un segundo (§2.2).
CREATE OR REPLACE FUNCTION bot_ia_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado jsonb := estado_leer(p_chat_id);
  v_entrar boolean := p_texto IN ('/chasqui', 'chasqui');
BEGIN
  IF NOT v_entrar AND COALESCE(v_estado->>'flujo', '') <> 'ia' THEN
    RETURN NULL;
  END IF;

  IF NOT ia_disponible(p_usuario_id) THEN
    RETURN NULL;   -- apagado: que el enrutador siga con el menú de siempre
  END IF;

  IF v_entrar THEN
    PERFORM estado_guardar(p_chat_id, 'ia', 'conversando', '{}'::jsonb, p_usuario_id);
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, bot_ia_bienvenida(p_usuario_id),
        jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Menú', 'd', 'ia:salir'))))));
  END IF;

  -- Un chat secuestrado no puede quemar la cuenta del modelo en una noche.
  IF NOT consumir_rate_limit('ia:' || p_usuario_id::text,
                             config_int('ia_limite_hora', 60), 3600) THEN
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id,
        '😮‍💨 Hablamos mucho en la última hora. Espera un rato o usa /menu.')));
  END IF;

  PERFORM ia_registrar(p_chat_id, p_usuario_id, 'user', to_jsonb(p_texto));

  PERFORM encolar_tarea('chasqui_responder',
    jsonb_build_object('chat_id', p_chat_id, 'usuario_id', p_usuario_id,
                       'sede_id', p_sede_id),
    5,          -- prioridad alta: hay alguien esperando frente al teléfono
    NULL, 0, 2  -- 2 intentos: si el modelo falla dos veces, mejor avisar que insistir
  );

  -- Sin mensaje inmediato a propósito: el «⌛ pensando…» que hay que
  -- borrar después ensucia el chat, y la respuesta llega en segundos.
  RETURN jsonb_build_object('acciones', '[]'::jsonb);
END;
$$;


-- ---------------------------------------------------------------------
-- 10. Enganche con los despachadores (se reescriben, ver 040)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_cli_menu(p_usuario_id) || bot_inv_menu(p_usuario_id)
      || bot_cob_menu(p_usuario_id) || bot_com_menu(p_usuario_id)
      || bot_por_menu(p_usuario_id) || bot_ia_menu(p_usuario_id);
$$;

CREATE OR REPLACE FUNCTION bot_modulo_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_ia_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_inv_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_cli_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_cob_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_com_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_por_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_auth_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id));
$$;

-- El orden importa: `bot_ia_texto` va de ÚLTIMO. Si un auxiliar está a
-- medias de registrar una entrada de inventario, el texto que escribe es
-- la cantidad que le pidieron, no una pregunta para Chasqui. Los flujos
-- con estado propio se atienden primero; la conversación recoge lo que
-- ninguno reclamó.
CREATE OR REPLACE FUNCTION bot_modulo_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_auth_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_por_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_inv_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cob_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_com_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cli_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_ia_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_texto_ayuda(p_usuario_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT '<b>Comandos</b>' || E'\n' ||
         '/menu — menú principal' || E'\n' ||
         '/chasqui — hablar con Chasqui en lenguaje natural' || E'\n' ||
         '/cola — pacientes en espera' || E'\n' ||
         '/stock — existencias y alertas de inventario' || E'\n' ||
         '/entrada — registrar una compra que llegó' || E'\n' ||
         '/proveedores — proveedores y última compra' || E'\n' ||
         '/cobrar — cuentas abiertas por cobrar' || E'\n' ||
         '/caja — estado de la caja del día' || E'\n' ||
         '/portal — enlace para entrar al portal' || E'\n' ||
         '/sesiones — sesiones abiertas en el portal' || E'\n' ||
         '/ayuda — esta ayuda';
$$;


-- ---------------------------------------------------------------------
-- 11. Permisos de base de datos
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON ia_mensaje, ia_accion_pendiente TO chasquipet_app;
GRANT SELECT ON ia_herramienta TO chasquipet_app;
GRANT USAGE, SELECT ON SEQUENCE ia_mensaje_id_seq TO chasquipet_app;
GRANT SELECT ON ia_mensaje, ia_accion_pendiente, ia_herramienta TO chasquipet_lectura;
