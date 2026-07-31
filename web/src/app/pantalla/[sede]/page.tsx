import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { obtenerPantalla } from '@/lib/pantalla';
import VistaPantalla from './vista-pantalla';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const revalidate = 0;

/** Nombre de la clínica que se muestra cuando no hay nadie en atención. */
const CLINICA = process.env.NOMBRE_CLINICA ?? 'Chasqui Pet';

export const metadata: Metadata = {
  title: 'Turnos — Chasqui Pet',
  robots: { index: false, follow: false },
};

/**
 * Pantalla pública de turnos para el monitor de la sala de espera (§5.5).
 *
 * Sin autenticación y sin ningún dato personal: sólo códigos de turno y
 * consultorio. El primer render se hace en el servidor con datos reales, así el
 * monitor nunca muestra una pantalla en blanco mientras carga.
 */
export default async function PaginaPantalla({
  params,
}: {
  params: Promise<{ sede: string }>;
}) {
  const { sede } = await params;

  const datos = await obtenerPantalla(sede);
  if (!datos) notFound();

  return (
    <VistaPantalla sedeId={sede} clinica={CLINICA} datosIniciales={datos} />
  );
}
