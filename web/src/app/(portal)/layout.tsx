import Link from 'next/link';
import { exigirSesion, puede } from '@/lib/sesion';
import { NavegacionEscritorio, NavegacionMovil, type Enlace } from './navegacion';
import estilos from './portal.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const CLINICA = process.env.NOMBRE_CLINICA ?? 'Chasqui Pet';

/**
 * Marco del portal. Todo lo que cuelga de aquí exige sesión (§11.1): la
 * comprobación está en el layout y no en cada página para que añadir una vista
 * nueva no pueda olvidarse de pedirla.
 *
 * La navegación se arma con los permisos reales de la sesión, igual que el
 * menú del bot (§4): un veterinario no ve «Compras» ni «Administración».
 * Es interfaz, no seguridad —cada página vuelve a exigir su permiso— pero
 * enseñar puertas cerradas es una forma barata de hacer perder el tiempo.
 *
 * El orden de la lista importa: los cuatro primeros destinos son los que caben
 * en la barra inferior del celular, así que van de más usado a menos.
 */
export default async function LayoutPortal({
  children,
}: {
  children: React.ReactNode;
}) {
  const sesion = await exigirSesion();

  const enlaces: Enlace[] = [{ href: '/', texto: 'Panel', icono: '🏠' }];

  if (puede(sesion, 'agenda.ver')) {
    enlaces.push({ href: '/agenda', texto: 'Agenda', icono: '📅' });
  }
  if (puede(sesion, 'pacientes.ver')) {
    enlaces.push({ href: '/consultas', texto: 'Consultas', icono: '📋' });
    enlaces.push({ href: '/pacientes', texto: 'Pacientes', icono: '🐾' });
  }
  if (puede(sesion, 'remision.ver')) {
    enlaces.push({ href: '/remisiones', texto: 'Remisiones', icono: '🏥' });
  }
  if (puede(sesion, 'inventario.ver')) {
    enlaces.push({ href: '/inventario', texto: 'Inventario', icono: '📦' });
  }
  if (puede(sesion, 'proveedores.ver')) {
    enlaces.push({ href: '/compras', texto: 'Compras', icono: '🚚' });
  }
  if (puede(sesion, 'reportes.operativos') || puede(sesion, 'reportes.financieros')) {
    enlaces.push({ href: '/reportes', texto: 'Reportes', icono: '📊' });
  }
  if (
    puede(sesion, 'usuarios.gestionar') ||
    puede(sesion, 'config.editar') ||
    puede(sesion, 'auditoria.ver') ||
    puede(sesion, 'sistema.operar')
  ) {
    enlaces.push({ href: '/admin', texto: 'Administración', icono: '⚙️' });
  }

  return (
    <div className={estilos.marco}>
      {/* Primer elemento enfocable: saltarse la navegación con el teclado. */}
      <a className="saltar" href="#contenido">
        Saltar al contenido
      </a>

      <header className={estilos.cabecera}>
        <Link className={estilos.marca} href="/">
          {CLINICA}
        </Link>

        <NavegacionEscritorio enlaces={enlaces} />

        <div className={estilos.usuario}>
          <span className={estilos.nombre}>{sesion.nombre}</span>
          <form action="/salir" method="post">
            <button className={estilos.salir} type="submit">
              Salir
            </button>
          </form>
        </div>
      </header>

      <main className={estilos.contenido} id="contenido" tabIndex={-1}>
        {children}
      </main>

      <NavegacionMovil enlaces={enlaces} />
    </div>
  );
}
