-- =====================================================================
-- Chasqui Pet — 030_turnos.sql
-- Cola única por orden de llegada, compartida por los dos consultorios.
-- Puntos críticos: numeración con advisory lock (§2.2.6) y selección del
-- siguiente turno con FOR UPDATE SKIP LOCKED (§2.2.5).
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Tipos de servicio. Se usan en turnos, tarifas y (fase 2) citas.
-- ---------------------------------------------------------------------
CREATE TABLE tipo_servicio (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo         text UNIQUE NOT NULL,
  nombre         text NOT NULL,
  prefijo        char(1) NOT NULL,        -- A general, V vacunación, C control, U urgencia
  prioridad_base int NOT NULL DEFAULT 0,  -- urgencia entra con prioridad > 0
  duracion_estimada_min int NOT NULL DEFAULT 15,
  visible_qr     boolean NOT NULL DEFAULT true,
  orden          int NOT NULL DEFAULT 0,
  activo         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER tipo_servicio_touch BEFORE UPDATE ON tipo_servicio
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ---------------------------------------------------------------------
-- Sesión de consultorio: qué veterinario está en qué consultorio hoy
-- ---------------------------------------------------------------------
CREATE TABLE sesion_consultorio (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consultorio_id uuid NOT NULL REFERENCES consultorio(id),
  usuario_id     uuid NOT NULL REFERENCES usuario(id),
  abierta_at     timestamptz NOT NULL DEFAULT now(),
  cerrada_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- Un consultorio no puede tener dos sesiones abiertas a la vez,
-- ni un veterinario estar en dos consultorios.
CREATE UNIQUE INDEX idx_sesion_consultorio_abierta
  ON sesion_consultorio (consultorio_id) WHERE cerrada_at IS NULL;
CREATE UNIQUE INDEX idx_sesion_consultorio_usuario_abierta
  ON sesion_consultorio (usuario_id) WHERE cerrada_at IS NULL;

-- ---------------------------------------------------------------------
-- Turno
-- ---------------------------------------------------------------------
CREATE TABLE turno (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo            text NOT NULL,              -- 'A-042'
  sede_id           uuid NOT NULL REFERENCES sede(id),
  fecha             date NOT NULL DEFAULT hoy_bogota(),
  numero_secuencial int  NOT NULL,
  tipo_servicio_id  uuid NOT NULL REFERENCES tipo_servicio(id),
  estado            text NOT NULL DEFAULT 'en_espera'
                      CHECK (estado IN ('en_espera','llamado','en_atencion',
                                        'finalizado','ausente','cancelado')),
  prioridad         int NOT NULL DEFAULT 0,
  canal_origen      text NOT NULL DEFAULT 'recepcion_manual'
                      CHECK (canal_origen IN ('qr_telegram','recepcion_manual','tablet_kiosco')),
  telegram_chat_id  bigint,
  dueno_id          uuid,      -- FK añadida en 050_pacientes.sql
  paciente_id       uuid,
  consulta_id       uuid,
  cuenta_id         uuid,      -- FK añadida en 060_cobro.sql
  consultorio_id    uuid REFERENCES consultorio(id),
  veterinario_id    uuid REFERENCES usuario(id),
  creado_por        uuid REFERENCES usuario(id),
  veces_llamado     int NOT NULL DEFAULT 0,
  veces_reencolado  int NOT NULL DEFAULT 0,
  notas             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  llamado_at        timestamptz,
  en_atencion_at    timestamptz,
  finalizado_at     timestamptz,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sede_id, fecha, numero_secuencial)
);

CREATE TRIGGER turno_touch BEFORE UPDATE ON turno
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- La cola se recorre por (prioridad DESC, numero_secuencial ASC).
CREATE INDEX idx_turno_cola ON turno (sede_id, fecha, prioridad DESC, numero_secuencial)
  WHERE estado = 'en_espera';
CREATE INDEX idx_turno_estado ON turno (sede_id, fecha, estado);
CREATE INDEX idx_turno_consultorio ON turno (consultorio_id, estado)
  WHERE estado IN ('llamado','en_atencion');
CREATE INDEX idx_turno_chat ON turno (telegram_chat_id, fecha)
  WHERE telegram_chat_id IS NOT NULL;
CREATE INDEX idx_turno_paciente ON turno (paciente_id, fecha DESC);

-- Máximo 1 turno activo por chat de Telegram al día (§5.3).
CREATE UNIQUE INDEX idx_turno_chat_activo
  ON turno (telegram_chat_id, fecha)
  WHERE telegram_chat_id IS NOT NULL
    AND estado IN ('en_espera','llamado','en_atencion');

-- ---------------------------------------------------------------------
-- Numeración diaria sin colisión (§2.2.6)
-- pg_advisory_xact_lock serializa a los emisores del mismo día/sede.
-- Nunca MAX(numero)+1 sin lock: con 100 pacientes y dos canales, colisiona.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION siguiente_numero_turno(p_sede_id uuid, p_fecha date)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_numero int;
BEGIN
  -- Clave del lock: hash estable de (sede, fecha). Se libera al terminar la transacción.
  PERFORM pg_advisory_xact_lock(hashtext('turno:' || p_sede_id::text || ':' || p_fecha::text));

  SELECT COALESCE(MAX(numero_secuencial), 0) + 1 INTO v_numero
    FROM turno WHERE sede_id = p_sede_id AND fecha = p_fecha;

  RETURN v_numero;
END;
$$;

-- ---------------------------------------------------------------------
-- Estimación de espera y posición en cola
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION posicion_en_cola(p_turno_id uuid)
RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT count(*)::int + 1
    FROM turno t
    JOIN turno yo ON yo.id = p_turno_id
   WHERE t.sede_id = yo.sede_id
     AND t.fecha = yo.fecha
     AND t.estado = 'en_espera'
     AND (t.prioridad, -t.numero_secuencial) > (yo.prioridad, -yo.numero_secuencial);
$$;

CREATE OR REPLACE FUNCTION espera_estimada_min(p_sede_id uuid, p_posicion int)
RETURNS int
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_consultorios int;
  v_duracion int := config_int('duracion_atencion_min', 15);
BEGIN
  SELECT GREATEST(count(*), 1) INTO v_consultorios
    FROM sesion_consultorio sc
    JOIN consultorio c ON c.id = sc.consultorio_id
   WHERE sc.cerrada_at IS NULL AND c.sede_id = p_sede_id;

  RETURN GREATEST(ceil((p_posicion - 1)::numeric * v_duracion / v_consultorios), 0)::int;
END;
$$;

-- Ficha del turno tal como la necesita el bot y la web, en una sola llamada.
CREATE OR REPLACE FUNCTION turno_json(p_turno_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'turno_id',    t.id,
    'codigo',      t.codigo,
    'estado',      t.estado,
    'prioridad',   t.prioridad,
    'tipo',        ts.nombre,
    'sede_id',     t.sede_id,
    'consultorio', c.nombre,
    'consultorio_id', t.consultorio_id,
    'veterinario', u.nombre_completo,
    'chat_id',     t.telegram_chat_id,
    'paciente_id', t.paciente_id,
    'dueno_id',    t.dueno_id,
    'consulta_id', t.consulta_id,
    'cuenta_id',   t.cuenta_id,
    'notas',       t.notas,
    'creado_at',   to_char(t.created_at AT TIME ZONE 'America/Bogota', 'HH24:MI'),
    'posicion',    CASE WHEN t.estado = 'en_espera' THEN posicion_en_cola(t.id) END,
    'espera_min',  CASE WHEN t.estado = 'en_espera'
                        THEN espera_estimada_min(t.sede_id, posicion_en_cola(t.id)) END
  )
  FROM turno t
  JOIN tipo_servicio ts ON ts.id = t.tipo_servicio_id
  LEFT JOIN consultorio c ON c.id = t.consultorio_id
  LEFT JOIN usuario u ON u.id = t.veterinario_id
  WHERE t.id = p_turno_id;
$$;

-- ---------------------------------------------------------------------
-- Canal A — QR + Telegram (§5.3). Sin autenticación ni registro.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_turno_qr(
  p_chat_id bigint,
  p_sede_id uuid DEFAULT NULL,
  p_tipo_codigo text DEFAULT 'general'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_sede uuid := COALESCE(p_sede_id, (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1));
  v_fecha date := hoy_bogota();
  v_existente uuid;
  v_tipo tipo_servicio;
  v_numero int;
  v_id uuid;
BEGIN
  IF v_sede IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sede_invalida',
                              'mensaje', 'No hay una sede configurada.');
  END IF;

  -- Ya tiene turno activo hoy: se lo mostramos en vez de crear otro.
  SELECT id INTO v_existente
    FROM turno
   WHERE telegram_chat_id = p_chat_id AND fecha = v_fecha
     AND estado IN ('en_espera','llamado','en_atencion');

  IF v_existente IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'ya_existia', true, 'turno', turno_json(v_existente));
  END IF;

  -- Rate limit: 1 solicitud por chat cada 60 s.
  IF NOT consumir_rate_limit('turno:chat:' || p_chat_id, 1,
                             config_int('rate_limit_turno_seg', 60)) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'rate_limit',
             'mensaje', 'Espera un momento antes de volver a pedir turno.');
  END IF;

  -- El QR nunca puede marcar urgencia: la prioridad la asigna el personal.
  SELECT * INTO v_tipo FROM tipo_servicio
   WHERE codigo = p_tipo_codigo AND activo AND visible_qr;
  IF NOT FOUND THEN
    SELECT * INTO v_tipo FROM tipo_servicio WHERE codigo = 'general';
  END IF;

  v_numero := siguiente_numero_turno(v_sede, v_fecha);

  INSERT INTO turno (codigo, sede_id, fecha, numero_secuencial, tipo_servicio_id,
                     canal_origen, telegram_chat_id, prioridad)
  VALUES (v_tipo.prefijo || '-' || lpad(v_numero::text, 3, '0'),
          v_sede, v_fecha, v_numero, v_tipo.id, 'qr_telegram', p_chat_id, 0)
  RETURNING id INTO v_id;

  PERFORM auditar('turno', v_id::text, 'crear', NULL, 'telegram', NULL,
                  jsonb_build_object('canal', 'qr_telegram', 'chat_id', p_chat_id));
  PERFORM notificar_pantalla(v_sede);

  RETURN jsonb_build_object('ok', true, 'ya_existia', false, 'turno', turno_json(v_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Canal B — Recepción manual (§5.3). Fallback obligatorio: nadie se queda
-- sin turno por no tener celular.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_turno_manual(
  p_actor_id uuid,
  p_sede_id uuid DEFAULT NULL,
  p_tipo_codigo text DEFAULT 'general',
  p_urgencia boolean DEFAULT false,
  p_dueno_id uuid DEFAULT NULL,
  p_paciente_id uuid DEFAULT NULL,
  p_notas text DEFAULT NULL,
  p_chat_id bigint DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_sede uuid;
  v_fecha date := hoy_bogota();
  v_tipo tipo_servicio;
  v_numero int;
  v_id uuid;
  v_prioridad int;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'turnos.crear');

  v_sede := COALESCE(p_sede_id,
                     (SELECT sede_id FROM usuario WHERE id = p_actor_id),
                     (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1));

  SELECT * INTO v_tipo FROM tipo_servicio WHERE codigo = p_tipo_codigo AND activo;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tipo de servicio desconocido: %', p_tipo_codigo;
  END IF;

  v_prioridad := v_tipo.prioridad_base;
  IF p_urgencia THEN
    PERFORM exigir_permiso(p_actor_id, 'turnos.priorizar');
    v_prioridad := GREATEST(v_prioridad, config_int('prioridad_urgencia', 100));
  END IF;

  v_numero := siguiente_numero_turno(v_sede, v_fecha);

  INSERT INTO turno (codigo, sede_id, fecha, numero_secuencial, tipo_servicio_id,
                     canal_origen, prioridad, dueno_id, paciente_id, notas,
                     telegram_chat_id, creado_por)
  VALUES (v_tipo.prefijo || '-' || lpad(v_numero::text, 3, '0'),
          v_sede, v_fecha, v_numero, v_tipo.id, 'recepcion_manual', v_prioridad,
          p_dueno_id, p_paciente_id, p_notas, p_chat_id, p_actor_id)
  RETURNING id INTO v_id;

  PERFORM auditar('turno', v_id::text, 'crear', p_actor_id, p_canal, NULL,
                  jsonb_build_object('canal', 'recepcion_manual', 'urgencia', p_urgencia));
  PERFORM notificar_pantalla(v_sede);

  RETURN jsonb_build_object('ok', true, 'turno', turno_json(v_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Llamar siguiente (§2.2.5) — el punto de concurrencia del sistema.
-- Dos veterinarios pueden presionar el botón en el mismo milisegundo.
-- FOR UPDATE SKIP LOCKED garantiza que cada uno se lleva un turno distinto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION llamar_siguiente(
  p_actor_id uuid,
  p_consultorio_id uuid DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_consultorio uuid;
  v_sede uuid;
  v_turno_id uuid;
  v_pendiente uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'turnos.llamar');

  -- El consultorio sale de la sesión abierta del veterinario.
  v_consultorio := COALESCE(p_consultorio_id,
    (SELECT consultorio_id FROM sesion_consultorio
      WHERE usuario_id = p_actor_id AND cerrada_at IS NULL));

  IF v_consultorio IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_consultorio',
             'mensaje', 'Primero abre tu consultorio.');
  END IF;

  SELECT sede_id INTO v_sede FROM consultorio WHERE id = v_consultorio;

  -- No se llama a otro mientras haya uno sin cerrar en este consultorio.
  SELECT id INTO v_pendiente FROM turno
   WHERE consultorio_id = v_consultorio AND fecha = hoy_bogota()
     AND estado IN ('llamado','en_atencion')
   LIMIT 1;

  IF v_pendiente IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'turno_en_curso',
             'mensaje', 'Ya tienes un turno en curso en este consultorio.',
             'turno', turno_json(v_pendiente));
  END IF;

  SELECT t.id INTO v_turno_id
    FROM turno t
   WHERE t.sede_id = v_sede
     AND t.fecha = hoy_bogota()
     AND t.estado = 'en_espera'
   ORDER BY t.prioridad DESC, t.numero_secuencial
   LIMIT 1
   FOR UPDATE SKIP LOCKED;

  IF v_turno_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'cola_vacia',
             'mensaje', 'No hay pacientes esperando.');
  END IF;

  UPDATE turno
     SET estado = 'llamado',
         consultorio_id = v_consultorio,
         veterinario_id = p_actor_id,
         llamado_at = now(),
         veces_llamado = veces_llamado + 1
   WHERE id = v_turno_id;

  PERFORM auditar('turno', v_turno_id::text, 'llamar', p_actor_id, p_canal, NULL,
                  jsonb_build_object('consultorio_id', v_consultorio));

  -- Avisos: al dueño llamado, y a los que quedaron a 2 turnos de entrar.
  PERFORM encolar_tarea('notificar_turno_llamado',
                        jsonb_build_object('turno_id', v_turno_id), 10);
  PERFORM encolar_tarea('notificar_turnos_proximos',
                        jsonb_build_object('sede_id', v_sede), 5,
                        'proximos_' || v_sede::text || '_' || v_turno_id::text);
  PERFORM notificar_pantalla(v_sede);

  RETURN jsonb_build_object('ok', true, 'turno', turno_json(v_turno_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Transiciones restantes de la máquina de estados (§5.2)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iniciar_atencion(p_actor_id uuid, p_turno_id uuid, p_canal text DEFAULT 'telegram')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text; v_sede uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'turnos.llamar');

  SELECT estado, sede_id INTO v_estado, v_sede FROM turno WHERE id = p_turno_id FOR UPDATE;
  IF v_estado IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Turno inexistente.');
  END IF;
  IF v_estado <> 'llamado' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'estado_invalido',
             'mensaje', format('El turno está en estado "%s".', v_estado));
  END IF;

  UPDATE turno SET estado = 'en_atencion', en_atencion_at = now() WHERE id = p_turno_id;

  PERFORM auditar('turno', p_turno_id::text, 'iniciar_atencion', p_actor_id, p_canal);
  -- La cuenta se abre automáticamente al entrar en atención (§7.2.1).
  -- abrir_cuenta_para_turno() se define en 060_cobro.sql.
  PERFORM encolar_tarea('abrir_cuenta_turno', jsonb_build_object('turno_id', p_turno_id), 8,
                        'cuenta_' || p_turno_id::text);
  PERFORM notificar_pantalla(v_sede);

  RETURN jsonb_build_object('ok', true, 'turno', turno_json(p_turno_id));
END;
$$;

CREATE OR REPLACE FUNCTION marcar_ausente(p_actor_id uuid, p_turno_id uuid, p_canal text DEFAULT 'telegram')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text; v_sede uuid; v_reencolado int; v_max int := config_int('max_reencolados', 1);
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'turnos.llamar');

  SELECT estado, sede_id, veces_reencolado INTO v_estado, v_sede, v_reencolado
    FROM turno WHERE id = p_turno_id FOR UPDATE;

  IF v_estado NOT IN ('llamado','en_espera') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'estado_invalido',
             'mensaje', format('El turno está en estado "%s".', v_estado));
  END IF;

  UPDATE turno SET estado = 'ausente', consultorio_id = NULL WHERE id = p_turno_id;
  PERFORM auditar('turno', p_turno_id::text, 'ausente', p_actor_id, p_canal);
  PERFORM notificar_pantalla(v_sede);

  RETURN jsonb_build_object('ok', true,
           'puede_reencolar', v_reencolado < v_max,
           'turno', turno_json(p_turno_id));
END;
$$;

-- Un ausente vuelve al final de la cola, conservando su código, una sola vez.
CREATE OR REPLACE FUNCTION reencolar_turno(p_actor_id uuid, p_turno_id uuid, p_canal text DEFAULT 'telegram')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v turno;
  v_max int := config_int('max_reencolados', 1);
  v_nuevo int;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'turnos.crear');

  SELECT * INTO v FROM turno WHERE id = p_turno_id FOR UPDATE;
  IF v.estado <> 'ausente' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'estado_invalido',
             'mensaje', 'Sólo se reencolan turnos marcados como ausentes.');
  END IF;
  IF v.veces_reencolado >= v_max THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'limite_reencolado',
             'mensaje', format('El turno %s ya fue reencolado %s vez(ces).', v.codigo, v.veces_reencolado));
  END IF;

  -- Al final de la cola: número nuevo, código original intacto.
  v_nuevo := siguiente_numero_turno(v.sede_id, v.fecha);

  UPDATE turno
     SET estado = 'en_espera',
         numero_secuencial = v_nuevo,
         veces_reencolado = veces_reencolado + 1,
         consultorio_id = NULL,
         veterinario_id = NULL,
         llamado_at = NULL
   WHERE id = p_turno_id;

  PERFORM auditar('turno', p_turno_id::text, 'reencolar', p_actor_id, p_canal,
                  jsonb_build_object('numero_anterior', v.numero_secuencial),
                  jsonb_build_object('numero_nuevo', v_nuevo));
  PERFORM notificar_pantalla(v.sede_id);

  RETURN jsonb_build_object('ok', true, 'turno', turno_json(p_turno_id));
END;
$$;

CREATE OR REPLACE FUNCTION finalizar_turno(p_actor_id uuid, p_turno_id uuid, p_canal text DEFAULT 'telegram')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v turno;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'turnos.llamar');

  SELECT * INTO v FROM turno WHERE id = p_turno_id FOR UPDATE;
  IF v.estado NOT IN ('en_atencion','llamado') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'estado_invalido',
             'mensaje', format('El turno está en estado "%s".', v.estado));
  END IF;

  UPDATE turno SET estado = 'finalizado', finalizado_at = now() WHERE id = p_turno_id;
  PERFORM auditar('turno', p_turno_id::text, 'finalizar', p_actor_id, p_canal);
  PERFORM notificar_pantalla(v.sede_id);

  -- El bot decide qué proponer según lo que quedó abierto.
  RETURN jsonb_build_object(
    'ok', true,
    'consulta_id', v.consulta_id,
    'cuenta_id', v.cuenta_id,
    'turno', turno_json(p_turno_id));
END;
$$;

CREATE OR REPLACE FUNCTION cancelar_turno(p_actor_id uuid, p_turno_id uuid,
                                          p_motivo text DEFAULT NULL, p_canal text DEFAULT 'telegram')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_sede uuid; v_estado text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'turnos.cancelar');

  SELECT sede_id, estado INTO v_sede, v_estado FROM turno WHERE id = p_turno_id FOR UPDATE;
  IF v_estado IN ('finalizado','cancelado') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'El turno ya está cerrado.');
  END IF;

  UPDATE turno SET estado = 'cancelado', notas = COALESCE(notas || ' | ', '') || COALESCE(p_motivo, '')
   WHERE id = p_turno_id;

  PERFORM auditar('turno', p_turno_id::text, 'cancelar', p_actor_id, p_canal, NULL,
                  jsonb_build_object('motivo', p_motivo));
  PERFORM notificar_pantalla(v_sede);
  RETURN jsonb_build_object('ok', true, 'turno', turno_json(p_turno_id));
END;
$$;

CREATE OR REPLACE FUNCTION marcar_urgencia(p_actor_id uuid, p_turno_id uuid, p_canal text DEFAULT 'telegram')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_sede uuid; v_prio int := config_int('prioridad_urgencia', 100);
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'turnos.priorizar');

  UPDATE turno SET prioridad = v_prio
   WHERE id = p_turno_id AND estado IN ('en_espera','ausente')
   RETURNING sede_id INTO v_sede;

  IF v_sede IS NULL THEN
    RETURN jsonb_build_object('ok', false,
             'mensaje', 'Sólo se puede marcar urgencia en turnos que aún esperan.');
  END IF;

  PERFORM auditar('turno', p_turno_id::text, 'marcar_urgencia', p_actor_id, p_canal);
  PERFORM notificar_pantalla(v_sede);
  RETURN jsonb_build_object('ok', true, 'turno', turno_json(p_turno_id));
END;
$$;

-- Timeout de llamado (§5.2): turnos llamados hace más de timeout_llamado_seg.
-- No los marca ausentes solo: la decisión es del veterinario. Sólo los lista.
CREATE OR REPLACE FUNCTION turnos_llamado_vencido(p_sede_id uuid DEFAULT NULL)
RETURNS TABLE (turno_id uuid, codigo text, consultorio text, veterinario_chat_id bigint, segundos int)
LANGUAGE sql STABLE AS $$
  SELECT t.id, t.codigo, c.nombre, u.telegram_chat_id,
         extract(epoch FROM now() - t.llamado_at)::int
    FROM turno t
    JOIN consultorio c ON c.id = t.consultorio_id
    LEFT JOIN usuario u ON u.id = t.veterinario_id
   WHERE t.estado = 'llamado'
     AND t.fecha = hoy_bogota()
     AND (p_sede_id IS NULL OR t.sede_id = p_sede_id)
     AND t.llamado_at < now() - make_interval(secs => config_int('timeout_llamado_seg', 180));
$$;

-- ---------------------------------------------------------------------
-- Sesiones de consultorio
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION abrir_consultorio(p_actor_id uuid, p_consultorio_id uuid,
                                             p_canal text DEFAULT 'telegram')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_ocupado text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'consultorio.abrir');

  SELECT u.nombre_completo INTO v_ocupado
    FROM sesion_consultorio sc JOIN usuario u ON u.id = sc.usuario_id
   WHERE sc.consultorio_id = p_consultorio_id AND sc.cerrada_at IS NULL
     AND sc.usuario_id <> p_actor_id;

  IF v_ocupado IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'ocupado',
             'mensaje', format('Ese consultorio lo tiene abierto %s.', v_ocupado));
  END IF;

  -- Si el veterinario ya estaba en otro consultorio, se mueve.
  UPDATE sesion_consultorio SET cerrada_at = now()
   WHERE usuario_id = p_actor_id AND cerrada_at IS NULL
     AND consultorio_id <> p_consultorio_id;

  INSERT INTO sesion_consultorio (consultorio_id, usuario_id)
  VALUES (p_consultorio_id, p_actor_id)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM sesion_consultorio
     WHERE consultorio_id = p_consultorio_id AND cerrada_at IS NULL;
  END IF;

  PERFORM auditar('sesion_consultorio', v_id::text, 'abrir', p_actor_id, p_canal);
  PERFORM notificar_pantalla((SELECT sede_id FROM consultorio WHERE id = p_consultorio_id));

  RETURN jsonb_build_object('ok', true, 'sesion_id', v_id,
           'consultorio', (SELECT nombre FROM consultorio WHERE id = p_consultorio_id));
END;
$$;

CREATE OR REPLACE FUNCTION cerrar_consultorio(p_actor_id uuid, p_canal text DEFAULT 'telegram')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_consultorio uuid; v_abiertos int;
BEGIN
  SELECT id, consultorio_id INTO v_id, v_consultorio
    FROM sesion_consultorio WHERE usuario_id = p_actor_id AND cerrada_at IS NULL;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'No tienes ningún consultorio abierto.');
  END IF;

  SELECT count(*) INTO v_abiertos FROM turno
   WHERE consultorio_id = v_consultorio AND fecha = hoy_bogota()
     AND estado IN ('llamado','en_atencion');

  IF v_abiertos > 0 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'turno_en_curso',
             'mensaje', 'Cierra primero el turno que tienes en atención.');
  END IF;

  UPDATE sesion_consultorio SET cerrada_at = now() WHERE id = v_id;
  PERFORM auditar('sesion_consultorio', v_id::text, 'cerrar', p_actor_id, p_canal);
  PERFORM notificar_pantalla((SELECT sede_id FROM consultorio WHERE id = v_consultorio));
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------------------------------------------------------------------
-- Vistas de cola y pantalla pública (§5.5)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_cola_actual AS
  SELECT t.id, t.codigo, t.sede_id, t.prioridad, t.numero_secuencial,
         ts.nombre AS tipo, t.estado, t.created_at,
         extract(epoch FROM now() - t.created_at)::int / 60 AS minutos_esperando,
         t.telegram_chat_id, t.paciente_id, t.notas
    FROM turno t
    JOIN tipo_servicio ts ON ts.id = t.tipo_servicio_id
   WHERE t.fecha = hoy_bogota() AND t.estado = 'en_espera'
   ORDER BY t.prioridad DESC, t.numero_secuencial;

-- Payload de la pantalla de sala de espera. Sin datos personales:
-- sólo código de turno y consultorio.
CREATE OR REPLACE FUNCTION pantalla_publica(p_sede_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'sede', (SELECT nombre FROM sede WHERE id = p_sede_id),
    'actualizado', to_char(now() AT TIME ZONE 'America/Bogota', 'HH24:MI:SS'),
    'consultorios', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'consultorio', c.nombre,
               'abierto', sc.id IS NOT NULL,
               'turno', t.codigo,
               'estado', t.estado
             ) ORDER BY c.orden, c.nombre)
        FROM consultorio c
        LEFT JOIN sesion_consultorio sc
               ON sc.consultorio_id = c.id AND sc.cerrada_at IS NULL
        LEFT JOIN turno t
               ON t.consultorio_id = c.id AND t.fecha = hoy_bogota()
              AND t.estado IN ('llamado','en_atencion')
       WHERE c.sede_id = p_sede_id AND c.activo), '[]'::jsonb),
    'siguientes', COALESCE((
      SELECT jsonb_agg(x.codigo ORDER BY x.prioridad DESC, x.numero_secuencial)
        FROM (SELECT codigo, prioridad, numero_secuencial
                FROM turno
               WHERE sede_id = p_sede_id AND fecha = hoy_bogota() AND estado = 'en_espera'
               ORDER BY prioridad DESC, numero_secuencial
               LIMIT 3) x), '[]'::jsonb),
    'en_espera', (SELECT count(*) FROM turno
                   WHERE sede_id = p_sede_id AND fecha = hoy_bogota() AND estado = 'en_espera')
  );
$$;

-- La pantalla escucha por NOTIFY; el SSE del portal reenvía. Con fallback
-- a polling cada 5 s, esto es una optimización, no un requisito.
CREATE OR REPLACE FUNCTION notificar_pantalla(p_sede_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_sede_id IS NOT NULL THEN
    PERFORM pg_notify('pantalla_turnos', p_sede_id::text);
  END IF;
END;
$$;

-- Los turnos que están a N puestos de entrar, para el aviso "faltan 2 turnos".
CREATE OR REPLACE FUNCTION turnos_por_avisar(p_sede_id uuid, p_faltan int DEFAULT 2)
RETURNS TABLE (turno_id uuid, codigo text, chat_id bigint, posicion int)
LANGUAGE sql STABLE AS $$
  SELECT id, codigo, telegram_chat_id, pos::int
    FROM (
      SELECT id, codigo, telegram_chat_id,
             row_number() OVER (ORDER BY prioridad DESC, numero_secuencial) AS pos
        FROM turno
       WHERE sede_id = p_sede_id AND fecha = hoy_bogota() AND estado = 'en_espera'
         AND telegram_chat_id IS NOT NULL
    ) q
   WHERE pos <= p_faltan;
$$;
