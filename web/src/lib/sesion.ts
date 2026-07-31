import { cookies, headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { consultarUna } from './db';

/**
 * Sesión del portal (§11.1).
 *
 * No hay contraseñas ni usuarios propios de la web: la identidad es la misma
 * de Telegram y la resuelve Postgres. Aquí sólo se lee la cookie, se pregunta
 * a la base si ese token sigue vivo y se corta el paso si no.
 *
 * La cookie guarda el token en claro porque es lo único que el navegador puede
 * presentar; en la base sólo existe su sha256 (ver `058_auth_web.sql`).
 */

export const COOKIE_SESION = 'chasquipet_sesion';

/** 30 días, igual que `sesion.expires_at` en la base. */
export const DURACION_COOKIE_SEG = 30 * 24 * 60 * 60;

export interface Sesion {
  sesion_id: string;
  usuario_id: string;
  nombre: string;
  sede_id: string | null;
  permisos: string[];
}

export async function sesionActual(): Promise<Sesion | null> {
  const token = (await cookies()).get(COOKIE_SESION)?.value;
  if (!token) return null;

  const fila = await consultarUna<{ s: Sesion | null }>(
    'SELECT sesion_por_token($1) AS s',
    [token],
  );
  return fila?.s ?? null;
}

/**
 * Sesión o pantalla de ingreso. Se conserva a dónde iba para volver ahí
 * después de entrar: perder el enlace de una consulta a medias es exactamente
 * lo que no puede pasar.
 */
export async function exigirSesion(destino?: string): Promise<Sesion> {
  const sesion = await sesionActual();
  if (sesion) return sesion;
  redirect(destino ? `/entrar?volver=${encodeURIComponent(destino)}` : '/entrar');
}

export function puede(sesion: Sesion, permiso: string): boolean {
  return sesion.permisos.includes(permiso);
}

/**
 * Corta con 403 si falta el permiso. Los permisos son datos en Postgres (§4):
 * esto sólo lee la lista que la base ya resolvió, nunca decide por su cuenta.
 */
export async function exigirPermiso(permiso: string, destino?: string): Promise<Sesion> {
  const sesion = await exigirSesion(destino);
  if (!puede(sesion, permiso)) {
    redirect('/sin-permiso');
  }
  return sesion;
}

/** IP del cliente, respetando el proxy inverso si lo hay. */
export async function ipCliente(): Promise<string | null> {
  const h = await headers();
  const reenviada = h.get('x-forwarded-for');
  const ip = reenviada?.split(',')[0]?.trim() || h.get('x-real-ip');
  return ip && ip.length > 0 ? ip : null;
}

export async function agenteCliente(): Promise<string | null> {
  return (await headers()).get('user-agent');
}
