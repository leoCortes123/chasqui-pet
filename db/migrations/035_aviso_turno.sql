-- ===========================================================================
-- Chasqui Pet — control de avisos ya enviados a un turno
-- ---------------------------------------------------------------------------
-- Por qué existe:
--   La tarea `notificar_turnos_proximos` corre periódicamente por sede y
--   pregunta `turnos_por_avisar(sede, aviso_faltan_turnos)`. Esa función
--   devuelve SIEMPRE los N primeros de la cola: mientras el turno siga entre
--   los primeros, saldría en cada corrida y el dueño recibiría el mismo
--   «faltan 2 turnos» cada dos segundos. Hace falta memoria de qué se avisó.
--
--   Se guarda en la base y no en el worker porque puede haber varios workers
--   en paralelo (reclamar_tareas usa SKIP LOCKED) y porque un reinicio del
--   contenedor no puede perder esa memoria. La PK (turno_id, tipo) hace que el
--   INSERT ... ON CONFLICT DO NOTHING sea la operación atómica que decide, sin
--   carreras, cuál worker manda el aviso.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS aviso_turno_enviado (
  turno_id   uuid        NOT NULL REFERENCES turno(id) ON DELETE CASCADE,
  tipo       text        NOT NULL,   -- 'proximo' | 'llamado' | …
  enviado_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (turno_id, tipo)
);

COMMENT ON TABLE aviso_turno_enviado IS
  'Avisos de Telegram ya enviados por turno. Evita repetir el mismo aviso en cada pasada del worker.';
COMMENT ON COLUMN aviso_turno_enviado.tipo IS
  'Clase de aviso: proximo (faltan N turnos), llamado (es tu turno), etc.';

-- Los turnos son diarios; esta tabla se puede purgar sin consecuencias.
CREATE INDEX IF NOT EXISTS idx_aviso_turno_enviado_at
  ON aviso_turno_enviado (enviado_at);

-- El worker se conecta con el rol de aplicación (DATABASE_URL), igual que n8n
-- y la web. Alinear con lo que hace db/migrations/090_grants.sql.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chasquipet_app') THEN
    GRANT SELECT, INSERT, DELETE ON aviso_turno_enviado TO chasquipet_app;
  END IF;
END
$$;
