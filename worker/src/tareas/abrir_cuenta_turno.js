// ---------------------------------------------------------------------------
// abrir_cuenta_turno — payload {turno_id}
//
// TODO paso 5: el módulo de cobro (§7) todavía no existe. Cuando exista, aquí
// se crea la `cuenta` en estado abierta para el turno, se le asocia el
// consulta_id si lo hay y se guarda cuenta_id en el turno.
//
// Mientras tanto es un no-op EXPLÍCITO: se completa con una marca de
// pendiente. No debe fallar — si fallara, cada turno finalizado terminaría
// gastando 5 reintentos y disparando una alarma al superadmin por algo que
// simplemente no está construido todavía.
// ---------------------------------------------------------------------------

export const tipo = 'abrir_cuenta_turno';

export async function manejar({ payload }, { log }) {
  const turnoId = payload?.turno_id ?? null;
  log.info(
    `abrir_cuenta_turno(${turnoId}): módulo de cobro no implementado, se omite`,
  );

  // TODO paso 5: reemplazar por la creación real de la cuenta (§7.1).
  return { pendiente: 'modulo_cobro_no_implementado', turno_id: turnoId };
}
