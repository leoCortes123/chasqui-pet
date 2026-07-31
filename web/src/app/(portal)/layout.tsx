import Link from 'next/link';
import { exigirSesion, puede } from '@/lib/sesion';
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
 */
export default async function LayoutPortal({
  children,
}: {
  children: React.ReactNode;
}) {
  const sesion = await exigirSesion();

  const enlaces: { href: string; texto: string }[] = [{ href: '/', texto: 'Panel' }];

  if (puede(sesion, 'pacientes.ver')) {
    enlaces.push({ href: '/consultas', texto: 'Consultas' });
    enlaces.push({ href: '/pacientes', texto: 'Pacientes' });
  }
  if (puede(sesion, 'inventario.ver')) {
    enlaces.push({ href: '/inventario', texto: 'Inventario' });
  }
  if (puede(sesion, 'proveedores.ver')) {
    enlaces.push({ href: '/compras', texto: 'Compras' });
  }
  if (puede(sesion, 'reportes.operativos') || puede(sesion, 'reportes.financieros')) {
    enlaces.push({ href: '/reportes', texto: 'Reportes' });
  }
  if (
    puede(sesion, 'usuarios.gestionar') ||
    puede(sesion, 'config.editar') ||
    puede(sesion, 'auditoria.ver') ||
    puede(sesion, 'sistema.operar')
  ) {
    enlaces.push({ href: '/admin', texto: 'Administración' });
  }

  return (
    <div className={estilos.marco}>
      <header className={estilos.cabecera}>
        <Link className={estilos.marca} href="/">
          {CLINICA}
        </Link>
        <nav className={estilos.navegacion}>
          {enlaces.map((e) => (
            <Link key={e.href} href={e.href}>
              {e.texto}
            </Link>
          ))}
        </nav>
        <div className={estilos.usuario}>
          <span>{sesion.nombre}</span>
          <form action="/salir" method="post">
            <button className={estilos.salir} type="submit">
              Salir
            </button>
          </form>
        </div>
      </header>
      <main className={estilos.contenido}>{children}</main>
    </div>
  );
}
