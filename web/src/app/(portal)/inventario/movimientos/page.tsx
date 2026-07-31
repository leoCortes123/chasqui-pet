import type { Metadata } from 'next';
import Link from 'next/link';
import { consultar } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';
import { fechaHora, numero, pesos, primeroDeMes, hoyBogota } from '@/lib/formato';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Libro de movimientos — Chasqui Pet',
  robots: { index: false, follow: false },
};

interface Movimiento {
  id: string;
  cuando: string;
  tipo: string;
  medicamento: string;
  lote: string;
  cantidad: string;
  unidad: string;
  signo: number;
  valor: string;
  costo: string;
  paciente: string | null;
  turno: string | null;
  usuario: string;
  canal: string;
  motivo: string | null;
}

const TIPOS = [
  ['', 'Todos'],
  ['entrada', 'Entradas'],
  ['salida', 'Salidas'],
  ['ajuste_positivo', 'Ajustes positivos'],
  ['ajuste_negativo', 'Ajustes negativos'],
  ['baja_vencimiento', 'Bajas por vencimiento'],
  ['baja_dano', 'Bajas por daño'],
  ['devolucion', 'Devoluciones'],
] as const;

/**
 * El libro de movimientos (§11.2). Es la tabla tal cual: cada fila una
 * fila real de `movimiento_inventario`, sin agregar nada. De eso se trata
 * un libro, y por eso no se puede editar desde aquí ni desde ningún sitio.
 */
export default async function PaginaMovimientos({
  searchParams,
}: {
  searchParams: Promise<{ desde?: string; hasta?: string; tipo?: string }>;
}) {
  await exigirPermiso('inventario.ver', '/inventario/movimientos');
  const filtros = await searchParams;

  const desde = filtros.desde || primeroDeMes();
  const hasta = filtros.hasta || hoyBogota();
  const tipo = filtros.tipo ?? '';

  const filas = await consultar<Movimiento>(
    'SELECT * FROM libro_movimientos($1, $2, NULL, $3, 500)',
    [desde, hasta, tipo || null],
  );

  return (
    <>
      <p className={tabla.migaja}>
        <Link href="/inventario">← Inventario</Link>
      </p>
      <h1 className={estilos.titulo}>Libro de movimientos</h1>
      <p className={estilos.subtitulo}>
        Sólo se agrega: un error se corrige con un movimiento inverso, nunca editando
        el original.
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
          Tipo
          <select className={estilos.selector} name="tipo" defaultValue={tipo}>
            {TIPOS.map(([valor, texto]) => (
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

      {filas.length === 0 ? (
        <p className={estilos.vacio}>No hay movimientos en ese período.</p>
      ) : (
        <div className={tabla.desplazable}>
          <table className={tabla.tabla}>
            <thead>
              <tr>
                <th>Cuándo</th>
                <th>Tipo</th>
                <th>Medicamento</th>
                <th>Lote</th>
                <th className={tabla.derecha}>Cantidad</th>
                <th className={tabla.derecha}>Valor venta</th>
                <th className={tabla.derecha}>Costo</th>
                <th>Paciente</th>
                <th>Turno</th>
                <th>Quién</th>
                <th>Motivo</th>
              </tr>
            </thead>
            <tbody>
              {filas.map((m) => (
                <tr key={m.id}>
                  <td>{fechaHora(m.cuando)}</td>
                  <td>{m.tipo}</td>
                  <td>{m.medicamento}</td>
                  <td>{m.lote}</td>
                  <td className={tabla.derecha}>
                    {m.signo > 0 ? '+' : '−'}
                    {numero(m.cantidad)} {m.unidad}
                  </td>
                  <td className={tabla.derecha}>{pesos(m.valor)}</td>
                  <td className={tabla.derecha}>{pesos(m.costo)}</td>
                  <td>{m.paciente ?? '—'}</td>
                  <td>{m.turno ?? '—'}</td>
                  <td>
                    {m.usuario}
                    <span className={tabla.tenue}> · {m.canal}</span>
                  </td>
                  <td>{m.motivo ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
