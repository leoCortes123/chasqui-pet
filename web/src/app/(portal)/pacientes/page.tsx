import type { Metadata } from 'next';
import Link from 'next/link';
import { buscarPacientes } from '@/lib/clinico';
import { exigirPermiso } from '@/lib/sesion';
import estilos from '../vistas.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Pacientes — Chasqui Pet',
  robots: { index: false, follow: false },
};

const EMOJI: Record<string, string> = {
  perro: '🐕',
  gato: '🐈',
  ave: '🦜',
  conejo: '🐇',
  roedor: '🐹',
  reptil: '🦎',
  equino: '🐴',
};

/**
 * Buscador de pacientes. Es un GET con la búsqueda en la URL a propósito: así
 * el resultado se puede compartir por chat y recargar sin repetir el formulario.
 */
export default async function PaginaPacientes({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  await exigirPermiso('pacientes.ver', '/pacientes');
  const { q } = await searchParams;
  const texto = (q ?? '').trim();
  const resultados = texto ? await buscarPacientes(texto) : [];

  return (
    <>
      <h1 className={estilos.titulo}>Pacientes</h1>
      <p className={estilos.subtitulo}>
        Busca por nombre de la mascota, del dueño o por teléfono.
      </p>

      <form className={estilos.buscador} method="get">
        <input
          className={estilos.campo}
          type="search"
          name="q"
          defaultValue={texto}
          placeholder="Firulais, Gómez, 3001234567…"
          autoFocus
        />
        <button className={estilos.botonPrimario} type="submit">
          Buscar
        </button>
      </form>

      {texto && resultados.length === 0 && (
        <p className={estilos.vacio}>
          No hay ningún paciente parecido a «{texto}». Los pacientes nuevos se
          registran desde el bot, en el momento de atenderlos.
        </p>
      )}

      <ul className={estilos.lista}>
        {resultados.map((p) => (
          <li key={p.paciente_id}>
            <Link className={estilos.fila} href={`/pacientes/${p.paciente_id}`}>
              <span className={estilos.emoji}>{EMOJI[p.especie] ?? '🐾'}</span>
              <span className={estilos.filaTexto}>
                <span className={estilos.filaNombre}>{p.nombre}</span>
                <span className={estilos.filaDetalle}>
                  {[
                    p.dueno ?? 'Sin dueño registrado',
                    p.telefono,
                    p.ultima_consulta
                      ? `última consulta ${formatearFecha(p.ultima_consulta)}`
                      : 'sin consultas',
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </span>
              </span>
            </Link>
          </li>
        ))}
      </ul>
    </>
  );
}

/** §12: se almacena en ISO, se presenta en formato colombiano. */
function formatearFecha(iso: string): string {
  const [anio, mes, dia] = iso.split('-');
  return `${dia}/${mes}/${anio}`;
}
