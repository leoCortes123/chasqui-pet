import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ejecutarReporte, reportePorClave, type Columna, type FilaReporte } from '@/lib/reportes';
import { exigirPermiso } from '@/lib/sesion';
import { fecha, fechaHora, numero, pesos, porcentaje, primeroDeMes, hoyBogota } from '@/lib/formato';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

type Parametros = { params: Promise<{ clave: string }>; searchParams: Promise<Record<string, string | undefined>> };

export async function generateMetadata({ params }: Parametros): Promise<Metadata> {
  const { clave } = await params;
  const reporte = reportePorClave(clave);
  return {
    title: `${reporte?.titulo ?? 'Reporte'} — Chasqui Pet`,
    robots: { index: false, follow: false },
  };
}

/** Formatea una celda según el tipo declarado en la lista de reportes. */
function celda(valor: unknown, columna: Columna): string {
  if (valor === null || valor === undefined || valor === '') return '—';
  switch (columna.tipo) {
    case 'dinero':
      return pesos(valor);
    case 'numero':
      return numero(valor);
    case 'pct':
      return porcentaje(valor);
    case 'fecha':
      return fecha(valor);
    case 'fecha_hora':
      return fechaHora(valor);
    default:
      return String(valor);
  }
}

const NUMERICOS = new Set(['dinero', 'numero', 'pct']);

export default async function PaginaReporte({ params, searchParams }: Parametros) {
  const { clave } = await params;
  const reporte = reportePorClave(clave);
  if (!reporte) notFound();

  await exigirPermiso(reporte.permiso, `/reportes/${clave}`);

  const filtros = await searchParams;
  const desde = reporte.conRango ? (filtros.desde || primeroDeMes()) : null;
  const hasta = reporte.conRango ? (filtros.hasta || hoyBogota()) : null;

  const filas: FilaReporte[] = await ejecutarReporte(reporte, desde, hasta);

  const csv = new URLSearchParams();
  if (desde) csv.set('desde', desde);
  if (hasta) csv.set('hasta', hasta);

  return (
    <>
      <p className={tabla.migaja}>
        <Link href="/reportes">← Reportes</Link>
      </p>
      <h1 className={estilos.titulo}>{reporte.titulo}</h1>
      <p className={estilos.subtitulo}>{reporte.descripcion}</p>

      <form className={tabla.filtros} method="get">
        {reporte.conRango && (
          <>
            <label className={tabla.filtro}>
              Desde
              <input className={estilos.campo} type="date" name="desde" defaultValue={desde ?? ''} />
            </label>
            <label className={tabla.filtro}>
              Hasta
              <input className={estilos.campo} type="date" name="hasta" defaultValue={hasta ?? ''} />
            </label>
            <button className={estilos.botonPrimario} type="submit">
              Ver
            </button>
          </>
        )}
        <a className={estilos.boton} href={`/api/reportes/${reporte.clave}?${csv.toString()}`}>
          Descargar CSV
        </a>
      </form>

      {filas.length === 0 ? (
        <p className={estilos.vacio}>No hay datos en ese período.</p>
      ) : (
        <>
          <div className={tabla.desplazable}>
            <table className={tabla.tabla}>
              <thead>
                <tr>
                  {reporte.columnas.map((c) => (
                    <th key={c.clave} className={NUMERICOS.has(c.tipo ?? '') ? tabla.derecha : undefined}>
                      {c.titulo}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {filas.map((f, i) => (
                  <tr key={i}>
                    {reporte.columnas.map((c) => (
                      <td key={c.clave} className={NUMERICOS.has(c.tipo ?? '') ? tabla.derecha : undefined}>
                        {celda(f[c.clave], c)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className={estilos.subtitulo} style={{ marginTop: '1rem' }}>
            {filas.length} {filas.length === 1 ? 'fila' : 'filas'}.
          </p>
        </>
      )}
    </>
  );
}
