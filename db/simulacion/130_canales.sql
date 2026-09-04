-- =====================================================================
-- Chasqui Pet — db/simulacion/130_canales.sql
-- Deja los avisos a dueños en un estado en el que se puedan PROBAR. Se
-- carga con:
--
--     bash scripts/simular.sh dia
--
-- El problema que resuelve: db/demo/030_clinico_demo.sql le pone a los
-- dueños el chat de Telegram del turno con el que llegaron, y esos chats
-- son inventados (rango 900100000 en adelante). Todo aviso que salga
-- hacia ellos —recordatorio de cita, control próximo, resultado de una
-- remisión, resumen de consulta— muere en la Bot API con «chat not
-- found», se reintenta con backoff y termina en la bandeja de tareas
-- fallidas. La cola queda llena de ruido y no se puede distinguir un
-- fallo real de uno esperado.
--
-- Qué hace:
--   · A los dos primeros dueños con consentimiento les pone el chat de
--     una persona REAL del sistema (el primer usuario que no sea de
--     simulación y tenga chat; en la práctica, el superadministrador).
--     Los avisos de esos dos dueños llegan de verdad a Telegram, que es
--     justo lo que hay que poder ver en una prueba de usuario.
--   · A los demás les quita el chat inventado. Sin canal no se encola
--     nada, y el sistema informa «sin canal» en vez de fallar, que es el
--     comportamiento correcto según la Ley 1581 (§12).
--
-- El consentimiento NO se toca: quien no autorizó sigue sin autorizar, y
-- esa rama también tiene que poder probarse.
--
-- Si no hay ningún usuario real con chat (base recién instalada, nadie
-- ha entrado al bot todavía), no se asigna nada y se avisa por consola:
-- la simulación sirve igual, sólo que ningún aviso sale a Telegram.
-- =====================================================================

SET client_min_messages = warning;

BEGIN;

DO $sim$
DECLARE
  -- Rango CERRADO del personal inventado. Cerrado por arriba a
  -- propósito: los ids de Telegram reales pasan de los diez dígitos y
  -- están por encima de este rango, no por debajo.
  c_tg_base constant bigint := 900000000;
  c_tg_tope constant bigint := 900999999;

  v_chat_real bigint;
  v_con_canal int := 0;
  v_sin_canal int := 0;
BEGIN
  SELECT telegram_chat_id INTO v_chat_real
    FROM usuario
   WHERE activo
     AND telegram_chat_id IS NOT NULL
     AND telegram_user_id NOT BETWEEN c_tg_base AND c_tg_tope
   ORDER BY created_at
   LIMIT 1;

  -- Primero se limpia todo chat inventado: es la parte que siempre se
  -- hace, haya o no un chat real al que enganchar.
  UPDATE dueno SET telegram_chat_id = NULL
   WHERE telegram_chat_id BETWEEN c_tg_base AND c_tg_tope;
  GET DIAGNOSTICS v_sin_canal = ROW_COUNT;

  IF v_chat_real IS NULL THEN
    RAISE NOTICE 'No hay ningún usuario real con chat de Telegram: ningún dueño de simulación recibirá avisos.';
  ELSE
    UPDATE dueno d
       SET telegram_chat_id = v_chat_real
     WHERE d.id IN (
       SELECT id FROM dueno
        WHERE notas = 'DEMO' AND consentimiento_datos
        ORDER BY created_at
        LIMIT 2);
    GET DIAGNOSTICS v_con_canal = ROW_COUNT;
  END IF;

  RAISE NOTICE 'Canales de aviso: % dueño(s) apuntando al chat real %, % chat(s) inventado(s) retirados.',
               v_con_canal, COALESCE(v_chat_real::text, '(ninguno)'), v_sin_canal;
END
$sim$;

COMMIT;
