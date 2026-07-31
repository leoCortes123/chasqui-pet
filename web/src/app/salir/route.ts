import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { consultar } from '@/lib/db';
import { COOKIE_SESION } from '@/lib/sesion';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Cierra la sesión. POST y no GET: un enlace de salir se dispara solo con
 * cualquier precarga del navegador.
 *
 * La sesión se revoca en la base además de borrar la cookie — si sólo se
 * borrara la cookie, el token seguiría siendo válido para quien lo tuviera.
 */
export async function POST(peticion: Request): Promise<NextResponse> {
  const galletas = await cookies();
  const token = galletas.get(COOKIE_SESION)?.value;

  if (token) {
    await consultar('SELECT cerrar_sesion_web($1)', [token]);
  }

  galletas.delete(COOKIE_SESION);

  return NextResponse.redirect(new URL('/entrar', peticion.url), { status: 303 });
}
