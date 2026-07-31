// ---------------------------------------------------------------------------
// notificar_turnos_proximos — payload {sede_id}
//
// «⏳ Faltan 2 turnos para el tuyo». Esta tarea se reencola periódicamente,
// así que `turnos_por_avisar` devuelve una y otra vez a los mismos turnos
// mientras sigan de primeros en la cola. La deduplicación vive en la tabla
// aviso_turno_enviado (ver worker/sql/010_aviso_turno.sql): el INSERT con
// ON CONFLICT DO NOTHING es lo que decide, sin carreras entre workers, quién
// manda el aviso.
// ---------------------------------------------------------------------------

import { enviarMensaje, esc } from '../telegram.js';

export const tipo = 'notificar_turnos_proximos';

export async function manejar({ payload }, { db, log, marcarAviso }) {
  const sedeId = payload?.sede_id;
  if (!sedeId) throw new Error('payload sin sede_id');

  const { rows: cfg } = await db.query(
    "SELECT config_int('aviso_faltan_turnos', 2) AS faltan",
  );
  const faltan = cfg[0]?.faltan ?? 2;

  const { rows: turnos } = await db.query(
    'SELECT turno_id, codigo, chat_id, posicion FROM turnos_por_avisar($1, $2)',
    [sedeId, faltan],
  );

  const avisados = [];
  const omitidos = [];
  const bloqueados = [];

  for (const t of turnos) {
    if (!t.chat_id) continue;

    // Reserva del aviso ANTES de enviarlo: si dos workers procesan la misma
    // sede a la vez, solo uno gana el INSERT y solo uno escribe al dueño.
    const nuevo = await marcarAviso(t.turno_id, 'proximo');
    if (!nuevo) {
      omitidos.push(t.codigo);
      continue;
    }

    const cuantos = Math.max(0, Number(t.posicion) - 1);
    const texto =
      cuantos === 0
        ? `⏳ Eres el siguiente (<b>${esc(t.codigo)}</b>). Ve acercándote.`
        : `⏳ Falta${cuantos === 1 ? '' : 'n'} ${cuantos} turno${cuantos === 1 ? '' : 's'} para el tuyo (<b>${esc(t.codigo)}</b>). Ve acercándote.`;

    let r;
    try {
      r = await enviarMensaje(t.chat_id, texto);
    } catch (err) {
      // El envío falló de forma recuperable: se libera la reserva para que el
      // reintento de la tarea vuelva a intentarlo con este turno.
      await liberarAviso(db, t.turno_id, 'proximo');
      throw err;
    }

    if (r.ok) {
      avisados.push(t.codigo);
    } else {
      // Bloqueado: la reserva se queda puesta a propósito, no vale la pena
      // reintentar el mismo chat en cada pasada.
      bloqueados.push({ codigo: t.codigo, motivo: r.motivo });
    }
  }

  if (avisados.length) {
    log.info(`sede ${sedeId}: avisados ${avisados.join(', ')}`);
  }

  return {
    faltan,
    candidatos: turnos.length,
    avisados,
    omitidos_ya_avisados: omitidos,
    bloqueados,
  };
}

async function liberarAviso(db, turnoId, tipoAviso) {
  try {
    await db.query('DELETE FROM aviso_turno_enviado WHERE turno_id = $1 AND tipo = $2', [
      turnoId,
      tipoAviso,
    ]);
  } catch {
    // Si la tabla no existe todavía, no hay nada que liberar.
  }
}
