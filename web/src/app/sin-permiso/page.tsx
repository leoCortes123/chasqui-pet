import type { Metadata } from 'next';
import Link from 'next/link';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Sin permiso — Chasqui Pet',
  robots: { index: false, follow: false },
};

/**
 * El usuario entró, pero su rol no alcanza para esa vista (§4). Se dice sin
 * rodeos y con a quién acudir: un «403» a secas hace que la gente reintente.
 */
export default function PaginaSinPermiso() {
  return (
    <main style={{ padding: '3rem 1.5rem', maxWidth: '32rem', margin: '0 auto' }}>
      <h1>No tienes permiso para esta pantalla</h1>
      <p>
        Tu usuario existe y la sesión está abierta, pero tu rol no incluye esta
        parte del sistema. Si lo necesitas para trabajar, pídeselo al
        administrador de la clínica.
      </p>
      <p>
        <Link href="/consultas">Volver a consultas</Link>
      </p>
    </main>
  );
}
