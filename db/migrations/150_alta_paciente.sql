-- =====================================================================
-- Chasqui Pet — 150_alta_paciente.sql
-- Ámbito: VERTICAL (pacientes y dueños; convención de cabecera, Fase A7a).
--
-- Fase A6 del plan de consolidación: subir al núcleo la orquestación que
-- hoy vive en el bot.
--
-- El problema: dar de alta una mascota no es «insertar un paciente». Es
-- una transacción con reglas —dueño nuevo o dueño ya registrado, no
-- duplicar al dueño, avisar del posible duplicado antes de crear (§8.1)—
-- y esas reglas estaban escritas DOS VECES:
--
--   · `bot_cli_crear_paciente` (056_bot_clinico.sql:815) para el flujo de
--     botones: crea el dueño si no hay `dueno_id` y luego el paciente.
--   · `ia_alta_paciente_ejecutar` (078_chasqui_ia.sql:743) para el
--     asistente: además reutiliza un dueño existente por documento o por
--     teléfono antes de crear otro.
--
-- Cuando se construyó el asistente no pudo reusar nada del bot porque
-- aquello estaba mezclado con el estado conversacional y con el dibujo de
-- la pantalla. La duplicación ya ocurrió una vez; el bloque B agrega tres
-- módulos y la repetiría tres veces más.
--
-- Lo que hace este archivo: una sola función de negocio `alta_paciente`
-- con la transacción completa, y los dos caminos anteriores convertidos
-- en envoltorios que solo traducen entrada y salida a su canal. El bot
-- sigue encadenando con la consulta y dibujando la ficha; el asistente
-- sigue devolviendo el jsonb que espera `ia_texto_resultado`. Ninguno de
-- los dos vuelve a decidir nada sobre dueños ni duplicados.
--
-- Cambio de conducta deliberado (única desviación visible): el flujo de
-- botones ahora también reutiliza un dueño ya registrado con el mismo
-- teléfono o documento en vez de crear uno nuevo. Antes solo el
-- asistente lo hacía, y era el asistente el que estaba bien: §8.1 pide
-- buscar antes de crear. Queda registrado en la respuesta
-- (`dueno_reutilizado`) para que el canal pueda decirlo.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1. La operación de negocio
--
-- Contrato de salida: el de `crear_paciente` —{ok, paciente}— más tres
-- datos que solo esta función conoce: `dueno`, `dueno_reutilizado` y
-- `duplicados`. Es aditivo a propósito: `ia_texto_resultado` lee
-- `p_resultado->'paciente'->>'nombre'` y sigue funcionando sin tocarlo.
--
-- Los fallos se devuelven tal cual los devuelve la función de negocio que
-- falló (con su `motivo`), porque los dos canales ya saben mostrar eso.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION alta_paciente(
  p_actor uuid,
  p_args  jsonb,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_nombre     text := NULLIF(trim(COALESCE(p_args->>'mascota_nombre', '')), '');
  v_sin_dueno  boolean := COALESCE((p_args->>'sin_dueno')::boolean, false);
  v_dueno      uuid := NULLIF(p_args->>'dueno_id', '')::uuid;
  v_dueno_nom  text := NULLIF(trim(COALESCE(p_args->>'dueno_nombre', '')), '');
  v_tel        text := NULLIF(trim(COALESCE(p_args->>'dueno_telefono', '')), '');
  v_tipo_doc   text := NULLIF(p_args->>'dueno_tipo_documento', '');
  v_num_doc    text := NULLIF(trim(COALESCE(p_args->>'dueno_numero_documento', '')), '');
  v_reutiliza  boolean := false;
  v_hallado    uuid;
  v_duplicados jsonb;
  v_r          jsonb;
  v_paciente   uuid;
BEGIN
  -- Primera cerradura, antes de escribir nada. `crear_dueno` y
  -- `crear_paciente` la vuelven a exigir; esta está aquí para que la
  -- operación completa falle antes de crear medio registro.
  PERFORM exigir_permiso(p_actor, 'pacientes.editar');

  IF v_nombre IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_nombre',
             'mensaje', 'El nombre de la mascota es obligatorio.');
  END IF;

  -- --- El dueño -------------------------------------------------------
  IF v_dueno IS NOT NULL THEN
    -- Dueño elegido explícitamente: se comprueba que siga existiendo. Entre
    -- que el asistente arma la propuesta y alguien toca el botón puede
    -- pasar un rato, y un `dueno_id` muerto crearía la mascota huérfana.
    PERFORM 1 FROM dueno WHERE id = v_dueno AND activo;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'motivo', 'dueno_inexistente',
               'mensaje', 'Ese dueño ya no existe. Búscalo otra vez y vuelve a intentarlo.');
    END IF;

  ELSIF NOT v_sin_dueno THEN
    -- Buscar antes de crear (§8.1). El documento manda sobre el teléfono:
    -- un teléfono se comparte en una familia, un documento no.
    IF v_num_doc IS NOT NULL AND v_tipo_doc IS NOT NULL THEN
      SELECT id INTO v_hallado FROM dueno
       WHERE tipo_documento = v_tipo_doc AND numero_documento = v_num_doc AND activo
       LIMIT 1;
    END IF;
    IF v_hallado IS NULL AND v_tel IS NOT NULL THEN
      SELECT id INTO v_hallado FROM dueno
       WHERE telefono_digitos = regexp_replace(v_tel, '\D', '', 'g') AND activo
       LIMIT 1;
    END IF;

    IF v_hallado IS NOT NULL THEN
      v_dueno     := v_hallado;
      v_reutiliza := true;
    ELSE
      IF v_dueno_nom IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'sin_dueno',
                 'mensaje', 'Falta el dueño: no existe con ese documento o teléfono y no se '
                            'dio su nombre para crearlo.');
      END IF;
      v_r := crear_dueno(p_actor, v_dueno_nom, v_tel, v_tipo_doc, v_num_doc,
                         NULLIF(trim(COALESCE(p_args->>'dueno_direccion', '')), ''),
                         NULLIF(trim(COALESCE(p_args->>'dueno_barrio', '')), ''),
                         NULL, p_canal);
      IF NOT (v_r->>'ok')::boolean THEN
        RETURN v_r;   -- el canal ya sabe mostrar {ok:false, motivo, mensaje}
      END IF;
      v_dueno := (v_r->'dueno'->>'dueno_id')::uuid;
    END IF;
  END IF;

  -- --- Duplicados -----------------------------------------------------
  -- Se miran ANTES de crear, con el nombre real del dueño (que puede ser
  -- el del dueño reutilizado, no el que llegó en los argumentos). No
  -- bloquean: la clínica sabe que hay dos «Firulais» de la misma familia
  -- mejor que la base. Se informan para que el canal lo diga.
  SELECT COALESCE(jsonb_agg(to_jsonb(d)), '[]'::jsonb) INTO v_duplicados
    FROM posibles_duplicados(
           v_nombre,
           COALESCE((SELECT nombre_completo FROM dueno WHERE id = v_dueno), v_dueno_nom),
           COALESCE(v_tel, (SELECT telefono FROM dueno WHERE id = v_dueno))) d;

  -- --- El paciente ----------------------------------------------------
  v_r := crear_paciente(
           p_actor, v_nombre,
           COALESCE(NULLIF(p_args->>'especie', ''), 'otro'),
           v_dueno,
           COALESCE(NULLIF(p_args->>'sexo', ''), 'desconocido'),
           NULLIF(trim(COALESCE(p_args->>'raza', '')), ''),
           NULLIF(p_args->>'fecha_nacimiento_aprox', '')::date,
           NULLIF(trim(COALESCE(p_args->>'color_senas', '')), ''),
           NULLIF(trim(COALESCE(p_args->>'alergias', '')), ''),
           NULLIF(trim(COALESCE(p_args->>'notas', '')), ''),
           p_canal);

  IF NOT (v_r->>'ok')::boolean THEN
    RETURN v_r;
  END IF;

  v_paciente := (v_r->'paciente'->>'paciente_id')::uuid;

  -- `crear_dueno` y `crear_paciente` ya auditan cada uno lo suyo. Esto
  -- audita el acto completo, que es lo que nadie podía reconstruir
  -- después: si se advirtió de un duplicado y aun así se creó, y si el
  -- dueño se reutilizó o se creó en el mismo acto.
  PERFORM auditar('paciente', v_paciente::text, 'alta', p_actor, p_canal, NULL,
                  jsonb_build_object(
                    'dueno_id', v_dueno,
                    'dueno_reutilizado', v_reutiliza,
                    'duplicados_advertidos', jsonb_array_length(v_duplicados)));

  RETURN v_r || jsonb_build_object(
           'dueno', CASE WHEN v_dueno IS NOT NULL THEN dueno_json(v_dueno) END,
           'dueno_reutilizado', v_reutiliza,
           'duplicados', v_duplicados);
END;
$$;

COMMENT ON FUNCTION alta_paciente(uuid, jsonb, text) IS
  'Alta completa de mascota: dueño nuevo, reutilizado o ninguno, aviso de duplicados y paciente. Único camino de negocio para el bot y el asistente (Fase A6).';

GRANT EXECUTE ON FUNCTION alta_paciente(uuid, jsonb, text) TO chasquipet_app;


-- ---------------------------------------------------------------------
-- 2. El asistente pasa a delegar
--
-- Reemplaza a la versión de 078:743. Lo que hacía —reutilizar dueño por
-- documento o teléfono, crearlo si no, crear el paciente— es exactamente
-- lo que ahora hace `alta_paciente`, con los mismos argumentos y el
-- mismo contrato de salida. Los mensajes de error se conservan palabra
-- por palabra para no cambiar lo que lee la persona en Telegram.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ia_alta_paciente_ejecutar(p_usuario_id uuid, p_args jsonb)
RETURNS jsonb
LANGUAGE sql AS $$
  SELECT alta_paciente(p_usuario_id, p_args, 'telegram');
$$;


-- ---------------------------------------------------------------------
-- 3. El flujo de botones pasa a delegar
--
-- Reemplaza a la versión de 056:815. Aquí solo queda lo que es del canal:
-- el mensaje de error con su botón, el encadenado con la consulta cuando
-- el paciente se registró para atenderlo ya, y la ficha final. La regla
-- «dueño nuevo o existente» se fue al núcleo.
--
-- Los datos del flujo se traducen al contrato de `alta_paciente` sin
-- perder ninguno: el flujo de botones recoge nombre de dueño, teléfono,
-- nombre de mascota, especie y sexo, y `sin_dueno` cuando la mascota se
-- registra sin dueño.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_cli_crear_paciente(
  p_usuario_id uuid, p_chat_id bigint, p_datos jsonb, p_mensaje_id bigint)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_r        jsonb;
  v_paciente uuid;
  v_consulta uuid;
BEGIN
  v_r := alta_paciente(p_usuario_id, jsonb_build_object(
           'mascota_nombre', p_datos->>'mascota_nombre',
           'especie',        COALESCE(p_datos->>'especie', 'otro'),
           'sexo',           COALESCE(p_datos->>'sexo', 'desconocido'),
           'sin_dueno',      COALESCE((p_datos->>'sin_dueno')::boolean, false),
           'dueno_id',       NULLIF(p_datos->>'dueno_id', ''),
           'dueno_nombre',   p_datos->>'dueno_nombre',
           'dueno_telefono', p_datos->>'dueno_telefono'), 'telegram');

  IF NOT (v_r->>'ok')::boolean THEN
    RETURN jsonb_build_object('texto', '⚠️ ' || esc(v_r->>'mensaje'),
      'botones', jsonb_build_array(jsonb_build_array(
        jsonb_build_object('t', '⬅️ Menú', 'd', 'cli:cancelar'))));
  END IF;

  v_paciente := (v_r->'paciente'->>'paciente_id')::uuid;

  -- Si el paciente se registró para atenderlo ya, se sigue de largo a la
  -- consulta en vez de devolver al menú.
  IF p_datos->>'venia_de' = 'consulta' AND tiene_permiso(p_usuario_id, 'consulta.crear') THEN
    v_r := abrir_consulta(p_usuario_id, v_paciente);
    IF (v_r->>'ok')::boolean THEN
      v_consulta := (v_r->'consulta'->>'consulta_id')::uuid;
      PERFORM estado_guardar(p_chat_id, 'consulta', 'motivo',
                jsonb_build_object('consulta_id', v_consulta), p_usuario_id, p_mensaje_id);
      RETURN bot_cli_vista_paso(v_consulta, 'motivo');
    END IF;
  END IF;

  PERFORM estado_limpiar(p_chat_id);
  RETURN bot_cli_ficha(v_paciente, p_usuario_id);
END;
$$;
