// ---------------------------------------------------------------------------
// notificar_superadmin — payload {texto}
//
// Canal de alarmas del sistema: lo usa fallar_tarea() cuando una tarea agota
// sus reintentos, y cualquier flujo que necesite avisar a quien administra.
//
// CUIDADO: esta tarea no debe fallar por "no hay a quién avisar". Si fallara,
// fallar_tarea encolaría otro notificar_superadmin para avisar que el aviso
// falló, y así en bucle. Cuando no hay destinatarios se registra en el log y
// se completa.
// ---------------------------------------------------------------------------

import { enviarMensaje, esc } from '../telegram.js';

export const tipo = 'notificar_superadmin';

const SQL_DESTINATARIOS = `
  SELECT DISTINCT u.id, u.nombre_completo, u.telegram_chat_id
    FROM usuario u
    JOIN usuario_rol ur ON ur.usuario_id = u.id
   WHERE ur.rol_codigo = 'superadmin'
     AND u.activo
     AND u.telegram_chat_id IS NOT NULL
   ORDER BY u.nombre_completo
`;

export async function manejar({ payload }, { db, log }) {
  const texto = payload?.texto;
  if (!texto) throw new Error('payload sin texto');

  const { rows: destinatarios } = await db.query(SQL_DESTINATARIOS);

  if (destinatarios.length === 0) {
    log.aviso(
      'no hay superadmin activo con telegram_chat_id; el aviso no se entrega: ' +
        String(texto).replace(/\s+/g, ' ').slice(0, 200),
    );
    return { enviado: false, motivo: 'sin_superadmin_con_chat' };
  }

  // El texto viene de la base o de otro flujo: se escapa completo y se envía
  // como texto plano dentro del HTML, nunca como marcado confiable.
  const cuerpo = esc(texto);

  let enviados = 0;
  const fallos = [];

  for (const d of destinatarios) {
    try {
      const r = await enviarMensaje(d.telegram_chat_id, cuerpo);
      if (r.ok) enviados += 1;
      else fallos.push({ usuario: d.nombre_completo, motivo: r.motivo });
    } catch (err) {
      fallos.push({ usuario: d.nombre_completo, motivo: err.message });
    }
  }

  // Si NINGUNO recibió y hubo fallos recuperables, sí conviene reintentar.
  if (enviados === 0 && fallos.length > 0) {
    throw new Error(
      `no se pudo avisar a ningún superadmin: ${fallos.map((f) => f.motivo).join(' | ')}`,
    );
  }

  return { enviado: true, destinatarios: destinatarios.length, enviados, fallos };
}
