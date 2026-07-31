import type { Metadata } from 'next';
import { redirect } from 'next/navigation';
import { sesionActual } from '@/lib/sesion';
import Ingreso from './ingreso';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Ingresar — Chasqui Pet',
  robots: { index: false, follow: false },
};

/**
 * Pantalla de ingreso al portal (§11.1).
 *
 * No pide usuario ni contraseña: muestra un código y el enlace al bot. Quien
 * no tenga usuario aprovisionado en Telegram no entra, y el bot no le dice si
 * el código existía.
 */
export default async function PaginaEntrar({
  searchParams,
}: {
  searchParams: Promise<{ volver?: string }>;
}) {
  const { volver } = await searchParams;

  // Ya con sesión: no tiene sentido pedir otro código.
  if (await sesionActual()) {
    redirect(destinoSeguro(volver));
  }

  return <Ingreso volver={destinoSeguro(volver)} />;
}

/**
 * Sólo se admite volver a una ruta de este mismo sitio. Sin esto, un enlace
 * `?volver=https://…` convertiría la pantalla de ingreso en un redirector
 * hacia cualquier parte.
 */
function destinoSeguro(volver: string | undefined): string {
  if (!volver || !volver.startsWith('/') || volver.startsWith('//')) {
    return '/consultas';
  }
  return volver;
}
