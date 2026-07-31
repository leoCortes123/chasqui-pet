import type { Metadata } from 'next';
import Link from 'next/link';
import { consultar } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';
import { fecha, numero, pesos } from '@/lib/formato';
import estilos from '../vistas.module.css';
import tabla from '../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Compras — Chasqui Pet',
  robots: { index: false, follow: false },
};

interface Entrada {
  entrada_id: string;
  fecha: string;
  proveedor: string;
  documento: string | null;
  valor_total: string;
  estado: string;
  lineas: string;
}

interface Proveedor {
  proveedor_id: string;
  nombre: string;
  compras: string;
  ultima: string | null;
}

/**
 * Compras y proveedores (§11.2). El registro de una entrada se hace desde
 * el chat —es donde está quien recibe la mercancía, con la caja en la
 * mano—; aquí se consulta el histórico y se ve qué quedó sin confirmar.
 */
export default async function PaginaCompras() {
  await exigirPermiso('proveedores.ver', '/compras');

  const [entradas, proveedores] = await Promise.all([
    consultar<Entrada>('SELECT * FROM entradas_recientes(25)'),
    consultar<Proveedor>('SELECT * FROM proveedores_frecuentes(20)'),
  ]);

  const borradores = entradas.filter((e) => e.estado === 'borrador');

  return (
    <>
      <h1 className={estilos.titulo}>Compras</h1>
      <p className={estilos.subtitulo}>
        Una entrada en borrador no ha tocado el inventario. Se confirma desde el bot,
        con <code>/entrada</code>.
      </p>

      {borradores.length > 0 && (
        <section>
          <h2 className={estilos.titulo}>Sin confirmar</h2>
          <ul className={estilos.lista}>
            {borradores.map((e) => (
              <li key={e.entrada_id} className={estilos.fila}>
                <span className={estilos.emoji}>📥</span>
                <span className={estilos.filaTexto}>
                  <span className={estilos.filaNombre}>{e.proveedor}</span>
                  <span className={estilos.filaDetalle}>
                    {[
                      fecha(e.fecha),
                      e.documento ? `factura ${e.documento}` : null,
                      `${e.lineas} renglón(es)`,
                      pesos(e.valor_total),
                    ]
                      .filter(Boolean)
                      .join(' · ')}
                  </span>
                </span>
                <span className={`${estilos.etiqueta} ${estilos.borrador}`}>borrador</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Últimas entradas</h2>
        {entradas.length === 0 ? (
          <p className={estilos.vacio}>Todavía no se ha registrado ninguna compra.</p>
        ) : (
          <div className={tabla.desplazable}>
            <table className={tabla.tabla}>
              <thead>
                <tr>
                  <th>Fecha</th>
                  <th>Proveedor</th>
                  <th>Factura</th>
                  <th className={tabla.derecha}>Renglones</th>
                  <th className={tabla.derecha}>Valor</th>
                  <th>Estado</th>
                </tr>
              </thead>
              <tbody>
                {entradas.map((e) => (
                  <tr key={e.entrada_id}>
                    <td>{fecha(e.fecha)}</td>
                    <td>{e.proveedor}</td>
                    <td>{e.documento ?? '—'}</td>
                    <td className={tabla.derecha}>{numero(e.lineas)}</td>
                    <td className={tabla.derecha}>{pesos(e.valor_total)}</td>
                    <td>{e.estado}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className={estilos.subtitulo} style={{ marginTop: '1rem' }}>
          <Link className={tabla.enlace} href="/reportes/compras">
            Reporte de compras por proveedor →
          </Link>
        </p>
      </section>

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Proveedores</h2>
        {proveedores.length === 0 ? (
          <p className={estilos.vacio}>
            Todavía no hay proveedores. El primero se crea al registrar una entrada
            desde el bot.
          </p>
        ) : (
          <div className={tabla.desplazable}>
            <table className={tabla.tabla}>
              <thead>
                <tr>
                  <th>Proveedor</th>
                  <th className={tabla.derecha}>Compras</th>
                  <th>Última</th>
                </tr>
              </thead>
              <tbody>
                {proveedores.map((p) => (
                  <tr key={p.proveedor_id}>
                    <td>{p.nombre}</td>
                    <td className={tabla.derecha}>{numero(p.compras)}</td>
                    <td>{p.ultima ? fecha(p.ultima) : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}
