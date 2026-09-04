-- ===========================================================================
-- 220_botones_filas.sql — corrección: los botones de lista van en filas
-- Ámbito: VERTICAL
--
-- Por qué existe este archivo (§11.4, teclado del bot):
--   El contrato entre las vistas del bot y el nodo «Acciones a Bot API» de
--   n8n es que `botones` sea un arreglo de FILAS, y cada fila un arreglo de
--   objetos {t, d}:  [[{t,d}], [{t,d},{t,d}]]
--   El nodo hace `a.botones.map(fila => fila.map(...))` para armar el
--   `inline_keyboard` de Telegram.
--
--   Tres vistas de las fases B1b, B2 y B3 agregaban el botón de cada
--   elemento de la lista con UN solo nivel de arreglo, es decir un objeto
--   suelto donde iba una fila:
--     170_agenda_canales.sql:227  bot_age_dia   (botón por cita)
--     180_controles.sql:397       bot_ctl_lista (botón por control)
--     190_remisiones.sql:623      bot_rem_lista (botón por remisión)
--
--   El resultado en producción no era un botón mal puesto: el nodo Code de
--   n8n moría con `TypeError: fila.map is not a function`, la ejecución del
--   webhook entera quedaba en error y por lo tanto NUNCA se enviaba el
--   `answerCallbackQuery`. Para quien usa el bot, el botón se quedaba
--   parpadeando con «cargando…» y no llegaba respuesta alguna. Los tres
--   botones del menú —📅 Agenda, 🔔 Controles, 🏥 Remisiones— estaban
--   inservibles.
--
--   Se corrige en la base y no en el nodo de n8n a propósito: el nodo es un
--   traductor de formato (ver CLAUDE.md, «n8n sin decisiones»), y quien
--   incumplía el contrato era el SQL.
--
--   Un botón por fila (y no varios) porque las etiquetas llevan nombre de
--   paciente y destino: en un celular no caben dos por fila sin recortarse.
--   Es además lo que el resto del bot ya hace en sus listas.
--
-- Cambio mínimo: se reemplazan las TRES funciones de vista completas
-- (CREATE OR REPLACE, idempotente) sin tocar nada más de su cuerpo. No hay
-- cambios de esquema, de permisos ni de contrato: `bot_age_callback`,
-- `bot_ctl_callback` y `bot_rem_callback` las siguen llamando igual.
-- ===========================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Agenda del día (era 170_agenda_canales.sql:191)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_age_dia(p_usuario_id uuid, p_sede_id uuid, p_fecha date)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_r     jsonb;
  v_texto text;
  v_bot   jsonb := '[]'::jsonb;
  c       jsonb;
BEGIN
  v_r := agenda_del_dia(p_usuario_id, p_sede_id, p_fecha);

  v_texto := '📅 <b>Agenda</b> · ' || to_char(p_fecha, 'DD/MM/YYYY') ||
             CASE WHEN p_fecha = hoy_bogota() THEN ' (hoy)'
                  WHEN p_fecha = hoy_bogota() + 1 THEN ' (mañana)'
                  ELSE '' END;

  IF jsonb_array_length(v_r->'citas') = 0 THEN
    v_texto := v_texto || E'\n' || 'No hay citas ese día.';
  END IF;

  FOR c IN SELECT * FROM jsonb_array_elements(v_r->'citas') LOOP
    v_texto := v_texto || E'\n' ||
      CASE c->>'estado'
        WHEN 'cumplida'  THEN '✅'
        WHEN 'cancelada' THEN '✖️'
        WHEN 'no_asistio' THEN '🚫'
        WHEN 'confirmada' THEN '☑️'
        ELSE '🕐' END ||
      ' <b>' || esc(c->>'hora') || '</b> · ' ||
      esc(COALESCE(c->'paciente'->>'nombre', 'sin mascota')) ||
      COALESCE(' (' || esc(c->>'dueno') || ')', '') ||
      COALESCE(' · ' || esc(c->>'veterinario'), '');

    -- Solo lo que todavía se puede tocar lleva botón: una cita cumplida o
    -- cancelada se lee, no se opera.
    IF c->>'estado' IN ('programada','confirmada') THEN
      -- Doble arreglo: el botón es una FILA de un solo botón (ver cabecera).
      v_bot := v_bot || jsonb_build_array(jsonb_build_array(jsonb_build_object(
        't', (c->>'hora') || ' · ' || COALESCE(c->'paciente'->>'nombre', 'cita'),
        'd', 'age:cita:' || (c->>'cita_id'))));
    END IF;
  END LOOP;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '◀️', 'd', 'age:dia:' || (p_fecha - 1)::text),
    jsonb_build_object('t', '📆 Hoy', 'd', 'age:dia:' || hoy_bogota()::text),
    jsonb_build_object('t', '▶️', 'd', 'age:dia:' || (p_fecha + 1)::text)));

  IF tiene_permiso(p_usuario_id, 'agenda.gestionar') THEN
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(
      jsonb_build_object('t', '➕ Agendar cita', 'd', 'age:nueva')));
  END IF;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '⬅️ Menú', 'd', 'age:salir')));

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_bot);
END;
$$;

-- ---------------------------------------------------------------------
-- Controles por agendar (era 180_controles.sql:373)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_ctl_lista(p_usuario_id uuid, p_sede_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_r     jsonb := controles_pendientes(p_usuario_id, p_sede_id, 15);
  v_texto text;
  v_bot   jsonb := '[]'::jsonb;
  c       jsonb;
BEGIN
  v_texto := '🔔 <b>Controles por agendar</b>';

  IF (v_r->>'total')::int = 0 THEN
    v_texto := v_texto || E'\n' || 'No hay controles pendientes en los próximos 15 días.';
  END IF;

  FOR c IN SELECT * FROM jsonb_array_elements(v_r->'controles') LIMIT 10 LOOP
    v_texto := v_texto || E'\n' ||
      CASE WHEN (c->>'vencido')::boolean THEN '⚠️' ELSE '📅' END || ' ' ||
      to_char((c->>'fecha_control')::date, 'DD/MM') || ' · <b>' ||
      esc(c->>'paciente') || '</b>' ||
      COALESCE(' (' || esc(c->>'dueno') || ')', '') ||
      CASE WHEN (c->>'vencido')::boolean THEN ' · <i>vencido</i>'
           ELSE ' · en ' || (c->>'dias_faltan') || ' días' END;

    -- Doble arreglo: el botón es una FILA de un solo botón (ver cabecera).
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(jsonb_build_object(
      't', '📅 ' || (c->>'paciente') || ' · ' ||
           to_char((c->>'fecha_control')::date, 'DD/MM'),
      'd', 'ctl:agendar:' || (c->>'consulta_id'))));
  END LOOP;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '⬅️ Menú', 'd', 'ctl:salir')));

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_bot);
END;
$$;

-- ---------------------------------------------------------------------
-- Remisiones sin resultado (era 190_remisiones.sql:599)
-- ---------------------------------------------------------------------
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

    -- Doble arreglo: el botón es una FILA de un solo botón (ver cabecera).
    v_bot := v_bot || jsonb_build_array(jsonb_build_array(jsonb_build_object(
      't', (x->>'emoji') || ' ' || (x->>'paciente') || ' · ' || (x->>'destino'),
      'd', 'rem:ver:' || (x->>'remision_id'))));
  END LOOP;

  v_bot := v_bot || jsonb_build_array(jsonb_build_array(
    jsonb_build_object('t', '⬅️ Menú', 'd', 'rem:salir')));

  RETURN jsonb_build_object('texto', v_texto, 'botones', v_bot);
END;
$$;
