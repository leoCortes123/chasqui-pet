// ---------------------------------------------------------------------------
// alertas_remisiones — payload {} (opcional: {forzar: true})
//
// El aviso de la mañana de la Fase B3: qué se mandó al laboratorio o al
// especialista y se pasó de la fecha en que debía volver. Lo encola el job de
// n8n una vez al día.
//
// Mismos dos cuidados que `alertas_inventario`, y por las mismas razones:
//   - El texto lo arma la BASE (bot_texto_alertas_remisiones), no este
//     archivo, para que el mensaje se pueda revisar con psql y no existan dos
//     versiones del formato.
//   - Si no hay remisiones VENCIDAS no se manda nada. Una remisión pendiente
//     dentro de plazo es el curso normal de las cosas; avisarla cada mañana
//     conseguiría que dejaran de leerse las alertas, y entonces la que importa
//     se pierde con las demás.
// ---------------------------------------------------------------------------

import { enviarMensaje } from '../telegram.js';

export const tipo = 'alertas_remisiones';

// Van a quien puede hacer algo: llamar al laboratorio, cargar el resultado o
// anular la remisión.
const SQL_DESTINATARIOS = `
  SELECT DISTINCT u.id, u.nombre_completo, u.telegram_chat_id
    FROM usuario u
    JOIN v_usuario_permiso vp ON vp.usuario_id = u.id
   WHERE vp.permiso_codigo = 'remision.gestionar'
     AND u.activo
     AND u.telegram_chat_id IS NOT NULL
   ORDER BY u.nombre_completo
`;

export async function manejar({ payload }, { db, log }) {
  const { rows: hay } = await db.query('SELECT hay_alertas_remisiones() AS hay');

  if (!hay[0]?.hay && !payload?.forzar) {
    log.info('sin remisiones vencidas: no se envía alerta');
    return { enviado: false, motivo: 'sin_novedades' };
  }

  const { rows: texto } = await db.query('SELECT bot_texto_alertas_remisiones() AS t');
  const { rows: destinatarios } = await db.query(SQL_DESTINATARIOS);

  if (destinatarios.length === 0) {
    log.aviso('no hay quien gestione remisiones con telegram_chat_id; la alerta no se entrega');
    return { enviado: false, motivo: 'sin_destinatarios' };
  }

  let enviados = 0;
  const fallos = [];

  // El texto ya viene escapado desde la base: aquí no se vuelve a escapar, o
  // se verían las etiquetas <b> literales.
  for (const d of destinatarios) {
    try {
      const r = await enviarMensaje(d.telegram_chat_id, texto[0].t);
      if (r.ok) enviados += 1;
      else fallos.push({ usuario: d.nombre_completo, motivo: r.motivo });
    } catch (err) {
      fallos.push({ usuario: d.nombre_completo, motivo: err.message });
    }
  }

  if (enviados === 0 && fallos.length > 0) {
    throw new Error(
      `no se pudo entregar la alerta de remisiones: ${fallos.map((f) => f.motivo).join(' | ')}`,
    );
  }

  return { enviado: true, destinatarios: destinatarios.length, enviados, fallos };
}
