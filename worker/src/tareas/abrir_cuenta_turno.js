// ---------------------------------------------------------------------------
// abrir_cuenta_turno — payload {turno_id}
//
// La encola iniciar_atencion(): la cuenta se abre sola al entrar el turno en
// atención (§7.2.1), para que el veterinario no tenga que acordarse de nada y
// las salidas de medicamento tengan dónde caer.
//
// Toda la lógica vive en abrir_cuenta_para_turno(), que es idempotente: si el
// worker reintenta, o el turno vuelve a atención, no se duplica la cuenta.
// ---------------------------------------------------------------------------

export const tipo = 'abrir_cuenta_turno';

export async function manejar({ payload }, { db, log }) {
  const turnoId = payload?.turno_id;
  if (!turnoId) throw new Error('payload sin turno_id');

  const { rows } = await db.query('SELECT abrir_cuenta_para_turno($1, NULL, $2) AS r', [
    turnoId,
    'job',
  ]);
  const r = rows[0].r;

  if (!r.ok) {
    // El turno ya no está (datos de demo recargados, por ejemplo). No es un
    // error que merezca cinco reintentos ni una alarma al superadmin.
    log.aviso(`abrir_cuenta_turno(${turnoId}): ${r.mensaje}`);
    return { abierta: false, motivo: r.motivo };
  }

  return { abierta: !r.ya_existia, cuenta_id: r.cuenta?.cuenta_id ?? null };
}
