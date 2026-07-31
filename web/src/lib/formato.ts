/**
 * Formato de presentación, en español de Colombia (§12).
 *
 * Vive aquí y no en cada vista para que un peso se vea igual en el
 * dashboard, en un reporte y en la ficha de un paciente. Los valores
 * llegan de Postgres como texto —`numeric` no cabe en un `number` de
 * JavaScript sin perder precisión— y se convierten sólo para pintarlos.
 */

const PESOS = new Intl.NumberFormat('es-CO', {
  style: 'currency',
  currency: 'COP',
  maximumFractionDigits: 0,
});

const NUMERO = new Intl.NumberFormat('es-CO', { maximumFractionDigits: 3 });

export function pesos(valor: unknown): string {
  const n = Number(valor ?? 0);
  return Number.isFinite(n) ? PESOS.format(n) : '—';
}

export function numero(valor: unknown): string {
  const n = Number(valor ?? 0);
  return Number.isFinite(n) ? NUMERO.format(n) : '—';
}

export function porcentaje(valor: unknown): string {
  const n = Number(valor);
  return Number.isFinite(n) ? `${NUMERO.format(n)} %` : '—';
}

/** Fecha suelta (`date` de Postgres) sin desplazarla de zona horaria. */
export function fecha(valor: unknown): string {
  if (!valor) return '—';
  const texto = valor instanceof Date ? valor.toISOString().slice(0, 10) : String(valor).slice(0, 10);
  const [a, m, d] = texto.split('-');
  return a && m && d ? `${d}/${m}/${a}` : texto;
}

const FECHA_HORA = new Intl.DateTimeFormat('es-CO', {
  timeZone: 'America/Bogota',
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
});

/** Instante (`timestamptz`) presentado en hora de Bogotá (§12). */
export function fechaHora(valor: unknown): string {
  if (!valor) return '—';
  const d = valor instanceof Date ? valor : new Date(String(valor));
  return Number.isNaN(d.getTime()) ? '—' : FECHA_HORA.format(d);
}

const HORA = new Intl.DateTimeFormat('es-CO', {
  timeZone: 'America/Bogota',
  hour: '2-digit',
  minute: '2-digit',
});

export function hora(valor: unknown): string {
  if (!valor) return '—';
  const d = valor instanceof Date ? valor : new Date(String(valor));
  return Number.isNaN(d.getTime()) ? '—' : HORA.format(d);
}

/** Hoy en Bogotá, en formato `YYYY-MM-DD`, para los campos de fecha. */
export function hoyBogota(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Bogota' }).format(new Date());
}

/** El primero del mes en curso en Bogotá: el «desde» por defecto. */
export function primeroDeMes(): string {
  return `${hoyBogota().slice(0, 7)}-01`;
}
