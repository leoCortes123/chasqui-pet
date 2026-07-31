import type { Metadata } from 'next';
import Link from 'next/link';
import { consultar } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';
import { fechaHora, numero } from '@/lib/formato';
import { AccionesTarea } from './acciones-tarea';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Tareas — Chasqui Pet',
  robots: { index: false, follow: false },
};

interface Tarea {
  id: string;
  tipo: string;
  estado: string;
  intentos: number;
  max_intentos: number;
  proxima_ejecucion: string;
  ultimo_error: string | null;
  payload: unknown;
  created_at: string;
}

interface Resumen {
  estado: string;
  tareas: string;
  mas_antigua: string;
}

const ESTADOS = [
  ['fallida', 'Fallidas'],
  ['pendiente', 'Pendientes'],
  ['procesando', 'En proceso'],
  ['completada', 'Completadas'],
  ['', 'Todas'],
] as const;

/**
 * Bandeja de tareas (§2.2.4). Es lo que se mira cuando un dueño dice que
 * no le llegó el recibo: la tarea está aquí, con su error y sus intentos.
 */
export default async function PaginaTareas({
  searchParams,
}: {
  searchParams: Promise<{ estado?: string }>;
}) {
  await exigirPermiso('sistema.operar', '/admin/tareas');
  const { estado = 'fallida' } = await searchParams;

  const [tareas, resumen] = await Promise.all([
    consultar<Tarea>('SELECT * FROM tareas_listado($1, 100)', [estado || null]),
    consultar<Resumen>('SELECT * FROM resumen_tareas()'),
  ]);

  return (
    <>
      <p className={tabla.migaja}>
        <Link href="/admin">← Administración</Link>
      </p>
      <h1 className={estilos.titulo}>Tareas asíncronas</h1>
      <p className={estilos.subtitulo}>
        El webhook de Telegram responde en menos de un segundo; todo lo pesado —avisos,
        recibos, alertas— pasa por esta cola.
      </p>

      <div className={tabla.indicadores}>
        {resumen.map((r) => (
          <div
            key={r.estado}
            className={`${tabla.indicador} ${r.estado === 'fallida' ? tabla.grave : ''}`}
          >
            <span className={tabla.indicadorValor}>{numero(r.tareas)}</span>
            <span className={tabla.indicadorEtiqueta}>{r.estado}</span>
          </div>
        ))}
        {resumen.length === 0 && <p className={estilos.vacio}>La cola está vacía.</p>}
      </div>

      <form className={tabla.filtros} method="get" style={{ marginTop: '1.5rem' }}>
        <label className={tabla.filtro}>
          Estado
          <select className={estilos.selector} name="estado" defaultValue={estado}>
            {ESTADOS.map(([valor, texto]) => (
              <option key={valor} value={valor}>
                {texto}
              </option>
            ))}
          </select>
        </label>
        <button className={estilos.botonPrimario} type="submit">
          Ver
        </button>
      </form>

      {tareas.length === 0 ? (
        <p className={estilos.vacio}>No hay tareas en ese estado.</p>
      ) : (
        <div className={tabla.desplazable}>
          <table className={tabla.tabla}>
            <thead>
              <tr>
                <th>Creada</th>
                <th>Tipo</th>
                <th>Estado</th>
                <th className={tabla.derecha}>Intentos</th>
                <th>Próxima</th>
                <th>Último error</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {tareas.map((t) => (
                <tr key={t.id}>
                  <td>{fechaHora(t.created_at)}</td>
                  <td>{t.tipo}</td>
                  <td>{t.estado}</td>
                  <td className={tabla.derecha}>
                    {t.intentos}/{t.max_intentos}
                  </td>
                  <td>{fechaHora(t.proxima_ejecucion)}</td>
                  <td>
                    {t.ultimo_error ?? '—'}
                    <details>
                      <summary className={tabla.tenue}>payload</summary>
                      <pre className={tabla.json}>{JSON.stringify(t.payload, null, 1)}</pre>
                    </details>
                  </td>
                  <td>
                    <AccionesTarea tareaId={t.id} procesando={t.estado === 'procesando'} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
