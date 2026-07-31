// ---------------------------------------------------------------------------
// agregar_linea_cuenta — payload {movimiento_id, turno_id, origen}
//
// Lo encola salida_medicamento(): cada salida despachada debe aparecer como
// línea en la cuenta del paciente, al precio_venta del medicamento (§6.3).
//
// TODO paso 5: el módulo de cobro (§7) todavía no existe. Cuando exista, aquí
// se busca (o se abre) la cuenta del turno, se inserta la cuenta_linea con
// cantidad y valor_unitario, y se guarda su id en
// movimiento_inventario.cuenta_linea_id.
//
// Mientras tanto es un no-op EXPLÍCITO, igual que abrir_cuenta_turno: no debe
// fallar. Si fallara, cada salida de medicamento quemaría cinco reintentos y
// dispararía una alarma al superadmin por algo que aún no está construido.
// ---------------------------------------------------------------------------

export const tipo = 'agregar_linea_cuenta';

export async function manejar({ payload }, { log }) {
  const movimientoId = payload?.movimiento_id ?? null;
  log.info(
    `agregar_linea_cuenta(mov ${movimientoId}): módulo de cobro no implementado, se omite`,
  );

  // TODO paso 5: reemplazar por la creación real de la línea (§7.1).
  return {
    pendiente: 'modulo_cobro_no_implementado',
    movimiento_id: movimientoId,
    turno_id: payload?.turno_id ?? null,
  };
}
