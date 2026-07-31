// ---------------------------------------------------------------------------
// recordar_llamado_vencido — payload {sede_id}
//
// §5.2: si tras `timeout_llamado_seg` (default 180) el dueño no se presenta,
// el veterinario decide. Esta tarea no cambia el estado del turno: solo le
// recuerda al veterinario y le pone los dos botones. El cambio de estado lo
// hace n8n al recibir el callback.
//
// callback_data (lo consume el flujo de n8n):
//   turno:ausente:<uuid>   → marcar ausente y ofrecer llamar al siguiente
//   turno:presento:<uuid>  → pasar a en_atencion
// ---------------------------------------------------------------------------

import { enviarMensaje, esc, teclado } from '../telegram.js';

export const tipo = 'recordar_llamado_vencido';

export async function manejar({ payload }, { db, log }) {
  const sedeId = payload?.sede_id ?? null;

  const { rows: turnos } = await db.query(
    'SELECT turno_id, codigo, consultorio, veterinario_chat_id, segundos FROM turnos_llamado_vencido($1)',
    [sedeId],
  );

  const avisados = [];
  const sinVeterinario = [];
  const bloqueados = [];

  for (const t of turnos) {
    if (!t.veterinario_chat_id) {
      sinVeterinario.push(t.codigo);
      continue;
    }

    const minutos = Math.max(1, Math.round(Number(t.segundos) / 60));
    const texto =
      `⏱️ <b>${esc(t.codigo)}</b> lleva ${minutos} min llamado y no se ha presentado.` +
      (t.consultorio ? `\n${esc(t.consultorio)}` : '');

    const r = await enviarMensaje(t.veterinario_chat_id, texto, {
      reply_markup: teclado([
        [
          { texto: 'No se presentó', dato: `turno:ausente:${t.turno_id}` },
          { texto: 'Ya llegó', dato: `turno:presento:${t.turno_id}` },
        ],
      ]),
    });

    if (r.ok) avisados.push(t.codigo);
    else bloqueados.push({ codigo: t.codigo, motivo: r.motivo });
  }

  if (sinVeterinario.length) {
    log.aviso(
      `turnos vencidos sin chat del veterinario: ${sinVeterinario.join(', ')}`,
    );
  }

  return { vencidos: turnos.length, avisados, sin_veterinario: sinVeterinario, bloqueados };
}
