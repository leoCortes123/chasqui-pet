import Link from 'next/link';
import { exigirSesion } from '@/lib/sesion';
import estilos from './portal.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const CLINICA = process.env.NOMBRE_CLINICA ?? 'Chasqui Pet';

/**
 * Marco del portal. Todo lo que cuelga de aquí exige sesión (§11.1): la
 * comprobación está en el layout y no en cada página para que añadir una vista
 * nueva no pueda olvidarse de pedirla.
 */
export default async function LayoutPortal({
  children,
}: {
  children: React.ReactNode;
}) {
  const sesion = await exigirSesion();

  return (
    <div className={estilos.marco}>
      <header className={estilos.cabecera}>
        <Link className={estilos.marca} href="/consultas">
          {CLINICA}
        </Link>
        <nav className={estilos.navegacion}>
          <Link href="/consultas">Consultas</Link>
          <Link href="/pacientes">Pacientes</Link>
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
