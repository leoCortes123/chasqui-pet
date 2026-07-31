import { NextResponse } from 'next/server';
import { obtenerPantalla } from '@/lib/pantalla';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const revalidate = 0;

const SIN_CACHE = {
  'Cache-Control': 'no-store, no-cache, must-revalidate',
} as const;

/**
 * JSON plano del estado de la pantalla. Es el respaldo por polling cada 5 s
 * cuando el SSE no está disponible o se cortó. Sin autenticación, igual que la
 * pantalla: no expone ningún dato personal, sólo códigos de turno.
 */
export async function GET(
  _peticion: Request,
  { params }: { params: Promise<{ sede: string }> },
): Promise<NextResponse> {
  const { sede } = await params;

  try {
    const datos = await obtenerPantalla(sede);
    if (!datos) {
      return NextResponse.json(
        { error: 'La sede no existe o no está activa.' },
        { status: 404, headers: SIN_CACHE },
      );
    }
    return NextResponse.json(datos, { status: 200, headers: SIN_CACHE });
  } catch (error) {
    console.error('[api/pantalla] error consultando la pantalla:', error);
    return NextResponse.json(
      { error: 'No se pudo consultar el estado de los turnos.' },
      { status: 503, headers: SIN_CACHE },
    );
  }
}
