import { consultarUna } from './db';

/**
 * Lectura de la agenda para el portal (Fase B1b).
 *
 * Igual que `clinico.ts`: lo que devuelven las funciones SQL se muestra tal
 * cual. La web no recalcula cupos ni decide qué cita se puede tocar — eso lo
 * dice `agenda_del_dia` / `horarios_disponibles`, y el bot ve exactamente lo
 * mismo.
 */

export interface Cita {
  cita_id: string;
  estado: 'programada' | 'confirmada' | 'cumplida' | 'cancelada' | 'no_asistio';
  inicio: string;
  fin: string;
  fecha: string;
  hora: string;
  duracion_min: number;
  sede_id: string;
  tipo: string;
  tipo_nombre: string;
  paciente_id: string | null;
  paciente: { nombre: string; especie: string; emoji: string } | null;
  dueno_id: string | null;
  dueno: string | null;
  veterinario_id: string | null;
  veterinario: string | null;
  consultorio_id: string | null;
  consultorio: string | null;
  turno_id: string | null;
  turno: string | null;
  notas: string | null;
  motivo_cancelacion: string | null;
  recordatorio_enviado_at: string | null;
}

export interface AgendaDia {
  ok: boolean;
  fecha: string;
  sede_id: string;
  citas: Cita[];
  total: number;
  por_estado: Record<string, number>;
}

export interface Cupo {
  inicio: string;
  fin: string;
  hora: string;
  veterinario_id: string | null;
  veterinario: string | null;
  consultorio_id: string | null;
}

export interface Cupos {
  ok: boolean;
  fecha: string;
  tipo: string;
  duracion_min: number;
  slots: Cupo[];
  total: number;
  motivo?: string;
  mensaje?: string;
}

export async function agendaDelDia(
  usuarioId: string,
  sedeId: string | null,
  fecha: string,
): Promise<AgendaDia | null> {
  const fila = await consultarUna<{ a: AgendaDia | null }>(
    'SELECT agenda_del_dia($1, $2, $3::date) AS a',
    [usuarioId, sedeId, fecha],
  );
  return fila?.a ?? null;
}

export async function cuposDelDia(
  usuarioId: string,
  sedeId: string | null,
  fecha: string,
  tipo = 'general',
): Promise<Cupos | null> {
  const fila = await consultarUna<{ c: Cupos | null }>(
    'SELECT horarios_disponibles($1, $2, $3::date, $4) AS c',
    [usuarioId, sedeId, fecha, tipo],
  );
  return fila?.c ?? null;
}

/** Un control anotado en una consulta y todavía sin cita (Fase B2). */
export interface ControlPendiente {
  consulta_id: string;
  fecha_control: string;
  dias_faltan: number;
  vencido: boolean;
  paciente_id: string;
  paciente: string;
  especie: string;
  dueno_id: string | null;
  dueno: string | null;
  telefono: string | null;
  /** Si se le puede escribir por Telegram: consentimiento + chat (§12). */
  avisable: boolean;
  avisado: boolean;
  veterinario: string | null;
  consulta_fecha: string;
}

export interface Controles {
  ok: boolean;
  sede_id: string;
  hasta: string;
  controles: ControlPendiente[];
  total: number;
  vencidos: number;
}

export async function controlesPendientes(
  usuarioId: string,
  sedeId: string | null,
  dias = 15,
): Promise<Controles | null> {
  const fila = await consultarUna<{ c: Controles | null }>(
    'SELECT controles_pendientes($1, $2, $3) AS c',
    [usuarioId, sedeId, dias],
  );
  return fila?.c ?? null;
}

export interface TipoServicio {
  codigo: string;
  nombre: string;
  duracion_estimada_min: number;
}

export async function tiposDeServicio(): Promise<TipoServicio[]> {
  const fila = await consultarUna<{ t: TipoServicio[] }>(
    `SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'codigo', codigo, 'nombre', nombre,
              'duracion_estimada_min', duracion_estimada_min) ORDER BY orden), '[]'::jsonb) AS t
       FROM tipo_servicio WHERE activo`,
  );
  return fila?.t ?? [];
}

/** Fecha de hoy en Bogotá, en AAAA-MM-DD. La decide la base, no el servidor. */
export async function hoyBogota(): Promise<string> {
  const fila = await consultarUna<{ f: string }>('SELECT hoy_bogota()::text AS f');
  return fila?.f ?? new Date().toISOString().slice(0, 10);
}

const RE_FECHA = /^\d{4}-\d{2}-\d{2}$/;

/** Una fecha que viene de la URL no se pasa a SQL sin mirarla. */
export function esFecha(valor: string): boolean {
  return RE_FECHA.test(valor) && !Number.isNaN(Date.parse(valor));
}

/** Suma días a AAAA-MM-DD sin depender de la zona del servidor. */
export function desplazarFecha(fecha: string, dias: number): string {
  const t = Date.UTC(
    Number(fecha.slice(0, 4)),
    Number(fecha.slice(5, 7)) - 1,
    Number(fecha.slice(8, 10)),
  );
  return new Date(t + dias * 86_400_000).toISOString().slice(0, 10);
}

const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
const MESES = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

/** «martes 13 de agosto». Se arma a mano: `toLocaleDateString` depende de los
 *  datos de idioma que traiga la imagen de Node, y aquí el idioma es fijo. */
export function fechaLarga(fecha: string): string {
  const d = new Date(`${fecha}T12:00:00Z`);
  return `${DIAS[d.getUTCDay()]} ${d.getUTCDate()} de ${MESES[d.getUTCMonth()]}`;
}

export const ETIQUETA_ESTADO: Record<Cita['estado'], string> = {
  programada: 'programada',
  confirmada: 'confirmada',
  cumplida: 'atendida',
  cancelada: 'cancelada',
  no_asistio: 'no asistió',
};
