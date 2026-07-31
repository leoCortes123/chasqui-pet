import { consultarUna } from './db';

/**
 * Contrato con la base de datos. Lo produce la función SQL `pantalla_publica`.
 * NO se transforma ni se reordena en la web: lo que devuelve Postgres es lo que
 * ve la pantalla. Si algo hay que cambiar, se cambia en la función SQL.
 */

export type EstadoTurno = 'llamado' | 'en_atencion';

export interface ConsultorioPantalla {
  consultorio: string;
  abierto: boolean;
  turno: string | null;
  estado: EstadoTurno | null;
}

export interface DatosPantalla {
  sede: string;
  /** Hora local de la sede, formato HH:MM:SS. La calcula Postgres. */
  actualizado: string;
  en_espera: number;
  consultorios: ConsultorioPantalla[];
  siguientes: string[];
}

export interface Sede {
  id: string;
  nombre: string;
}

const RE_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Evita ir a la base con un parámetro de ruta que ni siquiera es un uuid. */
export function esUuid(valor: string): boolean {
  return RE_UUID.test(valor);
}

/** Devuelve la sede si existe y está activa; `null` en cualquier otro caso. */
export async function buscarSedeActiva(sedeId: string): Promise<Sede | null> {
  if (!esUuid(sedeId)) return null;
  return consultarUna<Sede>(
    'SELECT id::text AS id, nombre FROM sede WHERE id = $1 AND activa',
    [sedeId],
  );
}

/**
 * Lee el estado de la pantalla. Devuelve `null` si la sede no existe o no está
 * activa, para que la ruta responda 404 en vez de una pantalla vacía.
 */
export async function obtenerPantalla(
  sedeId: string,
): Promise<DatosPantalla | null> {
  if (!esUuid(sedeId)) return null;

  const sede = await buscarSedeActiva(sedeId);
  if (!sede) return null;

  const fila = await consultarUna<{ datos: DatosPantalla }>(
    'SELECT pantalla_publica($1) AS datos',
    [sedeId],
  );
  return fila?.datos ?? null;
}
