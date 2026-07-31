import { NextResponse } from 'next/server';
import { aCsv, ejecutarReporte, reportePorClave } from '@/lib/reportes';
import { puede, sesionActual } from '@/lib/sesion';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Exportación a CSV (§10). Es el mismo reporte que la pantalla, con otra
 * cabecera: no hay una segunda consulta que pueda quedar desalineada.
 *
 * A diferencia de las páginas, aquí no se redirige a `/entrar`: una
 * descarga sin sesión responde 401 y 403, que es lo que un cliente HTTP
 * puede entender.
 */
export async function GET(
  peticion: Request,
  contexto: { params: Promise<{ clave: string }> },
) {
  const { clave } = await contexto.params;
  const reporte = reportePorClave(clave);
  if (!reporte) {
    return NextResponse.json({ error: 'Ese reporte no existe' }, { status: 404 });
  }

  const sesion = await sesionActual();
  if (!sesion) {
    return NextResponse.json({ error: 'Sin sesión' }, { status: 401 });
  }
  if (!puede(sesion, reporte.permiso)) {
    return NextResponse.json({ error: 'Sin permiso' }, { status: 403 });
  }

  const url = new URL(peticion.url);
  const filas = await ejecutarReporte(
    reporte,
    url.searchParams.get('desde'),
    url.searchParams.get('hasta'),
  );

  const hoy = new Date().toISOString().slice(0, 10);

  return new NextResponse(aCsv(reporte, filas), {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="chasquipet-${reporte.clave}-${hoy}.csv"`,
      'Cache-Control': 'no-store',
    },
  });
}
