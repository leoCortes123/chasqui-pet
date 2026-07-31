import type { Metadata } from 'next';
import Link from 'next/link';
import { REPORTES } from '@/lib/reportes';
import { exigirSesion, puede } from '@/lib/sesion';
import estilos from '../vistas.module.css';
import tabla from '../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Reportes — Chasqui Pet',
  robots: { index: false, follow: false },
};

const GRUPOS = ['Operación', 'Inventario', 'Dinero', 'Clínica'] as const;

/**
 * Índice de reportes. Sólo aparecen los que la sesión puede abrir: quien
 * no tiene `reportes.financieros` no ve siquiera el nombre de los de
 * caja y margen.
 */
export default async function PaginaReportes() {
  const sesion = await exigirSesion('/reportes');
  const visibles = REPORTES.filter((r) => puede(sesion, r.permiso));

  return (
    <>
      <h1 className={estilos.titulo}>Reportes</h1>
      <p className={estilos.subtitulo}>
        Todos se filtran por fechas y se exportan a CSV.
      </p>

      {visibles.length === 0 && (
        <p className={estilos.vacio}>
          Tu usuario no tiene permiso para ver reportes. Habla con el administrador.
        </p>
      )}

      {GRUPOS.map((grupo) => {
        const delGrupo = visibles.filter((r) => r.grupo === grupo);
        if (delGrupo.length === 0) return null;

        return (
          <section key={grupo} className={tabla.seccion}>
            <h2 className={estilos.titulo}>{grupo}</h2>
            <div className={tabla.tarjetas}>
              {delGrupo.map((r) => (
                <Link key={r.clave} className={tabla.tarjeta} href={`/reportes/${r.clave}`}>
                  <span className={tabla.tarjetaTitulo}>{r.titulo}</span>
                  <span className={tabla.tarjetaDetalle}>{r.descripcion}</span>
                </Link>
              ))}
            </div>
          </section>
        );
      })}

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Trazabilidad de lote</h2>
        <div className={tabla.tarjetas}>
          <Link className={tabla.tarjeta} href="/reportes/trazabilidad">
            <span className={tabla.tarjetaTitulo}>Qué pacientes recibieron un lote</span>
            <span className={tabla.tarjetaDetalle}>
              La consulta del día en que un laboratorio retira un producto del mercado.
            </span>
          </Link>
        </div>
      </section>
    </>
  );
}
