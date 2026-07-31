-- =====================================================================
-- Chasqui Pet — db/demo/010_turnos_demo.sql
-- Datos de demostración: un día de operación completo del módulo de
-- turnos (entregable §13.9). Se carga con:
--
--     bash scripts/cargar-demo.sh
--
-- Qué produce:
--   · 4 usuarios de personal con roles reales (2 veterinarios, 1 auxiliar,
--     1 recepcionista).
--   · Los dos consultorios abiertos, cada uno con su veterinario.
--   · ~83 turnos del día: la mayoría ya finalizados, unos pocos ausentes,
--     un par de cancelados y una cola VIVA en el momento de la carga
--     (varios en espera, uno llamado y uno en atención), para que la
--     pantalla pública y el bot se vean con datos apenas se abra la demo.
--
-- ADVERTENCIA: es re-ejecutable, y para lograrlo BORRA todos los turnos
-- del día en curso y los usuarios de demo antes de volver a generarlos.
-- No toca el superadmin real ni los seeds de sede, consultorio,
-- tipo_servicio, rol, permiso ni config.
--
-- Identificadores ficticios de Telegram (rango reservado para la demo,
-- ningún usuario real de Telegram tiene estos números):
--   · Personal de demo ......... telegram_user_id 900000001 … 900000099
--   · Dueños (chats del QR) .... telegram_chat_id 900100001 … 900100999
-- La limpieza de la demo se apoya en ese rango: todo lo que esté por
-- encima de 900000000 es dato inventado y se puede borrar sin miedo.
--
-- Sobre los tiempos: la jornada simulada TERMINA en el instante de la
-- carga, para que siempre haya cola viva sin importar a qué hora se
-- ejecute. Si la demo se carga a las 17:00 —la hora típica de una
-- presentación— la jornada cae exactamente sobre 08:00–17:00 y el pico
-- de la mañana queda cerca de las 10:30. Si se carga fuera de horario la
-- jornada se comprime a un mínimo de 5 horas. La fecha operativa de
-- todos los turnos es siempre hoy_bogota().
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

DO $demo$
DECLARE
  -- Rangos ficticios documentados arriba.
  c_tg_base    constant bigint := 900000000;   -- personal de demo
  c_tg_tope    constant bigint := 900999999;
  c_chat_base  constant bigint := 900100000;   -- chats de dueños de demo

  v_sede   uuid;
  v_c1     uuid;
  v_c2     uuid;
  v_vet1   uuid;
  v_vet2   uuid;
  v_aux    uuid;
  v_rec    uuid;

  -- Anclaje temporal de la jornada simulada.
  v_corte     timestamptz := now();                       -- "ahora" de la demo
  v_apertura  timestamptz;                                -- hoy a las 08:00 Bogotá
  v_span      interval;
  v_inicio    timestamptz;
  v_hist_fin  timestamptz;                                -- fin del bloque histórico
  v_dur_franja interval;

  -- Volumen por franja de la jornada (9 franjas iguales). El pico está en
  -- las franjas 3 y 4: a media mañana, que es cuando la clínica se llena.
  v_franjas constant int[] := ARRAY[5, 9, 14, 13, 8, 5, 9, 8, 2];  -- 73 históricos

  f int; k int; idx int := 0;
  v_r        double precision;
  v_created  timestamptz;
  v_tipo     text;
  v_estado   text;
  v_espera   numeric;
  v_atencion numeric;

  v_borrados_turno   int;
  v_borrados_usuario int;
  v_total            int;
BEGIN
  -- ===================================================================
  -- BLOQUE 1 — Contexto: sede y consultorios que dejó el seed operativo.
  -- La demo NO crea sedes ni consultorios: se monta sobre los reales.
  -- ===================================================================
  SELECT id INTO v_sede FROM sede WHERE activa ORDER BY created_at LIMIT 1;
  IF v_sede IS NULL THEN
    RAISE EXCEPTION 'No hay ninguna sede activa. Ejecute primero las migraciones (110_seed_operativo.sql).';
  END IF;

  SELECT id INTO v_c1 FROM consultorio
   WHERE sede_id = v_sede AND activo ORDER BY orden, nombre LIMIT 1;
  SELECT id INTO v_c2 FROM consultorio
   WHERE sede_id = v_sede AND activo AND id <> v_c1 ORDER BY orden, nombre LIMIT 1;

  IF v_c1 IS NULL OR v_c2 IS NULL THEN
    RAISE EXCEPTION 'La sede necesita dos consultorios activos para cargar la demo.';
  END IF;

  -- ===================================================================
  -- BLOQUE 2 — Limpieza idempotente.
  -- Primero los turnos (referencian usuarios), luego las sesiones de
  -- consultorio, y al final los usuarios de demo. Los seeds y el
  -- superadmin real quedan intactos.
  -- ===================================================================
  -- El módulo de inventario (§6) ata cada salida al turno en que se
  -- despachó y al veterinario que la hizo. Como aquí se borran los turnos
  -- del día y el personal de demo para regenerarlos, hay que soltar antes
  -- esos movimientos. movimiento_inventario es de sólo agregar —trigger y
  -- grants—, así que el trigger se desactiva dentro de esta transacción.
  -- El descuadre que esto deja en lote.cantidad_actual lo rehace entero
  -- 020_inventario_demo.sql, que se carga inmediatamente después.
  IF to_regclass('public.movimiento_inventario') IS NOT NULL THEN
    ALTER TABLE movimiento_inventario DISABLE TRIGGER movimiento_inmutable;
    DELETE FROM movimiento_inventario
     WHERE turno_id IN (SELECT id FROM turno WHERE fecha = hoy_bogota())
        OR usuario_id IN (SELECT id FROM usuario
                           WHERE telegram_user_id BETWEEN c_tg_base AND c_tg_tope);
    ALTER TABLE movimiento_inventario ENABLE TRIGGER movimiento_inmutable;
  END IF;

  -- El módulo clínico (§8) cuelga la consulta del turno y el turno del
  -- paciente. Igual que con los movimientos, hay que soltar eso antes de
  -- borrar los turnos del día y el personal de demo, que es quien firma
  -- esas consultas. Lo vuelve a crear 030_clinico_demo.sql.
  IF to_regclass('public.consulta') IS NOT NULL THEN
    UPDATE turno SET consulta_id = NULL, paciente_id = NULL, dueno_id = NULL
     WHERE fecha = hoy_bogota();

    DELETE FROM consulta_adenda a USING consulta c
     WHERE a.consulta_id = c.id
       AND (c.paciente_id IN (SELECT id FROM paciente WHERE notas = 'DEMO')
            OR c.veterinario_id IN (SELECT id FROM usuario
                                     WHERE telegram_user_id BETWEEN c_tg_base AND c_tg_tope));

    DELETE FROM consulta
     WHERE paciente_id IN (SELECT id FROM paciente WHERE notas = 'DEMO')
        OR veterinario_id IN (SELECT id FROM usuario
                               WHERE telegram_user_id BETWEEN c_tg_base AND c_tg_tope);

    DELETE FROM paciente WHERE notas = 'DEMO';
    DELETE FROM dueno    WHERE notas = 'DEMO';
  END IF;

  DELETE FROM turno WHERE fecha = hoy_bogota();
  GET DIAGNOSTICS v_borrados_turno = ROW_COUNT;

  -- Se cierran TODAS las sesiones abiertas en los consultorios de esta sede,
  -- no sólo las del personal de demo: la carga se apropia de la jornada, y
  -- un índice único impide dos sesiones abiertas en el mismo consultorio.
  -- Sin esto, una prueba manual previa deja el consultorio tomado y la
  -- carga falla.
  DELETE FROM sesion_consultorio sc
   USING consultorio c
   WHERE sc.consultorio_id = c.id
     AND c.sede_id = v_sede
     AND (sc.cerrada_at IS NULL OR sc.abierta_at >= hoy_bogota());

  DELETE FROM sesion_consultorio sc
   USING usuario u
   WHERE sc.usuario_id = u.id
     AND u.telegram_user_id BETWEEN c_tg_base AND c_tg_tope;

  -- conversacion_estado y sesion se borran/anulan solos por sus FK.
  DELETE FROM usuario
   WHERE telegram_user_id BETWEEN c_tg_base AND c_tg_tope;
  GET DIAGNOSTICS v_borrados_usuario = ROW_COUNT;

  -- Contadores del rate limit de los chats de demo, para que volver a
  -- pedir turno por QR con esos chats no choque con la carga anterior.
  DELETE FROM rate_limit WHERE clave LIKE 'turno:chat:9001%';

  RAISE NOTICE 'Limpieza: % turnos y % usuarios de demo borrados.',
               v_borrados_turno, v_borrados_usuario;

  -- ===================================================================
  -- BLOQUE 3 — Personal de prueba, con los roles reales del sistema.
  -- Nombres colombianos verosímiles. Los telegram_user_id son ficticios
  -- (rango 9000000xx) y distintos entre sí: nadie puede entrar al bot
  -- con ellos, sólo sirven para que las pantallas muestren nombres.
  -- ===================================================================
  INSERT INTO usuario (telegram_user_id, telegram_chat_id, nombre_completo, telefono, sede_id, notas)
  VALUES
    (900000001, 900000001, 'Camilo Andrés Reyes Mahecha',    '300 412 8890', v_sede, 'Usuario de demostración'),
    (900000002, 900000002, 'Diana Marcela Ospina Cárdenas',  '311 765 4402', v_sede, 'Usuario de demostración'),
    (900000003, 900000003, 'Yuly Paola Beltrán Rincón',      '320 338 1176', v_sede, 'Usuario de demostración'),
    (900000004, 900000004, 'Jefferson Cifuentes Molina',     '316 209 5541', v_sede, 'Usuario de demostración')
  ON CONFLICT (telegram_user_id) DO UPDATE
    SET nombre_completo = EXCLUDED.nombre_completo,
        activo = true;

  SELECT id INTO v_vet1 FROM usuario WHERE telegram_user_id = 900000001;
  SELECT id INTO v_vet2 FROM usuario WHERE telegram_user_id = 900000002;
  SELECT id INTO v_aux  FROM usuario WHERE telegram_user_id = 900000003;
  SELECT id INTO v_rec  FROM usuario WHERE telegram_user_id = 900000004;

  INSERT INTO usuario_rol (usuario_id, rol_codigo) VALUES
    (v_vet1, 'veterinario'),
    (v_vet2, 'veterinario'),
    (v_aux,  'auxiliar'),
    (v_rec,  'recepcion')
  ON CONFLICT DO NOTHING;

  -- La auxiliar tiene habilitada la entrada de inventario (§4: se otorga
  -- uno a uno, no se inventa un rol nuevo). Sirve para enseñar en la demo
  -- que los permisos son datos y se ajustan por usuario.
  INSERT INTO usuario_permiso (usuario_id, permiso_codigo, otorgado, motivo)
  VALUES (v_aux, 'inventario.entrada', true, 'Habilitada por el administrador para recibir pedidos')
  ON CONFLICT DO NOTHING;

  -- ===================================================================
  -- BLOQUE 4 — Ventana temporal de la jornada simulada.
  -- ===================================================================
  v_apertura := (hoy_bogota() + time '08:00') AT TIME ZONE 'America/Bogota';
  -- Entre 5 y 9 horas de jornada, terminando siempre en el instante actual.
  v_span     := GREATEST(LEAST(v_corte - v_apertura, interval '9 hours'), interval '5 hours');
  v_inicio   := v_corte - v_span;
  -- El bloque histórico se corta 75 minutos antes de "ahora": es el margen
  -- que necesita el último turno histórico (hasta 45 min de espera más
  -- 25 min de atención) para quedar cerrado en el pasado y no en el futuro.
  v_hist_fin := v_corte - interval '75 minutes';

  -- ===================================================================
  -- BLOQUE 5 — Sesiones de consultorio abiertas.
  -- Cada veterinario en un consultorio, desde el inicio de la jornada.
  -- Sin esto la pantalla pública muestra los consultorios cerrados y la
  -- estimación de espera asume un solo consultorio.
  -- ===================================================================
  INSERT INTO sesion_consultorio (consultorio_id, usuario_id, abierta_at)
  VALUES (v_c1, v_vet1, v_inicio),
         (v_c2, v_vet2, v_inicio);

  -- ===================================================================
  -- BLOQUE 6 — Generación de los turnos en una tabla temporal.
  -- Se arma primero aquí para poder numerarlos por orden de llegada de
  -- una sola vez y respetar el índice único (sede_id, fecha, numero).
  -- ===================================================================
  CREATE TEMP TABLE _demo_turnos (
    ord          bigserial,
    created_at   timestamptz NOT NULL,
    tipo_codigo  text        NOT NULL,
    estado       text        NOT NULL,
    espera_min   numeric,            -- minutos entre la llegada y el llamado
    atencion_min numeric,            -- minutos de atención efectiva
    slot         int,                -- 1 = Consultorio 1, 2 = Consultorio 2
    con_chat     boolean NOT NULL DEFAULT true,
    prioridad    int     NOT NULL DEFAULT 0,
    notas        text
  ) ON COMMIT DROP;

  -- Semilla fija: la demo se ve igual en cada carga y en cada máquina.
  PERFORM setseed(0.4711);

  v_dur_franja := (v_hist_fin - v_inicio) / array_length(v_franjas, 1);

  -- --- 6.a Bloque histórico: lo que ya pasó en el día ------------------
  FOR f IN 1..array_length(v_franjas, 1) LOOP
    FOR k IN 1..v_franjas[f] LOOP
      idx := idx + 1;

      -- Llegada aleatoria dentro de la franja.
      v_created := v_inicio + v_dur_franja * (f - 1) + v_dur_franja * random();

      -- Mezcla de servicios: la consulta general manda, la urgencia es rara.
      v_r := random();
      v_tipo := CASE
                  WHEN v_r < 0.55 THEN 'general'
                  WHEN v_r < 0.73 THEN 'vacunacion'
                  WHEN v_r < 0.93 THEN 'control'
                  ELSE                  'urgencia'
                END;

      -- Desenlace: la gran mayoría se atiende; algunos no se presentan;
      -- muy pocos se cansan de esperar y se van.
      v_estado := CASE
                    WHEN idx % 12 = 0 THEN 'ausente'
                    WHEN idx % 31 = 0 THEN 'cancelado'
                    ELSE                   'finalizado'
                  END;

      v_espera   := 5 + random() * 40;   -- 5 a 45 minutos de espera
      v_atencion := 8 + random() * 17;   -- 8 a 25 minutos de atención

      INSERT INTO _demo_turnos
        (created_at, tipo_codigo, estado, espera_min, atencion_min, slot, con_chat, prioridad, notas)
      VALUES (
        v_created,
        v_tipo,
        v_estado,
        CASE WHEN v_estado = 'cancelado'  THEN NULL ELSE v_espera   END,
        CASE WHEN v_estado = 'finalizado' THEN v_atencion           END,
        CASE WHEN v_estado = 'cancelado'  THEN NULL ELSE 1 + (idx % 2) END,
        (idx % 10) < 7,                  -- ~70 % llegó por QR, el resto por recepción
        CASE WHEN v_tipo = 'urgencia' THEN 100 ELSE 0 END,
        CASE WHEN v_estado = 'cancelado'
             THEN 'El dueño se retiró antes de ser llamado.' END
      );
    END LOOP;
  END LOOP;

  -- --- 6.b Cola viva: el estado del sistema "en este momento" ----------
  -- Un turno en atención en el Consultorio 1, uno recién llamado al
  -- Consultorio 2 y ocho esperando, con esperas de 5 a 45 minutos.
  INSERT INTO _demo_turnos
    (created_at, tipo_codigo, estado, espera_min, atencion_min, slot, con_chat, prioridad, notas)
  VALUES
    (v_corte - interval '58 minutes', 'general',    'en_atencion', 30,   NULL, 1,    true,  0,   NULL),
    (v_corte - interval '40 minutes', 'control',    'llamado',     38,   NULL, 2,    true,  0,   NULL),
    (v_corte - interval '45 minutes', 'general',    'en_espera',   NULL, NULL, NULL, true,  0,   NULL),
    (v_corte - interval '39 minutes', 'vacunacion', 'en_espera',   NULL, NULL, NULL, false, 0,   'Refuerzo de triple felina.'),
    (v_corte - interval '32 minutes', 'general',    'en_espera',   NULL, NULL, NULL, true,  0,   NULL),
    (v_corte - interval '26 minutes', 'control',    'en_espera',   NULL, NULL, NULL, true,  0,   'Retiro de puntos.'),
    (v_corte - interval '20 minutes', 'general',    'en_espera',   NULL, NULL, NULL, true,  0,   NULL),
    (v_corte - interval '15 minutes', 'urgencia',   'en_espera',   NULL, NULL, NULL, false, 100, 'Perro con dificultad respiratoria. Urgencia marcada en recepción.'),
    (v_corte - interval '9 minutes',  'general',    'en_espera',   NULL, NULL, NULL, true,  0,   NULL),
    (v_corte - interval '5 minutes',  'vacunacion', 'en_espera',   NULL, NULL, NULL, true,  0,   NULL);

  -- ===================================================================
  -- BLOQUE 7 — Volcado a la tabla real.
  -- El número secuencial se asigna por orden de llegada; el código se
  -- forma como prefijo || '-' || lpad(numero, 3, '0') con el prefijo del
  -- tipo de servicio: A- general, V- vacunación, C- control, U- urgencia.
  -- ===================================================================
  WITH numerados AS (
    SELECT d.*, row_number() OVER (ORDER BY d.created_at, d.ord) AS num
      FROM _demo_turnos d
  ),
  con_llamado AS (
    SELECT n.*,
           CASE WHEN n.espera_min IS NOT NULL
                THEN n.created_at + make_interval(secs => (n.espera_min * 60)::int)
           END AS llamado_at
      FROM numerados n
  ),
  con_atencion AS (
    SELECT c.*,
           CASE WHEN c.estado IN ('en_atencion', 'finalizado')
                -- minuto y medio entre que se le llama y entra al consultorio
                THEN c.llamado_at + interval '90 seconds'
           END AS en_atencion_at
      FROM con_llamado c
  )
  INSERT INTO turno (
    codigo, sede_id, fecha, numero_secuencial, tipo_servicio_id, estado, prioridad,
    canal_origen, telegram_chat_id, consultorio_id, veterinario_id, creado_por,
    veces_llamado, notas, created_at, llamado_at, en_atencion_at, finalizado_at
  )
  SELECT
    ts.prefijo || '-' || lpad(q.num::text, 3, '0'),
    v_sede,
    hoy_bogota(),
    q.num,
    ts.id,
    q.estado,
    GREATEST(q.prioridad, ts.prioridad_base),
    CASE WHEN q.con_chat THEN 'qr_telegram' ELSE 'recepcion_manual' END,
    -- Un chat ficticio distinto por turno: así se respeta el índice único
    -- parcial de "máximo 1 turno activo por telegram_chat_id".
    CASE WHEN q.con_chat THEN c_chat_base + q.num END,
    -- Un ausente pierde el consultorio (lo libera al no presentarse) pero
    -- conserva el veterinario que lo llamó, igual que hace marcar_ausente().
    CASE WHEN q.estado IN ('llamado', 'en_atencion', 'finalizado')
         THEN CASE q.slot WHEN 1 THEN v_c1 ELSE v_c2 END END,
    CASE WHEN q.estado IN ('llamado', 'en_atencion', 'finalizado', 'ausente')
         THEN CASE q.slot WHEN 1 THEN v_vet1 ELSE v_vet2 END END,
    -- Los turnos de recepción los digita el personal de mostrador.
    CASE WHEN q.con_chat THEN NULL
         WHEN q.num % 2 = 0 THEN v_aux
         ELSE v_rec END,
    CASE WHEN q.estado IN ('llamado', 'en_atencion', 'finalizado', 'ausente') THEN 1 ELSE 0 END,
    q.notas,
    q.created_at,
    q.llamado_at,
    q.en_atencion_at,
    CASE WHEN q.estado = 'finalizado'
         THEN q.en_atencion_at + make_interval(secs => (q.atencion_min * 60)::int)
    END
  FROM con_atencion q
  JOIN tipo_servicio ts ON ts.codigo = q.tipo_codigo;

  GET DIAGNOSTICS v_total = ROW_COUNT;

  -- ===================================================================
  -- BLOQUE 8 — Auditoría.
  -- Nunca se escribe a mano en evento_auditoria: es append-only y la app
  -- no tiene UPDATE/DELETE sobre ella (§2.2.8). Se usa auditar().
  -- Ojo: el created_at de la auditoría es el momento de la CARGA de la
  -- demo, no el del turno; precisamente porque no se puede falsear.
  -- ===================================================================
  PERFORM count(*) FROM (
    SELECT auditar('turno', t.id::text, 'crear', t.creado_por, 'telegram', NULL,
                   jsonb_build_object('canal', t.canal_origen, 'codigo', t.codigo,
                                      'tipo', ts.codigo),
                   'Turno generado por los datos de demo')
      FROM turno t
      JOIN tipo_servicio ts ON ts.id = t.tipo_servicio_id
     WHERE t.fecha = hoy_bogota()
  ) s;

  PERFORM count(*) FROM (
    SELECT auditar('turno', t.id::text, 'finalizar', t.veterinario_id, 'telegram', NULL,
                   jsonb_build_object('codigo', t.codigo,
                                      'minutos_atencion',
                                      round(extract(epoch FROM t.finalizado_at - t.en_atencion_at) / 60)),
                   'Turno cerrado por los datos de demo')
      FROM turno t
     WHERE t.fecha = hoy_bogota() AND t.estado = 'finalizado'
  ) s;

  PERFORM auditar('demo', '010_turnos_demo', 'cargar', NULL, 'sistema', NULL,
                  jsonb_build_object('turnos', v_total,
                                     'jornada_desde', v_inicio,
                                     'jornada_hasta', v_corte,
                                     'sede_id', v_sede),
                  'Carga de datos de demostración del módulo de turnos');

  -- Que la pantalla pública que ya esté abierta se refresque sola.
  PERFORM notificar_pantalla(v_sede);

  RAISE NOTICE 'Demo cargada: % turnos para la fecha % en la sede %.',
               v_total, hoy_bogota(), v_sede;
END
$demo$;

COMMIT;
