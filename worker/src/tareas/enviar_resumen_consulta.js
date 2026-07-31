// ---------------------------------------------------------------------------
// enviar_resumen_consulta — payload {consulta_id}
//
// Al firmar una consulta, el dueño recibe por Telegram el diagnóstico, el
// tratamiento y las recomendaciones. Es lo que en la clínica se entrega en un
// papel que se pierde antes de llegar a la casa.
//
// Dos condiciones, ambas obligatorias (§12, Ley 1581 de 2012): que el dueño
// haya dado consentimiento explícito y que tengamos su chat_id. Si falta
// cualquiera de las dos la tarea se completa sin enviar nada — es un caso
// normal, no un error, y no debe gastar reintentos.
// ---------------------------------------------------------------------------

import { enviarMensaje, esc } from '../telegram.js';

export const tipo = 'enviar_resumen_consulta';

export async function manejar({ payload }, { db, log }) {
  const consultaId = payload?.consulta_id;
  if (!consultaId) throw new Error('payload sin consulta_id');

  const { rows } = await db.query(
    `SELECT consulta_json($1) AS c,
            d.telegram_chat_id AS chat_id,
            d.consentimiento_datos AS consintio,
            config_txt('nombre_clinica', 'Chasqui Pet') AS clinica
       FROM consulta c
       LEFT JOIN dueno d ON d.id = c.dueno_id
      WHERE c.id = $1`,
    [consultaId],
  );

  const fila = rows[0];
  if (!fila?.c) throw new Error(`la consulta ${consultaId} no existe`);

  const consulta = fila.c;
  if (consulta.estado !== 'firmada') {
    log.info(`consulta ${consultaId} en estado ${consulta.estado}, no se envía resumen`);
    return { enviado: false, motivo: 'no_firmada' };
  }

  if (!fila.consintio || !fila.chat_id) {
    log.info(
      `consulta ${consultaId} sin canal al dueño (consentimiento=${!!fila.consintio}), se omite`,
    );
    return { enviado: false, motivo: fila.consintio ? 'sin_chat_id' : 'sin_consentimiento' };
  }

  const paciente = consulta.paciente ?? {};
  const diagnostico = consulta.diagnostico_definitivo ?? consulta.diagnostico_presuntivo;

  const lineas = [
    `${paciente.emoji ?? '🐾'} <b>${esc(paciente.nombre ?? 'Tu mascota')}</b>`,
    `Resumen de la consulta de hoy en ${esc(fila.clinica)}.`,
    '',
    diagnostico ? `🔬 <b>Diagnóstico:</b> ${esc(diagnostico)}` : null,
    consulta.plan_tratamiento ? `💊 <b>Tratamiento:</b> ${esc(consulta.plan_tratamiento)}` : null,
    consulta.recomendaciones ? `🏠 <b>En casa:</b> ${esc(consulta.recomendaciones)}` : null,
    consulta.remision_externa ? `🏥 <b>Remisión:</b> ${esc(consulta.remision_externa)}` : null,
  ];

  if (consulta.medicamentos?.length) {
    const meds = consulta.medicamentos
      .map((m) => `${esc(m.nombre)} ${m.cantidad} ${esc(m.unidad)}`)
      .join(', ');
    lineas.push(`💉 <b>Se le aplicó/entregó:</b> ${meds}`);
  }

  if (consulta.proxima_revision) {
    // §12: se guarda en UTC, se presenta en local y en formato colombiano.
    const fecha = new Date(`${consulta.proxima_revision}T12:00:00-05:00`).toLocaleDateString(
      'es-CO',
      { timeZone: 'America/Bogota', day: '2-digit', month: '2-digit', year: 'numeric' },
    );
    lineas.push(`📅 <b>Próxima revisión:</b> ${fecha}`);
  }

  lineas.push('', 'Cualquier duda, escríbenos por aquí.');

  const r = await enviarMensaje(fila.chat_id, lineas.filter((l) => l !== null).join('\n'));
  if (!r.ok) {
    return { enviado: false, motivo: r.motivo, detalle: r.detalle };
  }

  return { enviado: true, paciente: paciente.nombre ?? null };
}
