// ---------------------------------------------------------------------------
// enviar_aviso_dueno — payload {dueno_id, mensaje}
//
// Envía por Telegram al dueño un aviso o recordatorio redactado por el
// asistente (Fase 5): «su mascota ya está lista», «vence la vacuna»…
//
// Dos condiciones, ambas obligatorias (§12, Ley 1581 de 2012): que el dueño
// haya dado consentimiento explícito y que tengamos su chat_id. El
// consentimiento se validó en el borrador y al confirmar, pero pudo
// retirarse después: si falta cualquiera de las dos en el momento del envío
// la tarea se completa sin mandar nada — es un caso normal, no un error, y
// no debe gastar reintentos.
//
// El texto lo redactó el asistente y lo aprobó quien confirmó. Aquí solo se
// escapa para el HTML de Telegram y se antepone el nombre de la clínica.
// ---------------------------------------------------------------------------

import { enviarMensaje, esc } from '../telegram.js';

export const tipo = 'enviar_aviso_dueno';

export async function manejar({ payload }, { db, log }) {
  const duenoId = payload?.dueno_id;
  const mensaje = payload?.mensaje;
  if (!duenoId || !mensaje) throw new Error('payload sin dueno_id o mensaje');

  const { rows } = await db.query(
    `SELECT d.nombre_completo AS nombre,
            d.telegram_chat_id AS chat_id,
            d.consentimiento_datos AS consintio,
            config_txt('nombre_clinica', 'Chasqui Pet') AS clinica
       FROM dueno d
      WHERE d.id = $1`,
    [duenoId],
  );

  const fila = rows[0];
  if (!fila) throw new Error(`el dueño ${duenoId} no existe`);

  const consintio = !!fila.consintio;
  if (!consintio || !fila.chat_id) {
    log.info(
      `dueno ${duenoId} sin canal al dueño (consentimiento=${consintio}), se omite el aviso`,
    );
    return { enviado: false, motivo: consintio ? 'sin_chat_id' : 'sin_consentimiento' };
  }

  const texto = `📨 <b>${esc(fila.clinica)}</b>\n\n${esc(mensaje)}`;

  const r = await enviarMensaje(fila.chat_id, texto);
  if (!r.ok) {
    return { enviado: false, motivo: r.motivo, detalle: r.detalle };
  }

  return { enviado: true, dueno: fila.nombre };
}