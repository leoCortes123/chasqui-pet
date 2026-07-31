import { NextResponse } from 'next/server';
import { verificarBase } from '@/lib/db';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const revalidate = 0;

const SIN_CACHE = {
  'Cache-Control': 'no-store, no-cache, must-revalidate',
} as const;

/**
 * Health check del servicio web (§2.2.11).
 * 200 si Postgres responde, 503 si no. Nunca se cachea: un health check
 * cacheado no sirve para nada.
 */
export async function GET(): Promise<NextResponse> {
  // §12: se almacena en UTC pero se presenta en hora de Bogotá. Quien lea
  // este endpoint está mirando un tablero, no una base de datos.
  const hora = new Date().toLocaleString('es-CO', {
    timeZone: 'America/Bogota',
    dateStyle: 'short',
    timeStyle: 'medium',
  });

  try {
    await verificarBase();
    return NextResponse.json(
      { ok: true, db: 'ok', hora },
      { status: 200, headers: SIN_CACHE },
    );
  } catch (error) {
    const detalle = error instanceof Error ? error.message : String(error);
    console.error('[health] Postgres no responde:', detalle);
    return NextResponse.json(
      { ok: false, db: 'error', hora, error: detalle },
      { status: 503, headers: SIN_CACHE },
    );
  }
}
