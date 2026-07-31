-- =====================================================================
-- Chasqui Pet — 050_pacientes.sql
-- Dueños, pacientes e historia clínica (§8).
--
-- Tres decisiones que gobiernan todo el archivo:
--
-- 1. En `dueno` sólo el nombre es obligatorio (§8.1). Exigir documento
--    frena la atención: el animal está en la mesa y el dueño no siempre
--    trae la cédula. Todo lo demás se completa después, desde el portal.
--
-- 2. La consulta se guarda como `borrador` en cada paso y sólo es
--    registro clínico válido cuando se firma (§8.2.4). Firmada, no se
--    edita: se corrige con una adenda, igual que un movimiento de
--    inventario se corrige con un movimiento inverso (§2.2.8).
--
-- 3. `cita` y `disponibilidad` se crean aquí aunque el agendamiento esté
--    fuera del MVP (§3). Un turno y una cita convergen en la misma
--    `consulta`; modelarlo ahora es lo que permite activar citas después
--    sin reescribir turnos.
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Dueño
-- ---------------------------------------------------------------------
CREATE TABLE dueno (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre_completo      text NOT NULL CHECK (length(trim(nombre_completo)) > 0),
  telefono             text,
  tipo_documento       text CHECK (tipo_documento IN ('cc','ce','ti','nit','pasaporte')),
  numero_documento     text,
  telegram_chat_id     bigint,
  direccion            text,
  barrio               text,
  notas                text,
  -- Ley 1581 de 2012 (§12): vincular el Telegram del dueño exige
  -- consentimiento explícito, y ese vínculo debe poder borrarse.
  consentimiento_datos boolean NOT NULL DEFAULT false,
  consentimiento_fecha timestamptz,
  activo               boolean NOT NULL DEFAULT true,
  creado_por           uuid REFERENCES usuario(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),

  -- Sólo dígitos: en recepción el mismo teléfono se escribe «300 123 4567»,
  -- «3001234567» y «+57 300 123 45 67». Para deduplicar hay que comparar
  -- lo que no cambia.
  telefono_digitos     text GENERATED ALWAYS AS (
                         NULLIF(regexp_replace(COALESCE(telefono, ''), '\D', '', 'g'), '')
                       ) STORED,
  busqueda             text GENERATED ALWAYS AS (
                         normalizar(coalesce(nombre_completo,'') || ' ' ||
                                    coalesce(numero_documento,''))
                       ) STORED
);

CREATE TRIGGER dueno_touch BEFORE UPDATE ON dueno
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_dueno_busqueda ON dueno USING gin (busqueda gin_trgm_ops);
CREATE INDEX idx_dueno_telefono ON dueno (telefono_digitos)
  WHERE telefono_digitos IS NOT NULL;
CREATE INDEX idx_dueno_chat ON dueno (telegram_chat_id)
  WHERE telegram_chat_id IS NOT NULL;

-- El documento es opcional, pero si se registra no se repite.
CREATE UNIQUE INDEX idx_dueno_documento
  ON dueno (tipo_documento, numero_documento)
  WHERE numero_documento IS NOT NULL;

-- ---------------------------------------------------------------------
-- Paciente
--
-- `dueno_id` es nullable a propósito: un animal callejero que llega
-- atropellado se atiende igual, y el dueño se le asocia después si
-- aparece.
-- ---------------------------------------------------------------------
CREATE TABLE paciente (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dueno_id              uuid REFERENCES dueno(id),
  nombre                text NOT NULL CHECK (length(trim(nombre)) > 0),
  especie               text NOT NULL DEFAULT 'perro'
                          CHECK (especie IN ('perro','gato','ave','conejo','roedor',
                                             'reptil','equino','otro')),
  raza                  text,
  sexo                  text NOT NULL DEFAULT 'desconocido'
                          CHECK (sexo IN ('macho','hembra','desconocido')),
  esterilizado          boolean,
  fecha_nacimiento_aprox date,
  color_senas           text,
  peso_ultimo_kg        numeric(6,3) CHECK (peso_ultimo_kg IS NULL OR peso_ultimo_kg > 0),
  peso_ultimo_at        timestamptz,
  foto_url              text,
  alergias              text,
  estado                text NOT NULL DEFAULT 'activo'
                          CHECK (estado IN ('activo','fallecido','inactivo')),
  fecha_fallecimiento   date,
  notas                 text,
  creado_por            uuid REFERENCES usuario(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),

  busqueda              text GENERATED ALWAYS AS (
                          normalizar(coalesce(nombre,'') || ' ' ||
                                     coalesce(raza,'') || ' ' ||
                                     coalesce(color_senas,''))
                        ) STORED
);

CREATE TRIGGER paciente_touch BEFORE UPDATE ON paciente
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_paciente_busqueda ON paciente USING gin (busqueda gin_trgm_ops);
CREATE INDEX idx_paciente_dueno ON paciente (dueno_id) WHERE dueno_id IS NOT NULL;
CREATE INDEX idx_paciente_activo ON paciente (estado) WHERE estado = 'activo';

-- ---------------------------------------------------------------------
-- Agendamiento — FUERA DEL MVP (§3): se modela el terreno, no se expone.
--
-- Ninguna función de este archivo escribe en estas dos tablas y el bot no
-- las menciona. Existen para que `consulta.cita_id` tenga a qué apuntar y
-- para que activar citas más adelante sea añadir interfaz, no migrar
-- historia clínica.
-- ---------------------------------------------------------------------
CREATE TABLE disponibilidad (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  veterinario_id uuid NOT NULL REFERENCES usuario(id),
  consultorio_id uuid REFERENCES consultorio(id),
  dia_semana     int  NOT NULL CHECK (dia_semana BETWEEN 0 AND 6),  -- 0 = domingo
  hora_inicio    time NOT NULL,
  hora_fin       time NOT NULL,
  vigente_desde  date NOT NULL DEFAULT hoy_bogota(),
  vigente_hasta  date,
  activo         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (hora_fin > hora_inicio)
);

CREATE TRIGGER disponibilidad_touch BEFORE UPDATE ON disponibilidad
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE cita (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sede_id          uuid NOT NULL REFERENCES sede(id),
  paciente_id      uuid REFERENCES paciente(id),
  dueno_id         uuid REFERENCES dueno(id),
  tipo_servicio_id uuid NOT NULL REFERENCES tipo_servicio(id),
  veterinario_id   uuid REFERENCES usuario(id),
  consultorio_id   uuid REFERENCES consultorio(id),
  inicio_at        timestamptz NOT NULL,
  fin_at           timestamptz NOT NULL,
  estado           text NOT NULL DEFAULT 'programada'
                     CHECK (estado IN ('programada','confirmada','cumplida',
                                       'cancelada','no_asistio')),
  turno_id         uuid REFERENCES turno(id),   -- al llegar, la cita genera turno
  notas            text,
  creado_por       uuid REFERENCES usuario(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (fin_at > inicio_at)
);

CREATE TRIGGER cita_touch BEFORE UPDATE ON cita
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX idx_cita_agenda ON cita (sede_id, inicio_at)
  WHERE estado IN ('programada','confirmada');
CREATE INDEX idx_cita_paciente ON cita (paciente_id, inicio_at DESC);

-- ---------------------------------------------------------------------
-- Consulta — el registro clínico
--
-- `turno_id` y `cita_id` son ambos nullables y ambos únicos: una consulta
-- nace de un turno (hoy) o de una cita (fase 2), nunca de dos.
-- ---------------------------------------------------------------------
CREATE TABLE consulta (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  turno_id               uuid REFERENCES turno(id),
  cita_id                uuid REFERENCES cita(id),
  paciente_id            uuid NOT NULL REFERENCES paciente(id),
  dueno_id               uuid REFERENCES dueno(id),
  veterinario_id         uuid NOT NULL REFERENCES usuario(id),
  consultorio_id         uuid REFERENCES consultorio(id),
  sede_id                uuid REFERENCES sede(id),
  fecha                  date NOT NULL DEFAULT hoy_bogota(),

  motivo_consulta        text,
  anamnesis              text,
  -- peso_kg, temperatura_c, fc, fr, mucosas, tllc_seg, hidratacion, cc.
  -- jsonb y no columnas: el examen físico cambia con la práctica de cada
  -- clínica y no queremos una migración por cada campo nuevo. Lo que sí
  -- es estable —el peso— se copia a paciente.peso_ultimo_kg al firmar.
  examen_fisico          jsonb NOT NULL DEFAULT '{}'::jsonb,
  diagnostico_presuntivo text,
  diagnostico_definitivo text,
  plan_tratamiento       text,
  recomendaciones        text,
  remision_externa       text,
  proxima_revision       date,

  estado                 text NOT NULL DEFAULT 'borrador'
                           CHECK (estado IN ('borrador','firmada','anulada')),
  canal_origen           text NOT NULL DEFAULT 'telegram'
                           CHECK (canal_origen IN ('telegram','web')),
  motivo_anulacion       text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  firmada_at             timestamptz,
  firmada_por            uuid REFERENCES usuario(id),
  anulada_at             timestamptz,
  anulada_por            uuid REFERENCES usuario(id)
);

CREATE TRIGGER consulta_touch BEFORE UPDATE ON consulta
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE UNIQUE INDEX idx_consulta_turno ON consulta (turno_id)
  WHERE turno_id IS NOT NULL;
CREATE UNIQUE INDEX idx_consulta_cita ON consulta (cita_id)
  WHERE cita_id IS NOT NULL;
CREATE INDEX idx_consulta_paciente ON consulta (paciente_id, fecha DESC, created_at DESC);
CREATE INDEX idx_consulta_veterinario ON consulta (veterinario_id, fecha DESC);
-- Un veterinario tiene como mucho un borrador abierto: es el que el bot
-- retoma cuando vuelve al menú.
CREATE INDEX idx_consulta_borrador ON consulta (veterinario_id, updated_at DESC)
  WHERE estado = 'borrador';

-- Corrección posterior a la firma. Append-only, igual que la auditoría:
-- lo firmado no se reescribe, se le añade.
CREATE TABLE consulta_adenda (
  id           bigserial PRIMARY KEY,
  consulta_id  uuid NOT NULL REFERENCES consulta(id),
  texto        text NOT NULL CHECK (length(trim(texto)) > 0),
  usuario_id   uuid NOT NULL REFERENCES usuario(id),
  canal        text NOT NULL DEFAULT 'telegram'
                 CHECK (canal IN ('telegram','web')),
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_adenda_consulta ON consulta_adenda (consulta_id, created_at);

-- Una consulta firmada es inmutable salvo por su anulación (§8.2.4). El
-- trigger existe porque la regla no puede depender de que todas las rutas
-- de escritura —bot, portal, psql de madrugada— se acuerden de mirarla.
CREATE OR REPLACE FUNCTION consulta_inmutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.estado = 'anulada' THEN
    RAISE EXCEPTION 'La consulta está anulada y no admite cambios';
  END IF;

  IF OLD.estado = 'firmada' THEN
    -- Sólo se permite la transición a 'anulada' y sus campos asociados.
    IF NEW.estado <> 'anulada' THEN
      RAISE EXCEPTION 'La consulta ya está firmada. Corrígela con una adenda, no editándola';
    END IF;

    IF (NEW.motivo_consulta,  NEW.anamnesis,        NEW.examen_fisico,
        NEW.diagnostico_presuntivo, NEW.diagnostico_definitivo,
        NEW.plan_tratamiento, NEW.recomendaciones,  NEW.remision_externa,
        NEW.proxima_revision, NEW.paciente_id,      NEW.veterinario_id)
       IS DISTINCT FROM
       (OLD.motivo_consulta,  OLD.anamnesis,        OLD.examen_fisico,
        OLD.diagnostico_presuntivo, OLD.diagnostico_definitivo,
        OLD.plan_tratamiento, OLD.recomendaciones,  OLD.remision_externa,
        OLD.proxima_revision, OLD.paciente_id,      OLD.veterinario_id) THEN
      RAISE EXCEPTION 'Anular una consulta no permite además cambiar su contenido';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER consulta_no_editar_firmada BEFORE UPDATE ON consulta
  FOR EACH ROW EXECUTE FUNCTION consulta_inmutable();

-- ---------------------------------------------------------------------
-- Llaves que quedaron pendientes en las migraciones anteriores
-- ---------------------------------------------------------------------
ALTER TABLE turno
  ADD CONSTRAINT turno_dueno_fk    FOREIGN KEY (dueno_id)    REFERENCES dueno(id),
  ADD CONSTRAINT turno_paciente_fk FOREIGN KEY (paciente_id) REFERENCES paciente(id),
  ADD CONSTRAINT turno_consulta_fk FOREIGN KEY (consulta_id) REFERENCES consulta(id);

ALTER TABLE movimiento_inventario
  ADD CONSTRAINT movimiento_consulta_fk FOREIGN KEY (consulta_id) REFERENCES consulta(id),
  ADD CONSTRAINT movimiento_paciente_fk FOREIGN KEY (paciente_id) REFERENCES paciente(id);

-- ---------------------------------------------------------------------
-- Utilidades de presentación
-- ---------------------------------------------------------------------

-- «3 años», «5 meses», «12 días». La edad se dice en la unidad que
-- importa: en un cachorro de 3 semanas, «0 años» no informa nada.
CREATE OR REPLACE FUNCTION edad_texto(p_nacimiento date)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p_nacimiento IS NULL THEN NULL
    WHEN p_nacimiento > hoy_bogota() THEN NULL
    WHEN age(hoy_bogota(), p_nacimiento) < interval '1 month'
      THEN (hoy_bogota() - p_nacimiento) || ' día' ||
           CASE WHEN (hoy_bogota() - p_nacimiento) = 1 THEN '' ELSE 's' END
    WHEN age(hoy_bogota(), p_nacimiento) < interval '2 years'
      THEN (extract(year from age(hoy_bogota(), p_nacimiento))::int * 12 +
            extract(month from age(hoy_bogota(), p_nacimiento))::int) || ' meses'
    ELSE extract(year from age(hoy_bogota(), p_nacimiento))::int || ' años'
  END;
$$;

CREATE OR REPLACE FUNCTION nombre_especie(p_especie text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_especie
           WHEN 'perro'   THEN 'Perro'
           WHEN 'gato'    THEN 'Gato'
           WHEN 'ave'     THEN 'Ave'
           WHEN 'conejo'  THEN 'Conejo'
           WHEN 'roedor'  THEN 'Roedor'
           WHEN 'reptil'  THEN 'Reptil'
           WHEN 'equino'  THEN 'Equino'
           ELSE 'Otro'
         END;
$$;

CREATE OR REPLACE FUNCTION emoji_especie(p_especie text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_especie
           WHEN 'perro'  THEN '🐕'
           WHEN 'gato'   THEN '🐈'
           WHEN 'ave'    THEN '🦜'
           WHEN 'conejo' THEN '🐇'
           WHEN 'roedor' THEN '🐹'
           WHEN 'reptil' THEN '🦎'
           WHEN 'equino' THEN '🐴'
           ELSE '🐾'
         END;
$$;

-- Catálogo de lo enumerable del examen físico (§8.2.1). Vive en una sola
-- función porque lo consumen dos interfaces —los botones del bot y el
-- formulario del portal— y deben ofrecer exactamente lo mismo.
CREATE OR REPLACE FUNCTION opciones_examen(p_campo text)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_campo
    WHEN 'mucosas' THEN jsonb_build_array(
      jsonb_build_object('v','rosadas',    't','Rosadas'),
      jsonb_build_object('v','palidas',    't','Pálidas'),
      jsonb_build_object('v','ictericas',  't','Ictéricas'),
      jsonb_build_object('v','cianoticas', 't','Cianóticas'),
      jsonb_build_object('v','congestivas','t','Congestivas'))
    WHEN 'hidratacion' THEN jsonb_build_array(
      jsonb_build_object('v','normal', 't','Normal'),
      jsonb_build_object('v','leve',   't','Deshidratación leve (5 %)'),
      jsonb_build_object('v','moderada','t','Moderada (7 %)'),
      jsonb_build_object('v','severa', 't','Severa (10 % o más)'))
    WHEN 'cc' THEN jsonb_build_array(
      jsonb_build_object('v','caquectico','t','1-2 Caquéctico'),
      jsonb_build_object('v','delgado',   't','3-4 Delgado'),
      jsonb_build_object('v','ideal',     't','5 Ideal'),
      jsonb_build_object('v','sobrepeso', 't','6-7 Sobrepeso'),
      jsonb_build_object('v','obeso',     't','8-9 Obeso'))
    WHEN 'especie' THEN jsonb_build_array(
      jsonb_build_object('v','perro',  't','🐕 Perro'),
      jsonb_build_object('v','gato',   't','🐈 Gato'),
      jsonb_build_object('v','ave',    't','🦜 Ave'),
      jsonb_build_object('v','conejo', 't','🐇 Conejo'),
      jsonb_build_object('v','roedor', 't','🐹 Roedor'),
      jsonb_build_object('v','reptil', 't','🦎 Reptil'),
      jsonb_build_object('v','equino', 't','🐴 Equino'),
      jsonb_build_object('v','otro',   't','🐾 Otro'))
    WHEN 'sexo' THEN jsonb_build_array(
      jsonb_build_object('v','macho',      't','♂️ Macho'),
      jsonb_build_object('v','hembra',     't','♀️ Hembra'),
      jsonb_build_object('v','desconocido','t','No sé'))
    ELSE '[]'::jsonb
  END;
$$;

CREATE OR REPLACE FUNCTION etiqueta_opcion(p_campo text, p_valor text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    (SELECT o->>'t' FROM jsonb_array_elements(opciones_examen(p_campo)) o
      WHERE o->>'v' = p_valor),
    p_valor);
$$;

-- Examen físico en una línea legible. Se omite lo que no se midió: un
-- examen con tres campos no debe verse como un formulario a medio llenar.
CREATE OR REPLACE FUNCTION examen_texto(p_examen jsonb)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(concat_ws(' · ',
    NULLIF(COALESCE(p_examen->>'peso_kg', '') || ' kg', ' kg'),
    NULLIF(COALESCE(p_examen->>'temperatura_c', '') || ' °C', ' °C'),
    NULLIF('FC ' || COALESCE(p_examen->>'fc', ''), 'FC '),
    NULLIF('FR ' || COALESCE(p_examen->>'fr', ''), 'FR '),
    CASE WHEN p_examen ? 'mucosas'     THEN 'Mucosas ' || etiqueta_opcion('mucosas', p_examen->>'mucosas') END,
    CASE WHEN p_examen ? 'tllc_seg'    THEN 'TLLC ' || (p_examen->>'tllc_seg') || ' s' END,
    CASE WHEN p_examen ? 'hidratacion' THEN etiqueta_opcion('hidratacion', p_examen->>'hidratacion') END,
    CASE WHEN p_examen ? 'cc'          THEN 'CC ' || etiqueta_opcion('cc', p_examen->>'cc') END
  ), '');
$$;

-- «el motivo, el diagnóstico y el tratamiento»: la coma y la «y» donde
-- van. Un mensaje de error que se lee mal se relee tres veces.
CREATE OR REPLACE FUNCTION frase_lista(p_items text[])
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN array_length(p_items, 1) IS NULL THEN NULL
    WHEN array_length(p_items, 1) = 1 THEN p_items[1]
    ELSE array_to_string(p_items[1:array_length(p_items,1)-1], ', ')
         || ' y ' || p_items[array_length(p_items,1)]
  END;
$$;

-- ---------------------------------------------------------------------
-- Búsqueda y deduplicación (§8.1)
--
-- Antes de crear se busca. Dos veces el mismo perro con dos historias
-- distintas es peor que no tener historia: nadie sabe cuál mirar.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION buscar_dueno(p_texto text, p_limite int DEFAULT 5)
RETURNS TABLE (
  dueno_id uuid, nombre text, telefono text, mascotas text, puntaje real
)
LANGUAGE sql STABLE AS $$
  WITH q AS (
    SELECT normalizar(COALESCE(p_texto, '')) AS t,
           NULLIF(regexp_replace(COALESCE(p_texto, ''), '\D', '', 'g'), '') AS d
  )
  SELECT d.id, d.nombre_completo, d.telefono,
         (SELECT string_agg(p.nombre, ', ' ORDER BY p.nombre)
            FROM paciente p WHERE p.dueno_id = d.id AND p.estado = 'activo'),
         GREATEST(
           similarity(d.busqueda, q.t),
           -- word_similarity compara contra cada palabra: «gomes» encuentra
           -- a «María Gómez», que similarity() sola descartaría por larga.
           word_similarity(q.t, d.busqueda) * 0.9,
           CASE WHEN q.d IS NOT NULL AND d.telefono_digitos IS NOT NULL
                     AND d.telefono_digitos LIKE '%' || q.d THEN 1.0
                WHEN d.busqueda LIKE q.t || '%'   THEN 0.95
                WHEN position(q.t in d.busqueda) > 0 THEN 0.85
                ELSE 0 END)::real
    FROM dueno d CROSS JOIN q
   WHERE d.activo
     AND (q.t <> '' OR q.d IS NOT NULL)
     AND (d.busqueda % q.t
          OR q.t <% d.busqueda
          OR position(q.t in d.busqueda) > 0
          OR (q.d IS NOT NULL AND length(q.d) >= 4
              AND d.telefono_digitos LIKE '%' || q.d))
   ORDER BY 5 DESC, d.nombre_completo
   LIMIT GREATEST(p_limite, 1);
$$;

-- Busca por nombre de la mascota y también por el del dueño: en el
-- mostrador tanto se dice «Firulais» como «la señora Gómez».
CREATE OR REPLACE FUNCTION buscar_paciente(p_texto text, p_limite int DEFAULT 5)
RETURNS TABLE (
  paciente_id uuid, nombre text, especie text, dueno_id uuid,
  dueno text, telefono text, ultima_consulta date, puntaje real
)
LANGUAGE sql STABLE AS $$
  WITH q AS (
    SELECT normalizar(COALESCE(p_texto, '')) AS t,
           NULLIF(regexp_replace(COALESCE(p_texto, ''), '\D', '', 'g'), '') AS d
  )
  SELECT p.id, p.nombre, p.especie, p.dueno_id, du.nombre_completo, du.telefono,
         (SELECT max(c.fecha) FROM consulta c
           WHERE c.paciente_id = p.id AND c.estado = 'firmada'),
         GREATEST(
           similarity(p.busqueda, q.t),
           word_similarity(q.t, p.busqueda) * 0.9,
           similarity(COALESCE(du.busqueda, ''), q.t) * 0.85,
           word_similarity(q.t, COALESCE(du.busqueda, '')) * 0.8,
           CASE WHEN q.d IS NOT NULL AND du.telefono_digitos IS NOT NULL
                     AND du.telefono_digitos LIKE '%' || q.d THEN 1.0
                WHEN p.busqueda LIKE q.t || '%'      THEN 0.95
                WHEN position(q.t in p.busqueda) > 0 THEN 0.85
                ELSE 0 END)::real
    FROM paciente p
    LEFT JOIN dueno du ON du.id = p.dueno_id
   CROSS JOIN q
   WHERE p.estado <> 'inactivo'
     AND (q.t <> '' OR q.d IS NOT NULL)
     AND (p.busqueda % q.t
          OR q.t <% p.busqueda
          OR position(q.t in p.busqueda) > 0
          OR COALESCE(du.busqueda, '') % q.t
          OR q.t <% COALESCE(du.busqueda, '')
          OR position(q.t in COALESCE(du.busqueda, '')) > 0
          OR (q.d IS NOT NULL AND length(q.d) >= 4
              AND du.telefono_digitos LIKE '%' || q.d))
   ORDER BY 8 DESC, p.nombre
   LIMIT GREATEST(p_limite, 1);
$$;

-- Deduplicación previa a crear (§8.1): teléfono, y mascota + dueño.
CREATE OR REPLACE FUNCTION posibles_duplicados(
  p_nombre_mascota text DEFAULT NULL,
  p_nombre_dueno text DEFAULT NULL,
  p_telefono text DEFAULT NULL
) RETURNS TABLE (
  paciente_id uuid, nombre text, especie text, dueno_id uuid, dueno text,
  telefono text, motivo text
)
LANGUAGE sql STABLE AS $$
  WITH q AS (
    SELECT normalizar(COALESCE(p_nombre_mascota, '')) AS m,
           normalizar(COALESCE(p_nombre_dueno, ''))   AS d,
           NULLIF(regexp_replace(COALESCE(p_telefono, ''), '\D', '', 'g'), '') AS tel
  )
  SELECT p.id, p.nombre, p.especie, du.id, du.nombre_completo, du.telefono,
         CASE
           WHEN q.tel IS NOT NULL AND du.telefono_digitos = q.tel THEN 'mismo teléfono'
           ELSE 'mismo nombre de mascota y dueño'
         END
    FROM paciente p
    LEFT JOIN dueno du ON du.id = p.dueno_id
   CROSS JOIN q
   WHERE p.estado = 'activo'
     AND (
       (q.tel IS NOT NULL AND du.telefono_digitos = q.tel)
       OR (q.m <> '' AND q.d <> ''
           AND similarity(p.busqueda, q.m) > 0.5
           AND similarity(COALESCE(du.busqueda, ''), q.d) > 0.5)
     )
   ORDER BY p.updated_at DESC
   LIMIT 5;
$$;

-- ---------------------------------------------------------------------
-- Lectura en JSON — un solo viaje por pantalla del bot o del portal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dueno_json(p_dueno_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'dueno_id', d.id,
    'nombre', d.nombre_completo,
    'telefono', d.telefono,
    'documento', CASE WHEN d.numero_documento IS NOT NULL
                      THEN upper(d.tipo_documento) || ' ' || d.numero_documento END,
    'direccion', d.direccion,
    'barrio', d.barrio,
    'notas', d.notas,
    'chat_id', d.telegram_chat_id,
    'consentimiento', d.consentimiento_datos,
    'mascotas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'paciente_id', p.id, 'nombre', p.nombre, 'especie', p.especie,
               'estado', p.estado) ORDER BY p.nombre)
        FROM paciente p WHERE p.dueno_id = d.id), '[]'::jsonb))
    FROM dueno d
   WHERE d.id = p_dueno_id;
$$;

CREATE OR REPLACE FUNCTION paciente_json(p_paciente_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'paciente_id', p.id,
    'nombre', p.nombre,
    'especie', p.especie,
    'especie_nombre', nombre_especie(p.especie),
    'emoji', emoji_especie(p.especie),
    'raza', p.raza,
    'sexo', p.sexo,
    'esterilizado', p.esterilizado,
    'edad', edad_texto(p.fecha_nacimiento_aprox),
    'fecha_nacimiento_aprox', p.fecha_nacimiento_aprox,
    'color_senas', p.color_senas,
    'peso_kg', p.peso_ultimo_kg,
    'peso_at', p.peso_ultimo_at,
    'alergias', p.alergias,
    'estado', p.estado,
    'notas', p.notas,
    'foto_url', p.foto_url,
    'dueno_id', p.dueno_id,
    'dueno', d.nombre_completo,
    'telefono', d.telefono,
    'chat_id', d.telegram_chat_id,
    'consultas', (SELECT count(*) FROM consulta c
                   WHERE c.paciente_id = p.id AND c.estado = 'firmada'),
    'ultima_consulta', (SELECT max(c.fecha) FROM consulta c
                         WHERE c.paciente_id = p.id AND c.estado = 'firmada'))
    FROM paciente p
    LEFT JOIN dueno d ON d.id = p.dueno_id
   WHERE p.id = p_paciente_id;
$$;

CREATE OR REPLACE FUNCTION consulta_json(p_consulta_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'consulta_id', c.id,
    'estado', c.estado,
    'fecha', c.fecha,
    'turno_id', c.turno_id,
    'turno', t.codigo,
    'paciente_id', c.paciente_id,
    'paciente', paciente_json(c.paciente_id),
    'veterinario_id', c.veterinario_id,
    'veterinario', u.nombre_completo,
    'consultorio', co.nombre,
    'motivo_consulta', c.motivo_consulta,
    'anamnesis', c.anamnesis,
    'examen_fisico', c.examen_fisico,
    'examen_texto', examen_texto(c.examen_fisico),
    'diagnostico_presuntivo', c.diagnostico_presuntivo,
    'diagnostico_definitivo', c.diagnostico_definitivo,
    'plan_tratamiento', c.plan_tratamiento,
    'recomendaciones', c.recomendaciones,
    'remision_externa', c.remision_externa,
    'proxima_revision', c.proxima_revision,
    'firmada_at', c.firmada_at,
    'motivo_anulacion', c.motivo_anulacion,
    'medicamentos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'nombre', m.nombre_generico,
               'cantidad', mi.cantidad,
               'unidad', m.unidad_base) ORDER BY mi.created_at)
        FROM movimiento_inventario mi
        JOIN medicamento m ON m.id = mi.medicamento_id
       WHERE mi.consulta_id = c.id AND mi.tipo = 'salida'), '[]'::jsonb),
    'adendas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'texto', a.texto, 'autor', ua.nombre_completo,
               'created_at', a.created_at) ORDER BY a.created_at)
        FROM consulta_adenda a
        JOIN usuario ua ON ua.id = a.usuario_id
       WHERE a.consulta_id = c.id), '[]'::jsonb))
    FROM consulta c
    LEFT JOIN turno t       ON t.id = c.turno_id
    LEFT JOIN usuario u     ON u.id = c.veterinario_id
    LEFT JOIN consultorio co ON co.id = c.consultorio_id
   WHERE c.id = p_consulta_id;
$$;

-- Historia clínica como línea de tiempo (§11.2). Sólo lo firmado: un
-- borrador ajeno a medio escribir no es historia de nadie.
CREATE OR REPLACE FUNCTION historia_paciente(p_paciente_id uuid, p_limite int DEFAULT 20)
RETURNS TABLE (
  consulta_id uuid, fecha date, veterinario text, motivo text,
  diagnostico text, plan text, examen text, medicamentos text
)
LANGUAGE sql STABLE AS $$
  SELECT c.id, c.fecha, u.nombre_completo, c.motivo_consulta,
         COALESCE(c.diagnostico_definitivo, c.diagnostico_presuntivo),
         c.plan_tratamiento,
         examen_texto(c.examen_fisico),
         (SELECT string_agg(m.nombre_generico || ' ' || fmt_cant(mi.cantidad) ||
                            ' ' || m.unidad_base, ', ' ORDER BY mi.created_at)
            FROM movimiento_inventario mi
            JOIN medicamento m ON m.id = mi.medicamento_id
           WHERE mi.consulta_id = c.id AND mi.tipo = 'salida')
    FROM consulta c
    LEFT JOIN usuario u ON u.id = c.veterinario_id
   WHERE c.paciente_id = p_paciente_id
     AND c.estado = 'firmada'
   ORDER BY c.fecha DESC, c.created_at DESC
   LIMIT GREATEST(p_limite, 1);
$$;

-- ---------------------------------------------------------------------
-- Escritura: dueños
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_dueno(
  p_actor_id uuid,
  p_nombre text,
  p_telefono text DEFAULT NULL,
  p_tipo_documento text DEFAULT NULL,
  p_numero_documento text DEFAULT NULL,
  p_direccion text DEFAULT NULL,
  p_barrio text DEFAULT NULL,
  p_notas text DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'pacientes.editar');

  IF NULLIF(trim(COALESCE(p_nombre, '')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_nombre',
             'mensaje', 'El nombre del dueño es obligatorio.');
  END IF;

  INSERT INTO dueno (nombre_completo, telefono, tipo_documento, numero_documento,
                     direccion, barrio, notas, creado_por)
  VALUES (trim(p_nombre), NULLIF(trim(COALESCE(p_telefono,'')), ''),
          p_tipo_documento, NULLIF(trim(COALESCE(p_numero_documento,'')), ''),
          p_direccion, p_barrio, p_notas, p_actor_id)
  RETURNING id INTO v_id;

  PERFORM auditar('dueno', v_id::text, 'crear', p_actor_id, p_canal, NULL,
                  jsonb_build_object('nombre', trim(p_nombre), 'telefono', p_telefono));

  RETURN jsonb_build_object('ok', true, 'dueno', dueno_json(v_id));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'documento_repetido',
             'mensaje', 'Ya hay un dueño registrado con ese documento.');
END;
$$;

CREATE OR REPLACE FUNCTION actualizar_dueno(
  p_actor_id uuid,
  p_dueno_id uuid,
  p_cambios jsonb,
  p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_antes jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'pacientes.editar');

  v_antes := dueno_json(p_dueno_id);
  IF v_antes IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese dueño no existe.');
  END IF;

  UPDATE dueno SET
    nombre_completo  = COALESCE(NULLIF(trim(p_cambios->>'nombre_completo'), ''), nombre_completo),
    telefono         = CASE WHEN p_cambios ? 'telefono' THEN NULLIF(trim(p_cambios->>'telefono'), '') ELSE telefono END,
    tipo_documento   = CASE WHEN p_cambios ? 'tipo_documento' THEN NULLIF(p_cambios->>'tipo_documento', '') ELSE tipo_documento END,
    numero_documento = CASE WHEN p_cambios ? 'numero_documento' THEN NULLIF(trim(p_cambios->>'numero_documento'), '') ELSE numero_documento END,
    direccion        = CASE WHEN p_cambios ? 'direccion' THEN NULLIF(trim(p_cambios->>'direccion'), '') ELSE direccion END,
    barrio           = CASE WHEN p_cambios ? 'barrio' THEN NULLIF(trim(p_cambios->>'barrio'), '') ELSE barrio END,
    notas            = CASE WHEN p_cambios ? 'notas' THEN NULLIF(trim(p_cambios->>'notas'), '') ELSE notas END
  WHERE id = p_dueno_id;

  PERFORM auditar('dueno', p_dueno_id::text, 'editar', p_actor_id, p_canal,
                  v_antes, dueno_json(p_dueno_id));

  RETURN jsonb_build_object('ok', true, 'dueno', dueno_json(p_dueno_id));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'documento_repetido',
             'mensaje', 'Ya hay otro dueño con ese documento.');
END;
$$;

-- Habeas data (§12). Vincular el Telegram del dueño exige consentimiento
-- explícito y registrado; sin él no se le escribe nunca.
CREATE OR REPLACE FUNCTION registrar_consentimiento(
  p_actor_id uuid,
  p_dueno_id uuid,
  p_otorgado boolean DEFAULT true,
  p_chat_id bigint DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'pacientes.editar');

  UPDATE dueno
     SET consentimiento_datos = p_otorgado,
         consentimiento_fecha = CASE WHEN p_otorgado THEN now() ELSE NULL END,
         -- Retirar el consentimiento desvincula el chat: es el mecanismo
         -- de supresión que exige la Ley 1581.
         telegram_chat_id = CASE WHEN p_otorgado
                                 THEN COALESCE(p_chat_id, telegram_chat_id)
                                 ELSE NULL END
   WHERE id = p_dueno_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese dueño no existe.');
  END IF;

  PERFORM auditar('dueno', p_dueno_id::text,
                  CASE WHEN p_otorgado THEN 'consentimiento_otorgado'
                       ELSE 'consentimiento_retirado' END,
                  p_actor_id, p_canal);

  RETURN jsonb_build_object('ok', true, 'dueno', dueno_json(p_dueno_id));
END;
$$;

-- Supresión de datos personales (Ley 1581 de 2012, §12). No borra la
-- historia clínica —el animal siguió existiendo y el registro clínico
-- tiene su propia obligación de conservación— pero sí todo dato que
-- identifique a la persona.
CREATE OR REPLACE FUNCTION suprimir_datos_dueno(
  p_actor_id uuid,
  p_dueno_id uuid,
  p_motivo text,
  p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_antes jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'usuarios.gestionar');

  v_antes := dueno_json(p_dueno_id);
  IF v_antes IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese dueño no existe.');
  END IF;

  UPDATE dueno
     SET nombre_completo = 'Dato suprimido',
         telefono = NULL, tipo_documento = NULL, numero_documento = NULL,
         telegram_chat_id = NULL, direccion = NULL, barrio = NULL,
         notas = NULL, consentimiento_datos = false, consentimiento_fecha = NULL,
         activo = false
   WHERE id = p_dueno_id;

  PERFORM auditar('dueno', p_dueno_id::text, 'suprimir_datos', p_actor_id, p_canal,
                  v_antes, NULL, p_motivo);

  RETURN jsonb_build_object('ok', true, 'mensaje', 'Datos personales suprimidos.');
END;
$$;

-- ---------------------------------------------------------------------
-- Escritura: pacientes
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crear_paciente(
  p_actor_id uuid,
  p_nombre text,
  p_especie text DEFAULT 'perro',
  p_dueno_id uuid DEFAULT NULL,
  p_sexo text DEFAULT 'desconocido',
  p_raza text DEFAULT NULL,
  p_fecha_nacimiento_aprox date DEFAULT NULL,
  p_color_senas text DEFAULT NULL,
  p_alergias text DEFAULT NULL,
  p_notas text DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'pacientes.editar');

  IF NULLIF(trim(COALESCE(p_nombre, '')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_nombre',
             'mensaje', 'El nombre de la mascota es obligatorio.');
  END IF;

  INSERT INTO paciente (dueno_id, nombre, especie, sexo, raza,
                        fecha_nacimiento_aprox, color_senas, alergias, notas, creado_por)
  VALUES (p_dueno_id, trim(p_nombre), COALESCE(p_especie, 'otro'),
          COALESCE(p_sexo, 'desconocido'), NULLIF(trim(COALESCE(p_raza,'')), ''),
          p_fecha_nacimiento_aprox, p_color_senas, p_alergias, p_notas, p_actor_id)
  RETURNING id INTO v_id;

  PERFORM auditar('paciente', v_id::text, 'crear', p_actor_id, p_canal, NULL,
                  jsonb_build_object('nombre', trim(p_nombre), 'especie', p_especie,
                                     'dueno_id', p_dueno_id));

  RETURN jsonb_build_object('ok', true, 'paciente', paciente_json(v_id));
END;
$$;

CREATE OR REPLACE FUNCTION actualizar_paciente(
  p_actor_id uuid,
  p_paciente_id uuid,
  p_cambios jsonb,
  p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_antes jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'pacientes.editar');

  v_antes := paciente_json(p_paciente_id);
  IF v_antes IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese paciente no existe.');
  END IF;

  UPDATE paciente SET
    nombre       = COALESCE(NULLIF(trim(p_cambios->>'nombre'), ''), nombre),
    especie      = COALESCE(NULLIF(p_cambios->>'especie', ''), especie),
    sexo         = COALESCE(NULLIF(p_cambios->>'sexo', ''), sexo),
    raza         = CASE WHEN p_cambios ? 'raza' THEN NULLIF(trim(p_cambios->>'raza'), '') ELSE raza END,
    esterilizado = CASE WHEN p_cambios ? 'esterilizado' THEN (p_cambios->>'esterilizado')::boolean ELSE esterilizado END,
    fecha_nacimiento_aprox = CASE WHEN p_cambios ? 'fecha_nacimiento_aprox'
                                  THEN NULLIF(p_cambios->>'fecha_nacimiento_aprox','')::date
                                  ELSE fecha_nacimiento_aprox END,
    color_senas  = CASE WHEN p_cambios ? 'color_senas' THEN NULLIF(trim(p_cambios->>'color_senas'), '') ELSE color_senas END,
    alergias     = CASE WHEN p_cambios ? 'alergias' THEN NULLIF(trim(p_cambios->>'alergias'), '') ELSE alergias END,
    notas        = CASE WHEN p_cambios ? 'notas' THEN NULLIF(trim(p_cambios->>'notas'), '') ELSE notas END,
    dueno_id     = CASE WHEN p_cambios ? 'dueno_id' THEN NULLIF(p_cambios->>'dueno_id','')::uuid ELSE dueno_id END,
    estado       = COALESCE(NULLIF(p_cambios->>'estado', ''), estado),
    fecha_fallecimiento = CASE WHEN p_cambios ? 'fecha_fallecimiento'
                               THEN NULLIF(p_cambios->>'fecha_fallecimiento','')::date
                               ELSE fecha_fallecimiento END
  WHERE id = p_paciente_id;

  PERFORM auditar('paciente', p_paciente_id::text, 'editar', p_actor_id, p_canal,
                  v_antes, paciente_json(p_paciente_id));

  RETURN jsonb_build_object('ok', true, 'paciente', paciente_json(p_paciente_id));
END;
$$;

-- Ata el turno en curso a un paciente. Desde aquí, la salida de
-- medicamento y la cuenta saben de qué animal hablan.
CREATE OR REPLACE FUNCTION vincular_turno_paciente(
  p_actor_id uuid,
  p_turno_id uuid,
  p_paciente_id uuid,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_dueno uuid; v_chat bigint;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'pacientes.editar');

  SELECT dueno_id INTO v_dueno FROM paciente WHERE id = p_paciente_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese paciente no existe.');
  END IF;

  SELECT telegram_chat_id INTO v_chat FROM turno WHERE id = p_turno_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese turno ya no existe.');
  END IF;

  UPDATE turno SET paciente_id = p_paciente_id, dueno_id = v_dueno
   WHERE id = p_turno_id;

  -- El turno vino del QR: ese chat es el del dueño. Se guarda sólo si ya
  -- consintió (§12); si no, el vínculo se pierde y está bien que se pierda.
  IF v_chat IS NOT NULL AND v_dueno IS NOT NULL THEN
    UPDATE dueno SET telegram_chat_id = v_chat
     WHERE id = v_dueno AND consentimiento_datos AND telegram_chat_id IS NULL;
  END IF;

  PERFORM auditar('turno', p_turno_id::text, 'vincular_paciente', p_actor_id, p_canal,
                  NULL, jsonb_build_object('paciente_id', p_paciente_id, 'dueno_id', v_dueno));

  RETURN jsonb_build_object('ok', true, 'paciente', paciente_json(p_paciente_id));
END;
$$;

-- ---------------------------------------------------------------------
-- Escritura: consulta
--
-- Abrir → guardar campo a campo (borrador) → firmar. Cada paso es una
-- transacción independiente: si el chat se pierde entre uno y otro, lo
-- escrito hasta ahí ya está guardado (§8.2.3).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION abrir_consulta(
  p_actor_id uuid,
  p_paciente_id uuid,
  p_turno_id uuid DEFAULT NULL,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
  v_turno turno;
  v_consultorio uuid;
  v_sede uuid;
  v_dueno uuid;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'consulta.crear');

  SELECT dueno_id INTO v_dueno FROM paciente WHERE id = p_paciente_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Ese paciente no existe.');
  END IF;

  -- Sin turno explícito: el que este veterinario tiene en atención.
  IF p_turno_id IS NULL THEN
    SELECT * INTO v_turno FROM turno
     WHERE veterinario_id = p_actor_id AND fecha = hoy_bogota()
       AND estado = 'en_atencion'
     ORDER BY en_atencion_at DESC LIMIT 1;
  ELSE
    SELECT * INTO v_turno FROM turno WHERE id = p_turno_id;
  END IF;

  -- Reabrir en vez de duplicar: si ese turno ya tiene consulta en
  -- borrador del mismo paciente, se continúa.
  IF v_turno.id IS NOT NULL THEN
    SELECT id INTO v_id FROM consulta
     WHERE turno_id = v_turno.id AND estado = 'borrador' AND paciente_id = p_paciente_id;
    IF v_id IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'reabierta', true,
                                'consulta', consulta_json(v_id));
    END IF;

    IF EXISTS (SELECT 1 FROM consulta WHERE turno_id = v_turno.id) THEN
      -- El turno ya tiene su consulta. Si es del mismo paciente, esto es
      -- un segundo intento y hay que decirlo; si es de otro —una segunda
      -- mascota de la misma familia, una consulta suelta— se abre sin
      -- turno en vez de bloquear la atención.
      IF EXISTS (SELECT 1 FROM consulta
                  WHERE turno_id = v_turno.id AND paciente_id = p_paciente_id) THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'turno_ya_atendido',
                 'mensaje', 'Ese turno ya tiene una consulta firmada. Agrégale una adenda.');
      END IF;
      v_turno := NULL;
    END IF;
  END IF;

  SELECT sc.consultorio_id, c.sede_id INTO v_consultorio, v_sede
    FROM sesion_consultorio sc
    JOIN consultorio c ON c.id = sc.consultorio_id
   WHERE sc.usuario_id = p_actor_id AND sc.cerrada_at IS NULL;

  INSERT INTO consulta (turno_id, paciente_id, dueno_id, veterinario_id,
                        consultorio_id, sede_id, canal_origen)
  VALUES (v_turno.id, p_paciente_id, v_dueno, p_actor_id,
          COALESCE(v_turno.consultorio_id, v_consultorio),
          COALESCE(v_turno.sede_id, v_sede), p_canal)
  RETURNING id INTO v_id;

  IF v_turno.id IS NOT NULL THEN
    UPDATE turno SET consulta_id = v_id,
                     paciente_id = COALESCE(paciente_id, p_paciente_id),
                     dueno_id    = COALESCE(dueno_id, v_dueno)
     WHERE id = v_turno.id;
  END IF;

  PERFORM auditar('consulta', v_id::text, 'abrir', p_actor_id, p_canal, NULL,
                  jsonb_build_object('paciente_id', p_paciente_id, 'turno_id', v_turno.id));

  RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(v_id));
END;
$$;

-- Guardado incremental (§8.2.3). Un campo por llamada: así el bot puede
-- ir preguntando de a uno y cada respuesta queda persistida al instante.
CREATE OR REPLACE FUNCTION guardar_consulta(
  p_actor_id uuid,
  p_consulta_id uuid,
  p_campo text,
  p_valor text,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado text;
  v_vet uuid;
  v_valor text := NULLIF(trim(COALESCE(p_valor, '')), '');
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'consulta.crear');

  SELECT estado, veterinario_id INTO v_estado, v_vet
    FROM consulta WHERE id = p_consulta_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa consulta ya no existe.');
  END IF;

  IF v_estado <> 'borrador' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'no_es_borrador',
             'mensaje', 'La consulta ya está firmada. Agrega una adenda.');
  END IF;

  CASE p_campo
    WHEN 'motivo_consulta'        THEN UPDATE consulta SET motivo_consulta = v_valor WHERE id = p_consulta_id;
    WHEN 'anamnesis'              THEN UPDATE consulta SET anamnesis = v_valor WHERE id = p_consulta_id;
    WHEN 'diagnostico_presuntivo' THEN UPDATE consulta SET diagnostico_presuntivo = v_valor WHERE id = p_consulta_id;
    WHEN 'diagnostico_definitivo' THEN UPDATE consulta SET diagnostico_definitivo = v_valor WHERE id = p_consulta_id;
    WHEN 'plan_tratamiento'       THEN UPDATE consulta SET plan_tratamiento = v_valor WHERE id = p_consulta_id;
    WHEN 'recomendaciones'        THEN UPDATE consulta SET recomendaciones = v_valor WHERE id = p_consulta_id;
    WHEN 'remision_externa'       THEN UPDATE consulta SET remision_externa = v_valor WHERE id = p_consulta_id;
    WHEN 'proxima_revision'       THEN UPDATE consulta SET proxima_revision = v_valor::date WHERE id = p_consulta_id;
    ELSE
      RETURN jsonb_build_object('ok', false, 'mensaje',
               format('Campo desconocido: %s', p_campo));
  END CASE;

  RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(p_consulta_id));
EXCEPTION
  WHEN invalid_datetime_format OR datetime_field_overflow THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'fecha_invalida',
             'mensaje', 'Esa no es una fecha válida.');
END;
$$;

-- Examen físico: una clave del jsonb por llamada, con la misma lógica de
-- guardado incremental. Los numéricos se validan aquí y no en el bot,
-- porque el portal tiene que rechazar exactamente lo mismo.
CREATE OR REPLACE FUNCTION guardar_examen(
  p_actor_id uuid,
  p_consulta_id uuid,
  p_clave text,
  p_valor text,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_estado text;
  v_num numeric;
  v_valor text := NULLIF(trim(COALESCE(p_valor, '')), '');
  v_rango record;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'consulta.crear');

  SELECT estado INTO v_estado FROM consulta WHERE id = p_consulta_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa consulta ya no existe.');
  END IF;
  IF v_estado <> 'borrador' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'no_es_borrador',
             'mensaje', 'La consulta ya está firmada.');
  END IF;

  IF p_clave NOT IN ('peso_kg','temperatura_c','fc','fr','tllc_seg',
                     'mucosas','hidratacion','cc','hallazgos') THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             format('Campo de examen desconocido: %s', p_clave));
  END IF;

  -- Borrar una medida es tan válido como corregirla.
  IF v_valor IS NULL THEN
    UPDATE consulta SET examen_fisico = examen_fisico - p_clave WHERE id = p_consulta_id;
    RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(p_consulta_id));
  END IF;

  IF p_clave IN ('peso_kg','temperatura_c','fc','fr','tllc_seg') THEN
    BEGIN
      v_num := replace(v_valor, ',', '.')::numeric;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'motivo', 'no_es_numero',
               'mensaje', format('«%s» no es un número.', v_valor));
    END;

    -- Rangos de cordura, no de diagnóstico: atajan el dedo que escribe
    -- 350 kg en un gato, no le dicen al veterinario qué es normal.
    SELECT * INTO v_rango FROM (VALUES
      ('peso_kg',       0.05,  200.0, 'kg'),
      ('temperatura_c', 20.0,   45.0, '°C'),
      ('fc',            10.0,  400.0, 'latidos/min'),
      ('fr',             1.0,  200.0, 'respiraciones/min'),
      ('tllc_seg',       0.1,   15.0, 'segundos')
    ) AS r(clave, minimo, maximo, unidad) WHERE r.clave = p_clave;

    IF v_num < v_rango.minimo OR v_num > v_rango.maximo THEN
      RETURN jsonb_build_object('ok', false, 'motivo', 'fuera_de_rango',
               'mensaje', format('%s fuera de rango (%s a %s %s).',
                                 v_valor, v_rango.minimo, v_rango.maximo, v_rango.unidad));
    END IF;

    UPDATE consulta
       SET examen_fisico = examen_fisico || jsonb_build_object(p_clave, v_num)
     WHERE id = p_consulta_id;
  ELSE
    IF p_clave <> 'hallazgos'
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(opciones_examen(p_clave)) o
                        WHERE o->>'v' = v_valor) THEN
      RETURN jsonb_build_object('ok', false, 'mensaje',
               format('«%s» no es una opción de %s.', v_valor, p_clave));
    END IF;

    UPDATE consulta
       SET examen_fisico = examen_fisico || jsonb_build_object(p_clave, v_valor)
     WHERE id = p_consulta_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(p_consulta_id));
END;
$$;

-- El formulario del portal manda todos los campos de una vez (§8.2.5). Se
-- aplican en una sola transacción reutilizando las mismas funciones que
-- usa el bot: dos interfaces, una sola validación.
CREATE OR REPLACE FUNCTION guardar_consulta_completa(
  p_actor_id uuid,
  p_consulta_id uuid,
  p_datos jsonb,
  p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_clave text;
  v_r jsonb;
  v_errores text[] := ARRAY[]::text[];
BEGIN
  FOR v_clave IN SELECT jsonb_object_keys(p_datos) LOOP
    IF v_clave LIKE 'examen.%' THEN
      v_r := guardar_examen(p_actor_id, p_consulta_id,
                            substring(v_clave FROM 8), p_datos->>v_clave, p_canal);
    ELSE
      v_r := guardar_consulta(p_actor_id, p_consulta_id, v_clave, p_datos->>v_clave, p_canal);
    END IF;

    IF NOT (v_r->>'ok')::boolean THEN
      v_errores := v_errores || (v_clave || ': ' || (v_r->>'mensaje'))::text;
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', frase_lista(v_errores),
                              'errores', to_jsonb(v_errores),
                              'consulta', consulta_json(p_consulta_id));
  END IF;

  RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(p_consulta_id));
END;
$$;

-- Firma (§8.2.4). Consulta mínima viable: motivo + diagnóstico +
-- tratamiento. Lo demás es opcional y saltable.
CREATE OR REPLACE FUNCTION firmar_consulta(
  p_actor_id uuid,
  p_consulta_id uuid,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c consulta;
  v_peso numeric;
  v_faltan text[] := ARRAY[]::text[];
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'consulta.firmar');

  SELECT * INTO c FROM consulta WHERE id = p_consulta_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa consulta ya no existe.');
  END IF;

  IF c.estado = 'firmada' THEN
    RETURN jsonb_build_object('ok', true, 'ya_firmada', true,
                              'consulta', consulta_json(p_consulta_id));
  END IF;
  IF c.estado = 'anulada' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa consulta está anulada.');
  END IF;

  IF NULLIF(trim(COALESCE(c.motivo_consulta, '')), '') IS NULL THEN
    v_faltan := v_faltan || 'el motivo'::text;
  END IF;
  IF NULLIF(trim(COALESCE(c.diagnostico_definitivo, c.diagnostico_presuntivo, '')), '') IS NULL THEN
    v_faltan := v_faltan || 'el diagnóstico'::text;
  END IF;
  IF NULLIF(trim(COALESCE(c.plan_tratamiento, '')), '') IS NULL THEN
    v_faltan := v_faltan || 'el tratamiento'::text;
  END IF;

  IF array_length(v_faltan, 1) IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'incompleta',
             'faltan', to_jsonb(v_faltan),
             'mensaje', 'Falta ' || frase_lista(v_faltan) || '.');
  END IF;

  UPDATE consulta
     SET estado = 'firmada', firmada_at = now(), firmada_por = p_actor_id
   WHERE id = p_consulta_id;

  -- El peso de hoy es el peso del paciente. Es el único dato del examen
  -- que se propaga a la ficha: el resto pertenece a esta consulta.
  v_peso := NULLIF(c.examen_fisico->>'peso_kg', '')::numeric;
  IF v_peso IS NOT NULL THEN
    UPDATE paciente
       SET peso_ultimo_kg = v_peso, peso_ultimo_at = now()
     WHERE id = c.paciente_id;
  END IF;

  PERFORM auditar('consulta', p_consulta_id::text, 'firmar', p_actor_id, p_canal,
                  NULL, jsonb_build_object('paciente_id', c.paciente_id,
                                           'turno_id', c.turno_id));

  -- Resumen al dueño por Telegram: sólo si consintió (§12). Lo decide el
  -- worker, no este flujo, para que el webhook siga respondiendo en <1 s.
  PERFORM encolar_tarea('enviar_resumen_consulta',
            jsonb_build_object('consulta_id', p_consulta_id), 3,
            'resumen_consulta_' || p_consulta_id::text);

  RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(p_consulta_id));
END;
$$;

CREATE OR REPLACE FUNCTION agregar_adenda(
  p_actor_id uuid,
  p_consulta_id uuid,
  p_texto text,
  p_canal text DEFAULT 'telegram'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'consulta.crear');

  SELECT estado INTO v_estado FROM consulta WHERE id = p_consulta_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa consulta ya no existe.');
  END IF;
  IF v_estado <> 'firmada' THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'Las adendas son para consultas firmadas. Esta todavía se puede editar.');
  END IF;
  IF NULLIF(trim(COALESCE(p_texto, '')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'La adenda no puede ir vacía.');
  END IF;

  INSERT INTO consulta_adenda (consulta_id, texto, usuario_id, canal)
  VALUES (p_consulta_id, trim(p_texto), p_actor_id, p_canal);

  PERFORM auditar('consulta', p_consulta_id::text, 'adenda', p_actor_id, p_canal,
                  NULL, jsonb_build_object('texto', trim(p_texto)));

  RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(p_consulta_id));
END;
$$;

-- Anular es excepcional: la consulta se firmó sobre el paciente
-- equivocado, o duplicada. Exige motivo y queda visible en la historia.
CREATE OR REPLACE FUNCTION anular_consulta(
  p_actor_id uuid,
  p_consulta_id uuid,
  p_motivo text,
  p_canal text DEFAULT 'web'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_antes jsonb;
BEGIN
  PERFORM exigir_permiso(p_actor_id, 'consulta.firmar');

  IF NULLIF(trim(COALESCE(p_motivo, '')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
             'Anular una consulta exige explicar por qué.');
  END IF;

  v_antes := consulta_json(p_consulta_id);
  IF v_antes IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Esa consulta ya no existe.');
  END IF;

  UPDATE consulta
     SET estado = 'anulada', motivo_anulacion = trim(p_motivo),
         anulada_at = now(), anulada_por = p_actor_id
   WHERE id = p_consulta_id AND estado <> 'anulada';

  PERFORM auditar('consulta', p_consulta_id::text, 'anular', p_actor_id, p_canal,
                  v_antes, NULL, trim(p_motivo));

  RETURN jsonb_build_object('ok', true, 'consulta', consulta_json(p_consulta_id));
END;
$$;

-- El borrador que el veterinario dejó a medias. El bot lo usa para
-- ofrecer «continuar» en vez de empezar de cero.
CREATE OR REPLACE FUNCTION consulta_en_curso(p_usuario_id uuid)
RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM consulta
   WHERE veterinario_id = p_usuario_id AND estado = 'borrador'
     AND created_at > now() - interval '12 hours'
   ORDER BY updated_at DESC
   LIMIT 1;
$$;
