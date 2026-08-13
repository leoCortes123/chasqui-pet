-- =====================================================================
-- Chasqui Pet — 190_remisiones.sql
-- Ámbito: VERTICAL (remisiones externas y resultados; convención A7a).
--
-- Fase B3 del plan de consolidación: perseguir lo que se mandó afuera.
--
-- El estado del que se parte: `consulta.remision_externa` (`050:200`) es
-- una columna de texto libre dentro de la consulta. Sirve para escribir
-- «se remite a laboratorio para hemograma» y para nada más. No hay
-- destino, no hay estado, no hay fecha esperada y, sobre todo, **no hay
-- forma de preguntar qué se mandó y todavía no volvió**. Un examen que se
-- pierde en el camino solo se descubre cuando el dueño llama a reclamar,
-- y `reporte_pacientes` (`080:328`) apenas mide, meses después, si el
-- paciente volvió.
--
-- Lo que hace esta fase:
--
--   1. **`remision`** — qué se pidió, a quién, para qué mascota, desde qué
--      consulta, cuándo debería volver y en qué estado está
--      (`pendiente → recibida`, o `anulada`).
--   2. **`resultado_remision`** — lo que llegó: texto, foto o archivo, con
--      quién lo cargó. Varios por remisión, porque un laboratorio manda
--      dos hojas sin avisar.
--   3. **Alerta de vencidas**: la remisión que pasó su fecha esperada sin
--      resultado se le informa cada mañana a quien puede llamar al
--      laboratorio. Mismo patrón que `alertas_inventario` (`045:722`).
--   4. **Aviso al dueño cuando el resultado llega**, reutilizando la tarea
--      `enviar_aviso_dueno` de la Fase 5 y sus tres capas de validación de
--      consentimiento (Ley 1581, §12).
--
-- `consulta.remision_externa` **no se toca ni se migra**: sigue siendo la
-- nota clínica que el veterinario escribe dentro de la consulta, y una
-- consulta firmada es inmutable. La remisión es el seguimiento
-- administrativo de esa nota, no su reemplazo; se enlazan por
-- `remision.consulta_id`.
--
-- Sobre los resultados y el append-only: un resultado de laboratorio es
-- registro clínico. No se edita ni se borra — si llega uno corregido, se
-- carga otro y quedan los dos, con su fecha y su autor. Es la misma
-- decisión que `movimiento_inventario`, `pago` y la consulta firmada.
-- =====================================================================

SET client_min_messages = warning;

INSERT INTO config (clave, valor, tipo, descripcion, editable_ui) VALUES
  ('remision_dias_espera', '5', 'entero',
   'Días que se espera un resultado externo antes de considerar la remisión vencida', true)
ON CONFLICT (clave) DO NOTHING;


-- ---------------------------------------------------------------------
-- 1. Las dos tablas
--
-- `destino` es texto y no un catálogo de laboratorios a propósito: el
-- alcance de la fase son la remisión y su resultado. Un catálogo de
-- destinos con contacto y horarios es otra cosa, y hasta que la clínica
-- lo pida sería inventar una tabla para no usarla.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS remision (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  paciente_id    uuid NOT NULL REFERENCES paciente(id),
  dueno_id       uuid REFERENCES dueno(id),
  consulta_id    uuid REFERENCES consulta(id),
  sede_id        uuid REFERENCES sede(id),

  tipo           text NOT NULL DEFAULT 'laboratorio'
                   CHECK (tipo IN ('laboratorio','imagenes','especialista','otro')),
  destino        text NOT NULL,          -- «Lab. Veterinario del Norte», «Dr. Peña»
  examenes       text NOT NULL,          -- qué se pidió, como lo dicta el mostrador
  motivo         text,

  estado         text NOT NULL DEFAULT 'pendiente'
                   CHECK (estado IN ('pendiente','recibida','anulada')),
  fecha_solicitud date NOT NULL DEFAULT hoy_bogota(),
  fecha_esperada  date,                  -- cuándo debería estar de vuelta

  recibida_at    timestamptz,
  recibida_por   uuid REFERENCES usuario(id),
  anulada_at     timestamptz,
  anulada_por    uuid REFERENCES usuario(id),
  motivo_anulacion text,

  -- Sello del aviso al dueño: se avisa UNA vez aunque lleguen dos hojas.
  aviso_dueno_at timestamptz,

  solicitada_por uuid REFERENCES usuario(id),
  canal_origen   text NOT NULL DEFAULT 'telegram'
                   CHECK (canal_origen IN ('telegram','web','sistema')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'remision_touch') THEN
    CREATE TRIGGER remision_touch BEFORE UPDATE ON remision
      FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
  END IF;
END $$;

-- El índice que sostiene la pregunta de la fase: «¿qué está pendiente?».
CREATE INDEX IF NOT EXISTS idx_remision_pendiente
  ON remision (sede_id, fecha_esperada) WHERE estado = 'pendiente';
CREATE INDEX IF NOT EXISTS idx_remision_paciente
  ON remision (paciente_id, fecha_solicitud DESC);

COMMENT ON TABLE remision IS
  'Examen o interconsulta enviada afuera y su seguimiento hasta que vuelve (Fase B3).';
COMMENT ON COLUMN remision.aviso_dueno_at IS
  'Sello del aviso al dueño. Un resultado corregido no vuelve a avisarle.';

CREATE TABLE IF NOT EXISTS resultado_remision (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  remision_id     uuid NOT NULL REFERENCES remision(id),
  texto           text,
  -- Igual que la factura de una entrada (`070:74`): el file_id es lo que
  -- la Bot API necesita para reenviar el archivo; la URL es para lo que
  -- se carga desde el portal.
  adjunto_file_id text,
  adjunto_url     text,
  cargado_por     uuid REFERENCES usuario(id),
  canal           text NOT NULL DEFAULT 'telegram'
                    CHECK (canal IN ('telegram','web','sistema')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- Un resultado sin nada dentro no es un resultado.
  CHECK (texto IS NOT NULL OR adjunto_file_id IS NOT NULL OR adjunto_url IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_resultado_remision
  ON resultado_remision (remision_id, created_at);

COMMENT ON TABLE resultado_remision IS
  'Lo que volvió de una remisión: texto, foto o archivo. Append-only: un resultado corregido se agrega, no reemplaza (Fase B3).';

-- Append-only real, como en 090_grants: la aplicación puede insertar y
-- leer, nunca actualizar ni borrar. Un resultado clínico mal cargado se
-- corrige cargando otro, igual que un pago se corrige con un reverso.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chasquipet_app') THEN
    REVOKE UPDATE, DELETE, TRUNCATE ON resultado_remision FROM chasquipet_app;
    GRANT SELECT, INSERT ON resultado_remision TO chasquipet_app;
    GRANT SELECT ON resultado_remision TO chasquipet_lectura;
    GRANT SELECT ON remision TO chasquipet_lectura;
  END IF;
END $$;


-- ---------------------------------------------------------------------
-- 2. Permisos
--
-- `remision.gestionar` incluye cargar el resultado: quien recibe el sobre
-- del laboratorio en el mostrador es quien lo digita, y separar eso en un
-- tercer permiso solo conseguiría que nadie lo tuviera.
-- ---------------------------------------------------------------------
INSERT INTO permiso (codigo, modulo, descripcion) VALUES
  ('remision.ver',       'clinico', 'Ver remisiones externas y sus resultados'),
  ('remision.gestionar', 'clinico', 'Crear remisiones, cargar resultados y anularlas')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO rol_permiso (rol_codigo, permiso_codigo) VALUES
  ('superadmin',  'remision.ver'),
  ('superadmin',  'remision.gestionar'),
  ('admin',       'remision.ver'),
  ('admin',       'remision.gestionar'),
  ('veterinario', 'remision.ver'),
  ('veterinario', 'remision.gestionar'),
  ('auxiliar',    'remision.ver'),
  ('auxiliar',    'remision.gestionar'),
  ('recepcion',   'remision.ver'),
  ('recepcion',   'remision.gestionar')
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------
-- 3. Presentación
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION remision_json(p_remision_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'remision_id',   r.id,
    'estado',        r.estado,
    'tipo',          r.tipo,
    'destino',       r.destino,
    'examenes',      r.examenes,
    'motivo',        r.motivo,
    'paciente_id',   r.paciente_id,
    'paciente',      p.nombre,
    'especie',       p.especie,
    'emoji',         emoji_especie(p.especie),
    'dueno_id',      r.dueno_id,
    'dueno',         d.nombre_completo,
    'telefono',      d.telefono,
    'consulta_id',   r.consulta_id,
    'fecha_solicitud', r.fecha_solicitud,
    'fecha_esperada',  r.fecha_esperada,
    'dias_esperando',  hoy_bogota() - r.fecha_solicitud,
    'vencida',       r.estado = 'pendiente' AND r.fecha_esperada IS NOT NULL
                     AND r.fecha_esperada < hoy_bogota(),
    'solicitada_por', u.nombre_completo,
    'motivo_anulacion', r.motivo_anulacion,
    'avisado',       r.aviso_dueno_at IS NOT NULL,
    'resultados', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'resultado_id', x.id,
               'texto', x.texto,
               'tiene_adjunto', (x.adjunto_file_id IS NOT NULL OR x.adjunto_url IS NOT NULL),
               'adjunto_file_id', x.adjunto_file_id,
               'adjunto_url', x.adjunto_url,
               'cargado_por', (SELECT nombre_completo FROM usuario WHERE id = x.cargado_por),
               'cargado_at', to_char(x.created_at AT TIME ZONE 'America/Bogota',
                                     'DD/MM/YYYY HH24:MI'))
             ORDER BY x.created_at)
        FROM resultado_remision x WHERE x.remision_id = r.id), '[]'::jsonb))
  FROM remision r
  JOIN paciente p ON p.id = r.paciente_id
  LEFT JOIN dueno d ON d.id = r.dueno_id
  LEFT JOIN usuario u ON u.id = r.solicitada_por
 WHERE r.id = p_remision_id;
$$;


-- ---------------------------------------------------------------------
-- 4. crear_remision
--
-- Si viene `consulta_id`, todo lo demás —mascota, dueño, sede, quién la
-- pidió— sale de la consulta: en el mostrador nadie va a volver a digitar
-- lo que ya está escrito.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_remision(
  p_actor uuid,
  p_args  jsonb,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_consulta consulta;
  v_pac      uuid := NULLIF(p_args->>'paciente_id', '')::uuid;
  v_destino  text := NULLIF(trim(COALESCE(p_args->>'destino', '')), '');
  v_examenes text := NULLIF(trim(COALESCE(p_args->>'examenes', '')), '');
  v_tipo     text := COALESCE(NULLIF(p_args->>'tipo', ''), 'laboratorio');
  v_dueno    uuid;
  v_sede     uuid;
  v_esperada date;
  v_id       uuid;
BEGIN
  PERFORM exigir_permiso(p_actor, 'remision.gestionar');

  IF NULLIF(p_args->>'consulta_id', '') IS NOT NULL THEN
    SELECT * INTO v_consulta FROM consulta WHERE id = (p_args->>'consulta_id')::uuid;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'motivo', 'sin_consulta',
               'mensaje', 'Esa consulta no existe.');
    END IF;
    v_pac := COALESCE(v_pac, v_consulta.paciente_id);
  END IF;

  IF v_pac IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_paciente',
             'mensaje', 'Una remisión necesita la mascota que se remite.');
  END IF;

  SELECT dueno_id INTO v_dueno FROM paciente WHERE id = v_pac AND estado = 'activo';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'paciente_inexistente',
             'mensaje', 'Esa mascota no existe o está inactiva.');
  END IF;

  IF v_destino IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_destino',
             'mensaje', '¿A dónde se remite? Escribe el laboratorio o el especialista.');
  END IF;

  IF v_examenes IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_examenes',
             'mensaje', '¿Qué se pidió? Escribe los exámenes o el motivo de la interconsulta.');
  END IF;

  IF v_tipo NOT IN ('laboratorio','imagenes','especialista','otro') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'tipo_invalido',
             'mensaje', 'El tipo de remisión debe ser laboratorio, imagenes, especialista u otro.');
  END IF;

  v_sede := COALESCE(v_consulta.sede_id,
                     (SELECT sede_id FROM usuario WHERE id = p_actor),
                     (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1));

  -- La fecha esperada es lo que después convierte una remisión olvidada en
  -- una alerta. Si nadie la dice, la pone la configuración.
  v_esperada := COALESCE(NULLIF(p_args->>'fecha_esperada', '')::date,
                         hoy_bogota() + config_int('remision_dias_espera', 5));

  INSERT INTO remision (paciente_id, dueno_id, consulta_id, sede_id, tipo, destino,
                        examenes, motivo, fecha_esperada, solicitada_por, canal_origen)
  VALUES (v_pac, v_dueno, v_consulta.id, v_sede, v_tipo, v_destino, v_examenes,
          NULLIF(trim(COALESCE(p_args->>'motivo', '')), ''), v_esperada,
          COALESCE(v_consulta.veterinario_id, p_actor),
          CASE WHEN p_canal IN ('telegram','web','sistema') THEN p_canal ELSE 'sistema' END)
  RETURNING id INTO v_id;

  PERFORM auditar('remision', v_id::text, 'crear', p_actor, p_canal, NULL,
                  jsonb_build_object('paciente_id', v_pac, 'destino', v_destino,
                                     'tipo', v_tipo, 'fecha_esperada', v_esperada));

  RETURN jsonb_build_object('ok', true, 'remision', remision_json(v_id),
           'mensaje', 'Remisión registrada.');
END;
$$;


-- ---------------------------------------------------------------------
-- 5. registrar_resultado — lo que volvió
--
-- Cargar un resultado cierra la remisión y, si el dueño autorizó el
-- contacto, le avisa. El aviso va por `tarea_async` (C6.7): el que digita
-- el resultado no tiene por qué esperar a que Telegram responda.
--
-- Se puede cargar más de un resultado: los laboratorios mandan la
-- corrección al día siguiente. El segundo NO vuelve a avisar al dueño
-- —`aviso_dueno_at` es el sello— y la remisión ya estaba cerrada.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION registrar_resultado(
  p_actor uuid,
  p_remision_id uuid,
  p_args  jsonb DEFAULT '{}'::jsonb,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_r      remision;
  v_texto  text := NULLIF(trim(COALESCE(p_args->>'texto', '')), '');
  v_file   text := NULLIF(p_args->>'file_id', '');
  v_url    text := NULLIF(p_args->>'url', '');
  v_dueno  dueno%ROWTYPE;
  v_res    uuid;
  v_aviso  boolean := false;
  v_pac    text;
BEGIN
  PERFORM exigir_permiso(p_actor, 'remision.gestionar');

  SELECT * INTO v_r FROM remision WHERE id = p_remision_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_remision',
             'mensaje', 'Esa remisión no existe.');
  END IF;

  IF v_r.estado = 'anulada' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'remision_anulada',
             'mensaje', 'Esa remisión está anulada: no admite resultados.');
  END IF;

  IF v_texto IS NULL AND v_file IS NULL AND v_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'resultado_vacio',
             'mensaje', 'Escribe el resultado o adjunta el archivo que llegó.');
  END IF;

  INSERT INTO resultado_remision (remision_id, texto, adjunto_file_id, adjunto_url,
                                  cargado_por, canal)
  VALUES (p_remision_id, v_texto, v_file, v_url, p_actor,
          CASE WHEN p_canal IN ('telegram','web','sistema') THEN p_canal ELSE 'sistema' END)
  RETURNING id INTO v_res;

  -- Ley 1581 (§12): el aviso solo sale si el dueño autorizó el contacto y
  -- tenemos su chat. Se comprueba aquí para no encolar lo que no se puede
  -- enviar, y el worker lo vuelve a comprobar al enviar.
  SELECT * INTO v_dueno FROM dueno WHERE id = v_r.dueno_id AND activo;
  SELECT nombre INTO v_pac FROM paciente WHERE id = v_r.paciente_id;

  IF v_r.aviso_dueno_at IS NULL
     AND v_dueno.id IS NOT NULL
     AND v_dueno.consentimiento_datos
     AND v_dueno.telegram_chat_id IS NOT NULL THEN
    PERFORM encolar_tarea('enviar_aviso_dueno',
      jsonb_build_object('dueno_id', v_dueno.id,
        'mensaje', format('Ya llegaron los resultados de %s (%s). '
                          'Comuníquese con nosotros para explicárselos.',
                          v_pac, v_r.examenes)),
      5, 'resultado_remision_' || p_remision_id::text, 0, 3);
    v_aviso := true;
  END IF;

  UPDATE remision
     SET estado       = 'recibida',
         recibida_at  = COALESCE(recibida_at, now()),
         recibida_por = COALESCE(recibida_por, p_actor),
         aviso_dueno_at = CASE WHEN v_aviso THEN now() ELSE aviso_dueno_at END
   WHERE id = p_remision_id;

  PERFORM auditar('remision', p_remision_id::text, 'resultado', p_actor, p_canal,
                  jsonb_build_object('estado', v_r.estado),
                  jsonb_build_object('estado', 'recibida', 'resultado_id', v_res,
                                     'aviso_dueno', v_aviso));

  RETURN jsonb_build_object('ok', true, 'remision', remision_json(p_remision_id),
           'aviso_dueno', v_aviso,
           'mensaje', CASE WHEN v_aviso
                           THEN 'Resultado guardado. Se le avisó al dueño.'
                           ELSE 'Resultado guardado.' END);
END;
$$;


-- ---------------------------------------------------------------------
-- 6. anular_remision — solo lo que aún no volvió
--
-- Si el resultado ya llegó, la remisión cumplió: no hay nada que anular.
-- Se anula lo que se pidió por error o lo que el dueño decidió no hacer.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION anular_remision(
  p_actor uuid,
  p_remision_id uuid,
  p_motivo text DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  PERFORM exigir_permiso(p_actor, 'remision.gestionar');

  SELECT estado INTO v_estado FROM remision WHERE id = p_remision_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_remision',
             'mensaje', 'Esa remisión no existe.');
  END IF;

  IF v_estado = 'anulada' THEN
    RETURN jsonb_build_object('ok', true, 'ya_estaba', true,
             'remision', remision_json(p_remision_id),
             'mensaje', 'Esa remisión ya estaba anulada.');
  END IF;

  IF v_estado = 'recibida' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'remision_recibida',
             'mensaje', 'Esa remisión ya tiene resultado: no se anula.');
  END IF;

  UPDATE remision
     SET estado = 'anulada', anulada_at = now(), anulada_por = p_actor,
         motivo_anulacion = NULLIF(trim(COALESCE(p_motivo, '')), '')
   WHERE id = p_remision_id;

  PERFORM auditar('remision', p_remision_id::text, 'anular', p_actor, p_canal,
                  jsonb_build_object('estado', v_estado),
                  jsonb_build_object('estado', 'anulada'), p_motivo);

  RETURN jsonb_build_object('ok', true, 'remision', remision_json(p_remision_id),
           'mensaje', 'Remisión anulada.');
END;
$$;


-- ---------------------------------------------------------------------
-- 7. remisiones_pendientes — qué se mandó y no ha vuelto
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION remisiones_pendientes(
  p_actor uuid,
  p_sede_id uuid DEFAULT NULL,
  p_limite int DEFAULT 30
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_sede uuid;
  v_l    jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor, 'remision.ver');

  v_sede := COALESCE(p_sede_id,
                     (SELECT sede_id FROM usuario WHERE id = p_actor),
                     (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1));

  SELECT COALESCE(jsonb_agg(remision_json(r.id)
                            ORDER BY r.fecha_esperada NULLS LAST, r.fecha_solicitud), '[]'::jsonb)
    INTO v_l
    FROM (SELECT id, fecha_esperada, fecha_solicitud
            FROM remision
           WHERE estado = 'pendiente'
             AND COALESCE(sede_id, v_sede) = v_sede
           ORDER BY fecha_esperada NULLS LAST, fecha_solicitud
           LIMIT GREATEST(COALESCE(p_limite, 30), 1)) r;

  RETURN jsonb_build_object('ok', true, 'sede_id', v_sede,
    'remisiones', v_l,
    'total', jsonb_array_length(v_l),
    'vencidas', (SELECT count(*) FROM jsonb_array_elements(v_l) e
                  WHERE (e->>'vencida')::boolean));
END;
$$;


-- ---------------------------------------------------------------------
-- 8. La alerta diaria — mismo patrón que `alertas_inventario`
--
-- `hay_alertas_remisiones` solo dice que sí cuando hay VENCIDAS. Una
-- remisión pendiente dentro de plazo es el curso normal de las cosas, y
-- un «todo en orden» cada mañana es la forma más rápida de que dejen de
-- leerse las alertas (mismo razonamiento que `045:759`).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION alertas_remisiones()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'fecha', hoy_bogota(),
    'vencidas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'remision_id', r.id, 'paciente', p.nombre, 'destino', r.destino,
               'examenes', r.examenes, 'esperada', r.fecha_esperada,
               'dias_vencida', hoy_bogota() - r.fecha_esperada,
               'dueno', d.nombre_completo, 'telefono', d.telefono)
             ORDER BY r.fecha_esperada)
        FROM remision r
        JOIN paciente p ON p.id = r.paciente_id
        LEFT JOIN dueno d ON d.id = r.dueno_id
       WHERE r.estado = 'pendiente'
         AND r.fecha_esperada IS NOT NULL
         AND r.fecha_esperada < hoy_bogota()), '[]'::jsonb),
    'pendientes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'remision_id', r.id, 'paciente', p.nombre, 'destino', r.destino,
               'esperada', r.fecha_esperada)
             ORDER BY r.fecha_esperada NULLS LAST)
        FROM remision r
        JOIN paciente p ON p.id = r.paciente_id
       WHERE r.estado = 'pendiente'
         AND (r.fecha_esperada IS NULL OR r.fecha_esperada >= hoy_bogota())), '[]'::jsonb));
$$;

CREATE OR REPLACE FUNCTION hay_alertas_remisiones()
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT (alertas_remisiones()->'vencidas') <> '[]'::jsonb;
$$;

-- El texto lo arma la BASE y no el worker, igual que el de inventario:
-- así el mensaje se puede revisar con psql y no hay dos versiones del
-- formato.
CREATE OR REPLACE FUNCTION bot_texto_alertas_remisiones()
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  a       jsonb := alertas_remisiones();
  v_texto text;
  x       jsonb;
BEGIN
  v_texto := '🏥 <b>Remisiones sin resultado</b>';

  FOR x IN SELECT * FROM jsonb_array_elements(a->'vencidas') LIMIT 15 LOOP
    v_texto := v_texto || E'\n' ||
      '⚠️ <b>' || esc(x->>'paciente') || '</b> · ' || esc(x->>'destino') || E'\n' ||
      '   ' || esc(x->>'examenes') || ' · esperada el ' ||
      to_char((x->>'esperada')::date, 'DD/MM') ||
      ' (' || (x->>'dias_vencida') || ' días)' ||
      COALESCE(E'\n' || '   📞 ' || esc(x->>'dueno') ||
               COALESCE(' · ' || esc(x->>'telefono'), ''), '');
  END LOOP;

  IF jsonb_array_length(a->'pendientes') > 0 THEN
    v_texto := v_texto || E'\n\n' ||
      'Dentro de plazo: ' || jsonb_array_length(a->'pendientes') || '.';
  END IF;

  RETURN v_texto;
END;
$$;

GRANT EXECUTE ON FUNCTION remision_json(uuid)                              TO chasquipet_app;
GRANT EXECUTE ON FUNCTION crear_remision(uuid, jsonb, text)                TO chasquipet_app;
GRANT EXECUTE ON FUNCTION registrar_resultado(uuid, uuid, jsonb, text)     TO chasquipet_app;
GRANT EXECUTE ON FUNCTION anular_remision(uuid, uuid, text, text)          TO chasquipet_app;
GRANT EXECUTE ON FUNCTION remisiones_pendientes(uuid, uuid, int)           TO chasquipet_app;
GRANT EXECUTE ON FUNCTION alertas_remisiones()                             TO chasquipet_app;
GRANT EXECUTE ON FUNCTION hay_alertas_remisiones()                         TO chasquipet_app;
GRANT EXECUTE ON FUNCTION bot_texto_alertas_remisiones()                   TO chasquipet_app;


-- =====================================================================
-- 9. El bot
-- =====================================================================

CREATE OR REPLACE FUNCTION bot_rem_menu(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_n int;
BEGIN
  IF NOT tiene_permiso(p_usuario_id, 'remision.ver') THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT count(*) INTO v_n FROM remision WHERE estado = 'pendiente';
  IF COALESCE(v_n, 0) = 0 THEN
    RETURN '[]'::jsonb;   -- sin nada que perseguir, no ocupa sitio en el menú
  END IF;

  RETURN jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '🏥 Remisiones (' || v_n || ')', 'd', 'rem:lista')));
END;
$$;

CREATE OR REPLACE FUNCTION bot_rem_lista(p_usuario_id uuid, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_r     jsonb := remisiones_pendientes(p_usuario_id, p_sede_id, 10);
  v_texto text;
  v_bot   jsonb := '[]'::jsonb;
  x       jsonb;
BEGIN
  v_texto := '🏥 <b>Remisiones sin resultado</b>';

  IF (v_r->>'total')::int = 0 THEN
    v_texto := v_texto || E'\n' || 'No hay nada pendiente de volver.';
  END IF;

  FOR x IN SELECT * FROM jsonb_array_elements(v_r->'remisiones') LOOP
    v_texto := v_texto || E'\n' ||
      CASE WHEN (x->>'vencida')::boolean THEN '⚠️' ELSE '⏳' END || ' ' ||
      esc(x->>'emoji') || ' <b>' || esc(x->>'paciente') || '</b> · ' ||
      esc(x->>'destino') || E'\n' ||
      '   ' || esc(x->>'examenes') ||
      CASE WHEN (x->>'vencida')::boolean
           THEN ' · <i>vencida</i>' ELSE '' END;

    v_bot := v_bot || jsonb_build_array(jsonb_build_object(
      't', (x->>'emoji') || ' ' || (x->>'paciente') || ' · ' || (x->>'destino'),
      'd', 'rem:ver:' || (x->>'remision_id')));
  END LOOP;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '⬅️ Menú', 'd', 'rem:salir')));

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_bot);
END;
$$;

CREATE OR REPLACE FUNCTION bot_rem_ficha(p_remision_id uuid, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  j     jsonb := remision_json(p_remision_id);
  v_bot jsonb := '[]'::jsonb;
  v_txt text;
  x     jsonb;
BEGIN
  IF j IS NULL THEN
    RETURN jsonb_build_object('texto', '⚠️ Esa remisión ya no existe.',
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'rem:salir'))));
  END IF;

  v_txt := '🏥 <b>Remisión</b> · ' || esc(j->>'destino') || E'\n' ||
    esc(j->>'emoji') || ' ' || esc(j->>'paciente') ||
    COALESCE(' · ' || esc(j->>'dueno'), '') || E'\n' ||
    '🔬 ' || esc(j->>'examenes') || E'\n' ||
    '📅 Enviada el ' || to_char((j->>'fecha_solicitud')::date, 'DD/MM/YYYY') ||
    COALESCE(' · esperada el ' ||
             to_char((j->>'fecha_esperada')::date, 'DD/MM/YYYY'), '') || E'\n' ||
    'Estado: <b>' || esc(j->>'estado') || '</b>' ||
    CASE WHEN (j->>'vencida')::boolean THEN ' ⚠️ <i>vencida</i>' ELSE '' END ||
    COALESCE(E'\n' || '📝 ' || esc(j->>'motivo'), '');

  FOR x IN SELECT * FROM jsonb_array_elements(j->'resultados') LOOP
    v_txt := v_txt || E'\n\n' || '✅ <b>Resultado</b> · ' || esc(x->>'cargado_at') ||
      COALESCE(' · ' || esc(x->>'cargado_por'), '') ||
      COALESCE(E'\n' || esc(x->>'texto'), '') ||
      CASE WHEN (x->>'tiene_adjunto')::boolean THEN E'\n' || '📎 Con archivo adjunto.' ELSE '' END;
  END LOOP;

  IF tiene_permiso(p_usuario_id, 'remision.gestionar') AND j->>'estado' = 'pendiente' THEN
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '✅ Cargar resultado', 'd', 'rem:res:' || p_remision_id),
      jsonb_build_object('t', '✖️ Anular', 'd', 'rem:anular:' || p_remision_id)));
  ELSIF tiene_permiso(p_usuario_id, 'remision.gestionar') AND j->>'estado' = 'recibida' THEN
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '➕ Otro resultado', 'd', 'rem:res:' || p_remision_id)));
  END IF;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '⬅️ Remisiones', 'd', 'rem:lista')));

  RETURN jsonb_build_object('texto', v_txt, 'botones', v_bot);
END;
$$;

CREATE OR REPLACE FUNCTION bot_rem_callback(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje_id bigint, p_data text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_partes text[] := string_to_array(p_data, ':');
  v_vista  jsonb;
  v_alerta text := NULL;
BEGIN
  IF v_partes[1] IS DISTINCT FROM 'rem' THEN
    RETURN NULL;
  END IF;

  CASE v_partes[2]

    WHEN 'lista' THEN
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_rem_lista(p_usuario_id, p_sede_id);

    WHEN 'ver' THEN
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_rem_ficha(v_partes[3]::uuid, p_usuario_id);

    -- El resultado se recibe como el siguiente mensaje del chat: texto, o
    -- la foto de la hoja que mandó el laboratorio. Por eso el estado queda
    -- esperando, y `bot_rem_media` mira el mismo paso.
    WHEN 'res' THEN
      PERFORM exigir_permiso(p_usuario_id, 'remision.gestionar');
      PERFORM estado_guardar(p_chat_id, 'remision', 'resultado',
                jsonb_build_object('remision_id', v_partes[3]), p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '✅ <b>Cargar resultado</b>' || E'\n' ||
        'Escríbeme el resultado, o mándame la foto o el archivo que llegó del laboratorio.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'rem:ver:' || v_partes[3]))));

    WHEN 'anular' THEN
      PERFORM exigir_permiso(p_usuario_id, 'remision.gestionar');
      PERFORM estado_guardar(p_chat_id, 'remision', 'motivo_anular',
                jsonb_build_object('remision_id', v_partes[3]), p_usuario_id, p_mensaje_id);
      v_vista := jsonb_build_object('texto',
        '✖️ <b>Anular la remisión</b>' || E'\n' ||
        'Escribe por qué se anula. Queda registrado.',
        'botones', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('t', '⬅️ Volver', 'd', 'rem:ver:' || v_partes[3]))));

    WHEN 'salir' THEN
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_menu_principal(p_usuario_id);

    ELSE
      v_alerta := 'Esa opción ya no está disponible.';
      v_vista := bot_menu_principal(p_usuario_id);
  END CASE;

  RETURN jsonb_build_object(
    'alerta', v_alerta,
    'acciones', jsonb_build_array(
      accion_editar(p_chat_id, p_mensaje_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;

CREATE OR REPLACE FUNCTION bot_rem_texto(
  p_usuario_id uuid, p_chat_id bigint, p_texto text, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado jsonb := estado_leer(p_chat_id);
  v_datos  jsonb := COALESCE(v_estado->'datos', '{}'::jsonb);
  v_rem    uuid  := NULLIF(v_datos->>'remision_id', '')::uuid;
  v_vista  jsonb;
  v_r      jsonb;
BEGIN
  IF p_texto IN ('/remisiones', 'remisiones') AND tiene_permiso(p_usuario_id, 'remision.ver') THEN
    PERFORM estado_limpiar(p_chat_id);
    v_vista := bot_rem_lista(p_usuario_id, p_sede_id);
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
  END IF;

  IF v_estado->>'flujo' IS DISTINCT FROM 'remision' THEN
    RETURN NULL;
  END IF;

  CASE v_estado->>'paso'

    WHEN 'resultado' THEN
      v_r := registrar_resultado(p_usuario_id, v_rem,
                                 jsonb_build_object('texto', p_texto), 'telegram');
      IF (v_r->>'ok')::boolean THEN
        PERFORM estado_limpiar(p_chat_id);
        v_vista := bot_rem_ficha(v_rem, p_usuario_id);
        v_vista := jsonb_set(v_vista, '{texto}',
          to_jsonb('✅ ' || esc(v_r->>'mensaje') || E'\n\n' || (v_vista->>'texto')));
      ELSE
        v_vista := jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
          'botones', jsonb_build_array(jsonb_build_array(
            jsonb_build_object('t', '⬅️ Volver', 'd', 'rem:ver:' || v_rem))));
      END IF;

    WHEN 'motivo_anular' THEN
      v_r := anular_remision(p_usuario_id, v_rem, p_texto, 'telegram');
      PERFORM estado_limpiar(p_chat_id);
      v_vista := bot_rem_ficha(v_rem, p_usuario_id);
      IF NOT (v_r->>'ok')::boolean THEN
        v_vista := jsonb_set(v_vista, '{texto}',
          to_jsonb('⚠️ ' || esc(v_r->>'mensaje') || E'\n\n' || (v_vista->>'texto')));
      END IF;

    ELSE
      RETURN NULL;
  END CASE;

  RETURN jsonb_build_object('acciones', jsonb_build_array(
    accion_enviar(p_chat_id, v_vista->>'texto', v_vista->'botones')));
END;
$$;

-- La hoja del laboratorio llega como foto. Mismo tratamiento que la
-- factura de una entrada (`076:787`): Telegram manda la foto en varios
-- tamaños y el último es el de mayor resolución.
CREATE OR REPLACE FUNCTION bot_rem_media(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje jsonb, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado  jsonb := estado_leer(p_chat_id);
  v_rem     uuid;
  v_file_id text;
  v_vista   jsonb;
  v_r       jsonb;
BEGIN
  IF v_estado->>'flujo' IS DISTINCT FROM 'remision'
     OR v_estado->>'paso' IS DISTINCT FROM 'resultado' THEN
    RETURN NULL;
  END IF;

  v_rem := NULLIF(v_estado->'datos'->>'remision_id', '')::uuid;

  v_file_id := COALESCE(
    (SELECT x->>'file_id' FROM jsonb_array_elements(p_mensaje->'photo') x
      ORDER BY (x->>'file_size')::bigint DESC NULLS LAST LIMIT 1),
    p_mensaje->'document'->>'file_id');

  IF v_file_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_r := registrar_resultado(p_usuario_id, v_rem, jsonb_build_object(
           'file_id', v_file_id,
           'texto', NULLIF(trim(COALESCE(p_mensaje->>'caption', '')), '')), 'telegram');

  IF NOT (v_r->>'ok')::boolean THEN
    RETURN jsonb_build_object('acciones', jsonb_build_array(
      accion_enviar(p_chat_id, '⚠️ ' || esc(v_r->>'mensaje'))));
  END IF;

  PERFORM estado_limpiar(p_chat_id);
  v_vista := bot_rem_ficha(v_rem, p_usuario_id);

  RETURN jsonb_build_object('acciones', jsonb_build_array(
    accion_enviar(p_chat_id, '📎 ' || esc(v_r->>'mensaje') || E'\n\n' || (v_vista->>'texto'),
                  v_vista->'botones')));
END;
$$;


-- =====================================================================
-- 10. El asistente
--
-- Una lectura y una escritura. La escritura con borrador propio, como
-- todas las que normalizan lenguaje de mostrador, y con confirmación
-- humana obligatoria (C6.9).
-- =====================================================================
CREATE OR REPLACE FUNCTION op_remisiones_pendientes(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'datos',
    COALESCE(remisiones_pendientes(p_actor, p_sede,
               COALESCE((p_args->>'limite')::int, 30)), 'null'::jsonb));
$$;

CREATE OR REPLACE FUNCTION op_registrar_remision(p_actor uuid, p_sede uuid, p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT crear_remision(p_actor, p_args, 'telegram');
$$;

CREATE OR REPLACE FUNCTION ia_remision_borrador(
  p_usuario_id uuid, p_chat_id bigint, p_sede_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_pac      uuid := NULLIF(p_args->>'paciente_id', '')::uuid;
  v_destino  text := NULLIF(trim(COALESCE(p_args->>'destino', '')), '');
  v_examenes text := NULLIF(trim(COALESCE(p_args->>'examenes', '')), '');
  v_tipo     text := COALESCE(NULLIF(p_args->>'tipo', ''), 'laboratorio');
  v_esperada date;
  v_pacnom   text;
  v_dueno    text;
  v_resumen  text;
  v_accion   uuid;
BEGIN
  PERFORM exigir_permiso(p_usuario_id, 'remision.gestionar');

  IF v_pac IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta la mascota. Usa buscar_paciente y pasa su paciente_id.');
  END IF;

  SELECT p.nombre, d.nombre_completo INTO v_pacnom, v_dueno
    FROM paciente p LEFT JOIN dueno d ON d.id = p.dueno_id
   WHERE p.id = v_pac AND p.estado = 'activo';
  IF v_pacnom IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Esa mascota no existe o está inactiva.');
  END IF;

  IF v_destino IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta a dónde se remite: el laboratorio o el especialista. Pregúntaselo al usuario.');
  END IF;

  IF v_examenes IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Falta qué se pidió: los exámenes o el motivo de la interconsulta.');
  END IF;

  IF v_tipo NOT IN ('laboratorio','imagenes','especialista','otro') THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'El tipo debe ser laboratorio, imagenes, especialista u otro.');
  END IF;

  v_esperada := COALESCE(NULLIF(p_args->>'fecha_esperada', '')::date,
                         hoy_bogota() + config_int('remision_dias_espera', 5));

  v_resumen := '🏥 <b>Remisión externa</b>' || E'\n' ||
               '🐾 ' || esc(v_pacnom) || COALESCE(' · ' || esc(v_dueno), '') || E'\n' ||
               '📍 ' || esc(v_destino) || ' (' || esc(v_tipo) || ')' || E'\n' ||
               '🔬 ' || esc(v_examenes) || E'\n' ||
               '📅 Se espera el <b>' || to_char(v_esperada, 'DD/MM/YYYY') || '</b>' ||
               CASE WHEN NULLIF(p_args->>'motivo', '') IS NOT NULL
                    THEN E'\n' || '📝 ' || esc(p_args->>'motivo') ELSE '' END || E'\n\n' ||
               '<i>Queda pendiente hasta que se cargue el resultado. Si se pasa de fecha, '
               'aparece en la alerta de la mañana.</i>';

  INSERT INTO ia_accion_pendiente (chat_id, usuario_id, sede_id, herramienta, argumentos, resumen)
  VALUES (p_chat_id, p_usuario_id, p_sede_id, 'registrar_remision',
          jsonb_build_object('paciente_id', v_pac, 'destino', v_destino,
                             'examenes', v_examenes, 'tipo', v_tipo,
                             'fecha_esperada', v_esperada,
                             'motivo', NULLIF(p_args->>'motivo', ''),
                             'consulta_id', NULLIF(p_args->>'consulta_id', '')),
          v_resumen)
  RETURNING id INTO v_accion;

  RETURN jsonb_build_object('ok', true, 'requiere_confirmacion', true,
    'accion_id', v_accion, 'critica', false, 'resumen', v_resumen);
END;
$$;

INSERT INTO ia_herramienta (nombre, permiso, escribe, critica, orden, descripcion, esquema) VALUES

('remisiones_pendientes', 'remision.ver', false, false, 79,
 'Exámenes o interconsultas enviados a un laboratorio o especialista que TODAVÍA no '
 'tienen resultado, con la mascota, el destino, qué se pidió, la fecha en que se esperaba '
 'y si ya está vencida. Úsala para «qué exámenes faltan», «qué no ha llegado del '
 'laboratorio», «a quién hay que reclamarle un resultado».',
 '{"type":"object","properties":{"limite":{"type":"integer","description":"Cuántas devolver. Por defecto 30."}}}'::jsonb),

('registrar_remision', 'remision.gestionar', true, false, 80,
 'Registra que una mascota se remitió afuera: a qué laboratorio o especialista y qué se '
 'pidió. Necesita el paciente_id (búscalo antes con buscar_paciente), el destino y los '
 'exámenes. Queda pendiente hasta que alguien cargue el resultado. NO ejecuta nada: deja '
 'una propuesta que la persona confirma con un botón.',
 '{"type":"object","properties":{"paciente_id":{"type":"string","description":"UUID de la mascota, obtenido de buscar_paciente"},"destino":{"type":"string","description":"Laboratorio o especialista al que se remite"},"examenes":{"type":"string","description":"Qué se pidió: los exámenes o el motivo de la interconsulta"},"tipo":{"type":"string","description":"laboratorio, imagenes, especialista u otro. Por defecto laboratorio."},"fecha_esperada":{"type":"string","description":"Cuándo se espera el resultado, AAAA-MM-DD. Si se omite, la configurada."},"motivo":{"type":"string","description":"Contexto clínico de la remisión"},"consulta_id":{"type":"string","description":"Consulta de la que sale la remisión, si se conoce"}},"required":["paciente_id","destino","examenes"]}'::jsonb)

ON CONFLICT (nombre) DO NOTHING;

UPDATE ia_herramienta h
   SET funcion = r.funcion, funcion_borrador = r.borrador, modulo = r.modulo
  FROM (VALUES
    ('remisiones_pendientes', 'op_remisiones_pendientes', NULL,                  'clinico'),
    ('registrar_remision',    'op_registrar_remision',    'ia_remision_borrador', 'clinico')
  ) AS r(nombre, funcion, borrador, modulo)
 WHERE h.nombre = r.nombre;

GRANT EXECUTE ON FUNCTION op_remisiones_pendientes(uuid, uuid, jsonb)     TO chasquipet_app;
GRANT EXECUTE ON FUNCTION op_registrar_remision(uuid, uuid, jsonb)        TO chasquipet_app;
GRANT EXECUTE ON FUNCTION ia_remision_borrador(uuid, bigint, uuid, jsonb) TO chasquipet_app;


-- =====================================================================
-- 11. Enganches del enrutador — se añade remisiones
--
-- Reemplazo ADITIVO de las versiones de 180. `bot_modulo_media` deja de
-- ser solo de compras: se encadenan los dos con COALESCE, y cada uno
-- devuelve NULL si el chat no está en su flujo.
-- =====================================================================
CREATE OR REPLACE FUNCTION bot_menu_extra(p_usuario_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT bot_cli_menu(p_usuario_id) || bot_inv_menu(p_usuario_id)
      || bot_cob_menu(p_usuario_id) || bot_com_menu(p_usuario_id)
      || bot_age_menu(p_usuario_id) || bot_ctl_menu(p_usuario_id)
      || bot_rem_menu(p_usuario_id)
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
    bot_age_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_ctl_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_rem_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_por_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id),
    bot_auth_callback(p_usuario_id, p_chat_id, p_mensaje_id, p_data, p_sede_id));
$$;

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
    bot_age_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_ctl_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_rem_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_cli_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id),
    bot_ia_texto(p_usuario_id, p_chat_id, p_texto, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_modulo_media(
  p_usuario_id uuid, p_chat_id bigint, p_mensaje jsonb, p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT COALESCE(
    bot_rem_media(p_usuario_id, p_chat_id, p_mensaje, p_sede_id),
    bot_com_media(p_usuario_id, p_chat_id, p_mensaje, p_sede_id));
$$;

CREATE OR REPLACE FUNCTION bot_texto_ayuda(p_usuario_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT '<b>Comandos</b>' || E'\n' ||
         '/menu — menú principal' || E'\n' ||
         '/chasqui — hablar con Chasqui en lenguaje natural' || E'\n' ||
         '/cola — pacientes en espera' || E'\n' ||
         '/agenda — citas agendadas de hoy' || E'\n' ||
         '/controles — controles pendientes de agendar' || E'\n' ||
         '/remisiones — exámenes enviados sin resultado' || E'\n' ||
         '/stock — existencias y alertas de inventario' || E'\n' ||
         '/entrada — registrar una compra que llegó' || E'\n' ||
         '/proveedores — proveedores y última compra' || E'\n' ||
         '/cobrar — cuentas abiertas por cobrar' || E'\n' ||
         '/caja — estado de la caja del día' || E'\n' ||
         '/portal — enlace para entrar al portal' || E'\n' ||
         '/sesiones — sesiones abiertas en el portal' || E'\n' ||
         '/ayuda — esta ayuda';
$$;
