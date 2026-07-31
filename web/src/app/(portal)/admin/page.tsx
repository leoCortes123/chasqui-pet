import type { Metadata } from 'next';
import Link from 'next/link';
import { consultarUna } from '@/lib/db';
import { exigirSesion, puede } from '@/lib/sesion';
import { fechaHora, numero } from '@/lib/formato';
import estilos from '../vistas.module.css';
import tabla from '../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Administración — Chasqui Pet',
  robots: { index: false, follow: false },
};

interface Salud {
  hora: string;
  fecha_operativa: string;
  tareas: { pendientes: number; procesando: number; fallidas: number; atraso_seg: number };
  telegram: { ultimo_update: string | null; sin_procesar: number };
  sesiones_activas: number;
  caja_abierta: number;
}

export default async function PaginaAdmin() {
  const sesion = await exigirSesion('/admin');

  const fila = await consultarUna<{ s: Salud }>('SELECT salud_sistema() AS s');
  const s = fila?.s;

  const secciones = [
    {
      href: '/admin/usuarios',
      titulo: 'Usuarios, roles y permisos',
      detalle:
        'Aprovisionar personal por su Telegram, repartir roles y habilitar excepciones individuales.',
      permiso: 'usuarios.gestionar',
    },
    {
      href: '/admin/config',
      titulo: 'Configuración operativa',
      detalle: 'Tiempos de la cola, umbrales de alerta, tarifas y consultorios.',
      permiso: 'config.editar',
    },
    {
      href: '/admin/auditoria',
      titulo: 'Auditoría',
      detalle: 'Quién hizo qué, cuándo y por qué canal. No se puede borrar, tampoco desde aquí.',
      permiso: 'auditoria.ver',
    },
    {
      href: '/admin/tareas',
      titulo: 'Tareas asíncronas',
      detalle: 'Avisos, recibos y alertas que no se pudieron entregar, con opción de reintentar.',
      permiso: 'sistema.operar',
    },
  ].filter((x) => puede(sesion, x.permiso));

  return (
    <>
      <h1 className={estilos.titulo}>Administración</h1>
      <p className={estilos.subtitulo}>
        Lo que no se hace por chat: configuración, personal y el rastro de todo.
      </p>

      {s && (
        <section>
          <h2 className={estilos.titulo}>Salud del sistema</h2>
          <div className={tabla.indicadores}>
            <div className={`${tabla.indicador} ${s.tareas.fallidas > 0 ? tabla.grave : ''}`}>
              <span className={tabla.indicadorValor}>{numero(s.tareas.fallidas)}</span>
              <span className={tabla.indicadorEtiqueta}>Tareas fallidas</span>
            </div>
            <div className={`${tabla.indicador} ${s.tareas.atraso_seg > 120 ? tabla.alerta : ''}`}>
              <span className={tabla.indicadorValor}>{numero(s.tareas.pendientes)}</span>
              <span className={tabla.indicadorEtiqueta}>Pendientes</span>
            </div>
            {/* Una cola pendiente que se atrasa significa que el worker no
                está corriendo, aunque el contenedor diga que sí. */}
            <div className={`${tabla.indicador} ${s.tareas.atraso_seg > 120 ? tabla.grave : ''}`}>
              <span className={tabla.indicadorValor}>{numero(s.tareas.atraso_seg)} s</span>
              <span className={tabla.indicadorEtiqueta}>Atraso de la cola</span>
            </div>
            <div className={tabla.indicador}>
              <span className={tabla.indicadorValor}>{numero(s.sesiones_activas)}</span>
              <span className={tabla.indicadorEtiqueta}>Sesiones del portal</span>
            </div>
            <div className={tabla.indicador}>
              <span className={tabla.indicadorValor}>{numero(s.caja_abierta)}</span>
              <span className={tabla.indicadorEtiqueta}>Cajas abiertas</span>
            </div>
          </div>
          <p className={estilos.subtitulo} style={{ marginTop: '0.75rem' }}>
            Último mensaje de Telegram recibido: {fechaHora(s.telegram.ultimo_update)}.
          </p>
        </section>
      )}

      <section className={tabla.seccion}>
        <div className={tabla.tarjetas}>
          {secciones.map((x) => (
            <Link key={x.href} className={tabla.tarjeta} href={x.href}>
              <span className={tabla.tarjetaTitulo}>{x.titulo}</span>
              <span className={tabla.tarjetaDetalle}>{x.detalle}</span>
            </Link>
          ))}
        </div>
      </section>
    </>
  );
}
