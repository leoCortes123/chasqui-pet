import type { Metadata } from 'next';
import Link from 'next/link';
import { consultar } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';
import { fecha, fechaHora, numero } from '@/lib/formato';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Trazabilidad de lote — Chasqui Pet',
  robots: { index: false, follow: false },
};

interface LoteEncontrado {
  lote_id: string;
  numero_lote: string;
  medicamento: string;
  fecha_vencimiento: string;
  cantidad_actual: string;
  proveedor: string;
  despachos: string;
}

interface Despacho {
  fecha: string;
  cantidad: string;
  paciente: string;
  especie: string | null;
  dueno: string;
  telefono: string | null;
  atendio: string;
  consulta_id: string | null;
}

/**
 * §10.9. Se llega por el número de lote impreso en la caja, que es lo que
 * trae el comunicado de retiro del laboratorio, y se sale con la lista de
 * dueños a los que hay que llamar, con su teléfono.
 */
export default async function PaginaTrazabilidad({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; lote?: string }>;
}) {
  await exigirPermiso('reportes.operativos', '/reportes/trazabilidad');
  const { q = '', lote } = await searchParams;

  const encontrados = q.trim()
    ? await consultar<LoteEncontrado>('SELECT * FROM buscar_lote($1, 15)', [q.trim()])
    : [];

  const despachos = lote
    ? await consultar<Despacho>('SELECT * FROM reporte_trazabilidad($1)', [lote])
    : [];

  const elegido = encontrados.find((l) => l.lote_id === lote);

  return (
    <>
      <p className={tabla.migaja}>
        <Link href="/reportes">← Reportes</Link>
      </p>
      <h1 className={estilos.titulo}>Trazabilidad de lote</h1>
      <p className={estilos.subtitulo}>
        Busca por el número de lote impreso en la caja o por el nombre del medicamento.
      </p>

      <form className={estilos.buscador} method="get">
        <input
          className={estilos.campo}
          type="search"
          name="q"
          defaultValue={q}
          placeholder="DEMO-AMX-2312, amoxicilina…"
          autoFocus
        />
        <button className={estilos.botonPrimario} type="submit">
          Buscar
        </button>
      </form>

      {q.trim() && encontrados.length === 0 && (
        <p className={estilos.vacio}>Ningún lote coincide con «{q}».</p>
      )}

      {encontrados.length > 0 && (
        <div className={tabla.desplazable}>
          <table className={tabla.tabla}>
            <thead>
              <tr>
                <th>Lote</th>
                <th>Medicamento</th>
                <th>Vence</th>
                <th className={tabla.derecha}>Quedan</th>
                <th>Proveedor</th>
                <th className={tabla.derecha}>Despachos</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {encontrados.map((l) => (
                <tr key={l.lote_id} className={l.lote_id === lote ? tabla.resaltada : undefined}>
                  <td>{l.numero_lote}</td>
                  <td>{l.medicamento}</td>
                  <td>{fecha(l.fecha_vencimiento)}</td>
                  <td className={tabla.derecha}>{numero(l.cantidad_actual)}</td>
                  <td>{l.proveedor}</td>
                  <td className={tabla.derecha}>{numero(l.despachos)}</td>
                  <td>
                    <Link
                      className={estilos.boton}
                      href={`/reportes/trazabilidad?q=${encodeURIComponent(q)}&lote=${l.lote_id}`}
                    >
                      Ver quién lo recibió
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {lote && (
        <section className={tabla.seccion}>
          <h2 className={estilos.titulo}>
            {elegido ? `Lote ${elegido.numero_lote} · ${elegido.medicamento}` : 'Despachos del lote'}
          </h2>

          {despachos.length === 0 ? (
            <p className={estilos.vacio}>De ese lote no ha salido nada todavía.</p>
          ) : (
            <div className={tabla.desplazable}>
              <table className={tabla.tabla}>
                <thead>
                  <tr>
                    <th>Cuándo</th>
                    <th className={tabla.derecha}>Cantidad</th>
                    <th>Paciente</th>
                    <th>Dueño</th>
                    <th>Teléfono</th>
                    <th>Atendió</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {despachos.map((d, i) => (
                    <tr key={i}>
                      <td>{fechaHora(d.fecha)}</td>
                      <td className={tabla.derecha}>{numero(d.cantidad)}</td>
                      <td>
                        {d.paciente}
                        {d.especie ? ` · ${d.especie}` : ''}
                      </td>
                      <td>{d.dueno}</td>
                      <td>{d.telefono ?? '—'}</td>
                      <td>{d.atendio}</td>
                      <td>
                        {d.consulta_id && (
                          <Link className={tabla.enlace} href={`/consulta/${d.consulta_id}`}>
                            Consulta
                          </Link>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      )}
    </>
  );
}
