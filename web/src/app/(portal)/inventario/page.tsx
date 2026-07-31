import type { Metadata } from 'next';
import Link from 'next/link';
import { consultar } from '@/lib/db';
import { exigirPermiso, puede } from '@/lib/sesion';
import { Catalogo, type FilaCatalogo } from './catalogo';
import estilos from '../vistas.module.css';
import tabla from '../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Inventario — Chasqui Pet',
  robots: { index: false, follow: false },
};

/**
 * Catálogo de medicamentos y precios. Es la vista que justifica el portal:
 * corregir quince precios por chat sería una tortura, y por eso §11.2 la
 * manda aquí.
 */
export default async function PaginaInventario({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const sesion = await exigirPermiso('inventario.ver', '/inventario');
  const { q = '' } = await searchParams;

  const filas = await consultar<FilaCatalogo>('SELECT * FROM catalogo_medicamentos($1)', [
    q.trim() || null,
  ]);

  return (
    <>
      <h1 className={estilos.titulo}>Inventario</h1>
      <p className={estilos.subtitulo}>
        El precio de venta vive en el catálogo; el costo, en cada lote. Cambiar un
        precio no recalcula lo ya cobrado.
      </p>

      <div className={tabla.filtros}>
        <form className={estilos.buscador} method="get" style={{ marginBottom: 0, flex: 1 }}>
          <input
            className={estilos.campo}
            type="search"
            name="q"
            defaultValue={q}
            placeholder="Buscar medicamento…"
          />
          <button className={estilos.botonPrimario} type="submit">
            Buscar
          </button>
        </form>
        <Link className={estilos.boton} href="/inventario/movimientos">
          Libro de movimientos
        </Link>
        <Link className={estilos.boton} href="/reportes/stock">
          Reporte de stock
        </Link>
      </div>

      {filas.length === 0 ? (
        <p className={estilos.vacio}>
          {q ? `Nada se parece a «${q}».` : 'El catálogo está vacío.'}
        </p>
      ) : (
        <Catalogo filas={filas} puedeEditar={puede(sesion, 'inventario.catalogo')} />
      )}
    </>
  );
}
