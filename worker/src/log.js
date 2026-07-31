// ---------------------------------------------------------------------------
// Logs a stdout, en español y con hora de Bogotá.
//
// Todo va a stdout (nunca a archivo): en Docker los logs los recoge el runtime.
// Una línea por evento, sin colores ni adornos, para que `docker logs` y un
// grep basten para depurar en la clínica.
// ---------------------------------------------------------------------------

const FORMATO_HORA = new Intl.DateTimeFormat('es-CO', {
  timeZone: 'America/Bogota',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hour12: false,
});

/** Marca de tiempo `2026-07-30 14:05:09` en hora de Bogotá. */
export function ahora() {
  const p = Object.fromEntries(
    FORMATO_HORA.formatToParts(new Date()).map((x) => [x.type, x.value]),
  );
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`;
}

function escribir(nivel, mensaje) {
  process.stdout.write(`[${ahora()}] ${nivel} ${mensaje}\n`);
}

export const log = {
  info: (m) => escribir('INFO ', m),
  aviso: (m) => escribir('AVISO', m),
  error: (m) => escribir('ERROR', m),
};

/** Mensaje legible de cualquier cosa que se haya lanzado. */
export function textoError(err) {
  if (err instanceof Error) return err.message || err.name;
  if (typeof err === 'string') return err;
  try {
    return JSON.stringify(err);
  } catch {
    return String(err);
  }
}
