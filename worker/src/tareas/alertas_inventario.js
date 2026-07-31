// ---------------------------------------------------------------------------
// alertas_inventario — payload {} (opcional: {forzar: true})
//
// El aviso diario del §6.2: qué está bajo el mínimo, qué vence pronto y qué
// venció y sigue en la estantería. Lo encola el job de n8n una vez al día.
//
// Dos cuidados:
//   - El texto lo arma la BASE (bot_texto_alertas_inventario), no este
//     archivo. Así el mismo mensaje se puede revisar con psql y no hay dos
//     versiones del formato.
//   - Si no hay nada que reportar NO se manda nada. Un «todo en orden» cada
//     mañana es la forma más rápida de que el administrador deje de leer las
//     alertas, y entonces la que importa también se pierde.
// ---------------------------------------------------------------------------

import { enviarMensaje } from '../telegram.js';

export const tipo = 'alertas_inventario';

// Van a quien administra el inventario, que es quien puede hacer algo al
// respecto: pedir, ajustar o dar de baja.
const SQL_DESTINATARIOS = `
  SELECT DISTINCT u.id, u.nombre_completo, u.telegram_chat_id
    FROM usuario u
    JOIN v_usuario_permiso vp ON vp.usuario_id = u.id
   WHERE vp.permiso_codigo = 'inventario.ajuste'
     AND u.activo
     AND u.telegram_chat_id IS NOT NULL
   ORDER BY u.nombre_completo
`;

export async function manejar({ payload }, { db, log }) {
  const { rows: hay } = await db.query('SELECT hay_alertas_inventario() AS hay');

  if (!hay[0]?.hay && !payload?.forzar) {
    log.info('inventario sin novedades: no se envía alerta');
    return { enviado: false, motivo: 'sin_novedades' };
  }

  const { rows: texto } = await db.query('SELECT bot_texto_alertas_inventario() AS t');
  const { rows: destinatarios } = await db.query(SQL_DESTINATARIOS);

  if (destinatarios.length === 0) {
    log.aviso('no hay quien administre inventario con telegram_chat_id; la alerta no se entrega');
    return { enviado: false, motivo: 'sin_destinatarios' };
  }

  let enviados = 0;
  const fallos = [];

  // El texto ya viene escapado desde la base (esc() por valor interpolado):
  // aquí no se vuelve a escapar, o se verían las etiquetas <b> literales.
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
      `no se pudo entregar la alerta de inventario: ${fallos.map((f) => f.motivo).join(' | ')}`,
    );
  }

  return { enviado: true, destinatarios: destinatarios.length, enviados, fallos };
}
