import type { Metadata } from 'next';
import Link from 'next/link';
import { consultasRecientes } from '@/lib/clinico';
import { exigirPermiso } from '@/lib/sesion';
import estilos from '../vistas.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Consultas — Chasqui Pet',
  robots: { index: false, follow: false },
};

/**
 * Bandeja de consultas. Primero los borradores propios, que son los que hay
 * que terminar; después lo de hoy, para consultar.
 */
export default async function PaginaConsultas() {
  const sesion = await exigirPermiso('pacientes.ver', '/consultas');
  const consultas = await consultasRecientes(sesion.usuario_id);

  const borradores = consultas.filter((c) => c.estado === 'borrador');
  const resto = consultas.filter((c) => c.estado !== 'borrador');

  return (
    <>
      <h1 className={estilos.titulo}>Consultas</h1>
      <p className={estilos.subtitulo}>
        Los borradores no son registro clínico hasta firmarlos.
      </p>

      {consultas.length === 0 && (
        <p className={estilos.vacio}>
          Hoy no hay consultas todavía. Se abren desde el bot, al atender un turno,
          o desde la ficha de un paciente.
        </p>
      )}

      {borradores.length > 0 && (
        <>
          <h2 className={estilos.tituloSeccion}>Sin firmar</h2>
          <Lista consultas={borradores} />
        </>
      )}

      {resto.length > 0 && (
        <>
          <h2 className={`${estilos.tituloSeccion} ${estilos.tituloDespues}`}>Hoy</h2>
          <Lista consultas={resto} />
        </>
      )}
    </>
  );
}

function Lista({
  consultas,
}: {
  consultas: Awaited<ReturnType<typeof consultasRecientes>>;
}) {
  return (
    <ul className={estilos.lista}>
      {consultas.map((c) => (
        <li key={c.consulta_id}>
          <Link className={estilos.fila} href={`/consulta/${c.consulta_id}`}>
            <span className={estilos.emoji}>{c.emoji}</span>
            <span className={estilos.filaTexto}>
              <span className={estilos.filaNombre}>{c.paciente}</span>
              <span className={estilos.filaDetalle}>
                {[c.dueno, c.turno, c.veterinario, c.actualizada]
                  .filter(Boolean)
                  .join(' · ')}
              </span>
            </span>
            <span className={`${estilos.etiqueta} ${estilos[c.estado] ?? ''}`}>
              {c.estado}
            </span>
          </Link>
        </li>
      ))}
    </ul>
  );
}
