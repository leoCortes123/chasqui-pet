import type { Metadata } from 'next';
import Link from 'next/link';
import { consultar } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';
import { fechaHora, primeroDeMes, hoyBogota } from '@/lib/formato';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Auditoría — Chasqui Pet',
  robots: { index: false, follow: false },
};

interface Evento {
  id: string;
  cuando: string;
  entidad: string;
  entidad_id: string | null;
  accion: string;
  usuario: string;
  canal: string;
  detalle: string | null;
  antes: unknown;
  despues: unknown;
}

interface Entidad {
  entidad: string;
  eventos: string;
}

/**
 * Auditoría (§2.2.8). La aplicación no puede editar ni borrar esta tabla
 * —el `REVOKE` está en `090_grants.sql`—, así que esta pantalla es de
 * lectura y no tiene ni un botón que escriba. Una auditoría que se puede
 * corregir desde el portal no sirve de nada.
 */
export default async function PaginaAuditoria({
  searchParams,
}: {
  searchParams: Promise<{ desde?: string; hasta?: string; entidad?: string }>;
}) {
  await exigirPermiso('auditoria.ver', '/admin/auditoria');
  const filtros = await searchParams;

  const desde = filtros.desde || primeroDeMes();
  const hasta = filtros.hasta || hoyBogota();
  const entidad = filtros.entidad ?? '';

  const [eventos, entidades] = await Promise.all([
    consultar<Evento>('SELECT * FROM auditoria_listado($1, $2, $3, NULL, 300)', [
      desde,
      hasta,
      entidad || null,
    ]),
    consultar<Entidad>('SELECT * FROM auditoria_entidades()'),
  ]);

  return (
    <>
      <p className={tabla.migaja}>
        <Link href="/admin">← Administración</Link>
      </p>
      <h1 className={estilos.titulo}>Auditoría</h1>
      <p className={estilos.subtitulo}>
        Sólo lectura, aquí y en todas partes: esta tabla no admite <code>UPDATE</code>{' '}
        ni <code>DELETE</code> ni siquiera para la aplicación.
      </p>

      <form className={tabla.filtros} method="get">
        <label className={tabla.filtro}>
          Desde
          <input className={estilos.campo} type="date" name="desde" defaultValue={desde} />
        </label>
        <label className={tabla.filtro}>
          Hasta
          <input className={estilos.campo} type="date" name="hasta" defaultValue={hasta} />
        </label>
        <label className={tabla.filtro}>
          Entidad
          <select className={estilos.selector} name="entidad" defaultValue={entidad}>
            <option value="">Todas</option>
            {entidades.map((e) => (
              <option key={e.entidad} value={e.entidad}>
                {e.entidad} ({e.eventos})
              </option>
            ))}
          </select>
        </label>
        <button className={estilos.botonPrimario} type="submit">
          Ver
        </button>
      </form>

      {eventos.length === 0 ? (
        <p className={estilos.vacio}>No hay eventos en ese período.</p>
      ) : (
        <div className={tabla.desplazable}>
          <table className={tabla.tabla}>
            <thead>
              <tr>
                <th>Cuándo</th>
                <th>Quién</th>
                <th>Canal</th>
                <th>Entidad</th>
                <th>Acción</th>
                <th>Detalle</th>
              </tr>
            </thead>
            <tbody>
              {eventos.map((e) => (
                <tr key={e.id}>
                  <td>{fechaHora(e.cuando)}</td>
                  <td>{e.usuario}</td>
                  <td>{e.canal}</td>
                  <td>
                    {e.entidad}
                    <span className={tabla.tenue}> {e.entidad_id?.slice(0, 8)}</span>
                  </td>
                  <td>{e.accion}</td>
                  <td>
                    {e.detalle && <div>{e.detalle}</div>}
                    {Boolean(e.antes || e.despues) && (
                      <details>
                        <summary className={tabla.tenue}>datos</summary>
                        <pre className={tabla.json}>
                          {JSON.stringify({ antes: e.antes, despues: e.despues }, null, 1)}
                        </pre>
                      </details>
                    )}
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
