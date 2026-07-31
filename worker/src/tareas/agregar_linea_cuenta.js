// ---------------------------------------------------------------------------
// agregar_linea_cuenta — payload {movimiento_id, turno_id, origen}
//
// La encola salida_medicamento(): cada medicamento despachado aparece como
// línea en la cuenta del paciente, al precio_venta del catálogo (§6.3). El
// veterinario no teclea nada; el auxiliar se encuentra la cuenta ya armada.
//
// agregar_linea_medicamento() es idempotente por movimiento_id —hay un UNIQUE
// en cuenta_linea.movimiento_id—, así que un reintento no cobra dos veces.
// ---------------------------------------------------------------------------

export const tipo = 'agregar_linea_cuenta';

// Casos que no son un error: la salida no está atada a una visita (uso
// interno, muestra) o la cuenta ya se cerró. Reintentar no los arregla.
const NO_REINTENTAR = new Set(['sin_turno', 'cuenta_cerrada', 'no_es_salida']);

export async function manejar({ payload }, { db, log }) {
  const movimientoId = payload?.movimiento_id;
  if (!movimientoId) throw new Error('payload sin movimiento_id');

  const { rows } = await db.query('SELECT agregar_linea_medicamento($1, NULL, $2) AS r', [
    movimientoId,
    'job',
  ]);
  const r = rows[0].r;

  if (!r.ok) {
    if (NO_REINTENTAR.has(r.motivo)) {
      log.info(`agregar_linea_cuenta(mov ${movimientoId}): ${r.mensaje}`);
      return { agregada: false, motivo: r.motivo };
    }
    throw new Error(r.mensaje ?? `no se pudo cobrar el movimiento ${movimientoId}`);
  }

  return {
    agregada: !r.ya_existia,
    linea_id: r.linea_id ?? null,
    cuenta_id: r.cuenta?.cuenta_id ?? null,
    total: r.cuenta?.total ?? null,
  };
}
