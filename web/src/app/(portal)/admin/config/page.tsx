import type { Metadata } from 'next';
import Link from 'next/link';
import { consultar } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';
import {
  FilaParametro,
  FilaTarifaEditable,
  NuevaTarifa,
  type FilaConfig,
  type FilaTarifa,
} from './formularios';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Configuración — Chasqui Pet',
  robots: { index: false, follow: false },
};

interface Consultorio {
  id: string;
  nombre: string;
  activo: boolean;
  orden: number;
}

/**
 * Configuración operativa (§11.2). Todo lo de aquí son filas de tablas
 * que el sistema lee en caliente: cambiar `timeout_llamado_seg` o el
 * precio de una consulta no exige desplegar nada ni reiniciar el bot.
 */
export default async function PaginaConfig() {
  await exigirPermiso('config.editar', '/admin/config');

  const [parametros, tarifas, consultorios] = await Promise.all([
    consultar<FilaConfig>('SELECT * FROM config_listado()'),
    consultar<FilaTarifa>('SELECT * FROM tarifas_listado()'),
    consultar<Consultorio>(
      'SELECT id, nombre, activo, orden FROM consultorio ORDER BY orden, nombre',
    ),
  ]);

  return (
    <>
      <p className={tabla.migaja}>
        <Link href="/admin">← Administración</Link>
      </p>
      <h1 className={estilos.titulo}>Configuración</h1>
      <p className={estilos.subtitulo}>
        El bot y el portal leen esto en caliente. No hace falta reiniciar nada.
      </p>

      <section>
        <h2 className={estilos.titulo}>Parámetros</h2>
        <div className={tabla.desplazable}>
          <table className={tabla.tabla}>
            <thead>
              <tr>
                <th>Clave</th>
                <th>Para qué sirve</th>
                <th>Valor</th>
              </tr>
            </thead>
            <tbody>
              {parametros.map((p) => (
                <FilaParametro key={p.clave} fila={p} />
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Tarifas</h2>
        <p className={estilos.subtitulo}>
          Lo que el bot ofrece al armar una cuenta. «Valor libre» es lo que se cobra
          por peso o por acuerdo: el bot pregunta cuánto en vez de suponerlo.
        </p>
        <div className={tabla.desplazable}>
          <table className={tabla.tabla}>
            <thead>
              <tr>
                <th>Código</th>
                <th>Servicio</th>
                <th className={tabla.derecha}>Usos</th>
                <th>Nombre, valor y estado</th>
              </tr>
            </thead>
            <tbody>
              {tarifas.map((t) => (
                <FilaTarifaEditable key={t.tarifa_id} fila={t} />
              ))}
            </tbody>
          </table>
        </div>
        <NuevaTarifa />
      </section>

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Consultorios</h2>
        <ul className={estilos.lista}>
          {consultorios.map((c) => (
            <li key={c.id} className={estilos.fila}>
              <span className={estilos.emoji}>🚪</span>
              <span className={estilos.filaTexto}>
                <span className={estilos.filaNombre}>{c.nombre}</span>
                <span className={estilos.filaDetalle}>orden {c.orden}</span>
              </span>
              <span className={`${estilos.etiqueta} ${c.activo ? estilos.firmada : estilos.anulada}`}>
                {c.activo ? 'activo' : 'inactivo'}
              </span>
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}
