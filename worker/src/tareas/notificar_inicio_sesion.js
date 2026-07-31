// ---------------------------------------------------------------------------
// notificar_inicio_sesion — payload {sesion_id}
//
// «Se abrió una sesión en el portal con tu usuario». Es el control barato del
// §11.1: aunque alguien consiga aprobar un ingreso, el dueño de la cuenta se
// entera en el mismo minuto y puede cerrarlo con /sesiones.
// ---------------------------------------------------------------------------

import { enviarMensaje, esc } from '../telegram.js';

export const tipo = 'notificar_inicio_sesion';

export async function manejar({ payload }, { db, log }) {
  const sesionId = payload?.sesion_id;
  if (!sesionId) throw new Error('payload sin sesion_id');

  const { rows } = await db.query(
    `SELECT u.telegram_chat_id AS chat_id,
            s.ip::text        AS ip,
            COALESCE(s.device_name, left(s.user_agent, 60)) AS dispositivo,
            to_char(s.created_at AT TIME ZONE 'America/Bogota', 'DD/MM/YYYY HH12:MI am') AS cuando
       FROM sesion s
       JOIN usuario u ON u.id = s.usuario_id
      WHERE s.id = $1`,
    [sesionId],
  );

  const s = rows[0];
  if (!s) throw new Error(`la sesión ${sesionId} no existe`);

  if (!s.chat_id) {
    log.info(`sesión ${sesionId}: el usuario no ha escrito nunca al bot, no hay chat_id`);
    return { enviado: false, motivo: 'sin_chat_id' };
  }

  const texto =
    '🔐 <b>Entraste al portal</b>\n' +
    `🕒 ${esc(s.cuando)}\n` +
    `🌐 ${esc(s.ip ?? 'origen desconocido')}\n` +
    `💻 ${esc(s.dispositivo ?? 'Navegador')}\n\n` +
    'Si no fuiste tú, escribe /sesiones y ciérralas.';

  const r = await enviarMensaje(s.chat_id, texto);
  return r.ok ? { enviado: true } : { enviado: false, motivo: r.motivo, detalle: r.detalle };
}
