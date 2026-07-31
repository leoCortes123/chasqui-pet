// ---------------------------------------------------------------------------
// notificar_turno_llamado — payload {turno_id}
//
// «Es tu turno, pasa al Consultorio 2». Junto con el aviso de "faltan 2
// turnos" (§5.3) es la funcionalidad que más se nota en una sala de espera
// llena de animales.
// ---------------------------------------------------------------------------

import { enviarMensaje, esc } from '../telegram.js';

export const tipo = 'notificar_turno_llamado';

export async function manejar({ payload }, { db, log, marcarAviso }) {
  const turnoId = payload?.turno_id;
  if (!turnoId) throw new Error('payload sin turno_id');

  const { rows } = await db.query('SELECT turno_json($1) AS t', [turnoId]);
  const turno = rows[0]?.t;
  if (!turno) throw new Error(`el turno ${turnoId} no existe`);

  // Turno de recepción manual sin Telegram: no hay a quién avisarle.
  // Es un caso normal, no un error: se completa sin hacer nada.
  if (!turno.chat_id) {
    log.info(`turno ${turno.codigo} sin chat_id, no hay a quién notificar`);
    return { enviado: false, motivo: 'sin_chat_id', codigo: turno.codigo };
  }

  const texto = turno.consultorio
    ? `🔔 Es tu turno <b>${esc(turno.codigo)}</b>. Pasa al <b>${esc(turno.consultorio)}</b>.`
    : `🔔 Es tu turno <b>${esc(turno.codigo)}</b>. Acércate a recepción.`;

  const r = await enviarMensaje(turno.chat_id, texto);
  if (!r.ok) {
    return { enviado: false, motivo: r.motivo, detalle: r.detalle, codigo: turno.codigo };
  }

  // Deja constancia para que el aviso de "faltan N" no salga después de este.
  await marcarAviso(turnoId, 'llamado');

  return { enviado: true, codigo: turno.codigo, consultorio: turno.consultorio ?? null };
}
