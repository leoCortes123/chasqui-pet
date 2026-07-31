// ---------------------------------------------------------------------------
// enviar_recibo — payload {cuenta_id}
//
// Al cerrar la cuenta, el dueño recibe el recibo por Telegram (§7.2.4). Es el
// papelito que se pierde en el bolsillo, pero en el chat donde ya está su
// turno y el resumen de la consulta.
//
// Dos condiciones, ambas obligatorias (§12, Ley 1581 de 2012): consentimiento
// explícito del dueño y chat_id conocido. Si falta cualquiera, la tarea se
// completa sin enviar nada — es un caso normal, no un error.
//
// El texto lo arma recibo_texto() en la base, el mismo que ve el auxiliar al
// cerrar: nadie tiene que mantener dos versiones del recibo.
// ---------------------------------------------------------------------------

import { enviarMensaje } from '../telegram.js';

export const tipo = 'enviar_recibo';

export async function manejar({ payload }, { db, log }) {
  const cuentaId = payload?.cuenta_id;
  if (!cuentaId) throw new Error('payload sin cuenta_id');

  const { rows } = await db.query(
    `SELECT cuenta_json($1) AS c, recibo_texto($1) AS texto,
            d.telegram_chat_id AS chat_id,
            d.consentimiento_datos AS consintio
       FROM cuenta c
       LEFT JOIN dueno d ON d.id = c.dueno_id
      WHERE c.id = $1`,
    [cuentaId],
  );

  const fila = rows[0];
  if (!fila?.c) throw new Error(`la cuenta ${cuentaId} no existe`);

  if (fila.c.estado !== 'cerrada') {
    log.info(`cuenta ${cuentaId} en estado ${fila.c.estado}, no se envía recibo`);
    return { enviado: false, motivo: 'no_cerrada' };
  }

  if (!fila.consintio || !fila.chat_id) {
    log.info(
      `cuenta ${cuentaId} sin canal al dueño (consentimiento=${!!fila.consintio}), se omite`,
    );
    return { enviado: false, motivo: fila.consintio ? 'sin_chat_id' : 'sin_consentimiento' };
  }

  const r = await enviarMensaje(fila.chat_id, fila.texto);
  if (!r.ok) {
    return { enviado: false, motivo: r.motivo, detalle: r.detalle };
  }

  return { enviado: true, recibo: fila.c.recibo_numero, total: fila.c.total };
}
