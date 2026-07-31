import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { consultarUna } from '@/lib/db';
import { obtenerHistoria, obtenerPaciente } from '@/lib/clinico';
import { exigirPermiso, puede } from '@/lib/sesion';
import estilos from '../../vistas.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Paciente — Chasqui Pet',
  robots: { index: false, follow: false },
};

/**
 * Ficha del paciente e historia clínica en línea de tiempo (§11.2).
 * Sólo aparece lo firmado: un borrador ajeno a medio escribir no es historia.
 */
export default async function PaginaPaciente({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const sesion = await exigirPermiso('pacientes.ver', `/pacientes/${id}`);

  const paciente = await obtenerPaciente(id);
  if (!paciente) notFound();

  const historia = await obtenerHistoria(id);

  /**
   * Abre la consulta y salta a ella. Es una acción de servidor y no un enlace
   * porque escribe: un GET que crea una consulta la duplicaría cada vez que
   * alguien recargue o el navegador precargue el enlace.
   */
  async function abrirConsulta() {
    'use server';
    const fila = await consultarUna<{ r: { ok: boolean; consulta?: { consulta_id: string } } }>(
      'SELECT abrir_consulta($1, $2, NULL, $3) AS r',
      [sesion.usuario_id, id, 'web'],
    );
    const consultaId = fila?.r?.consulta?.consulta_id;
    if (consultaId) redirect(`/consulta/${consultaId}`);
    redirect(`/pacientes/${id}?error=no-se-pudo-abrir`);
  }

  return (
    <>
      <section className={estilos.ficha}>
        <h1 className={estilos.fichaNombre}>
          {paciente.emoji} {paciente.nombre}
        </h1>
        <p className={estilos.datos}>
          {[
            paciente.especie_nombre,
            paciente.raza,
            paciente.sexo === 'macho'
              ? 'Macho'
              : paciente.sexo === 'hembra'
                ? 'Hembra'
                : null,
            paciente.edad,
            paciente.peso_kg ? `${paciente.peso_kg} kg` : null,
            paciente.esterilizado === true ? 'Esterilizado' : null,
          ]
            .filter(Boolean)
            .map((dato) => (
              <span key={String(dato)}>{dato}</span>
            ))}
        </p>
        <p className={estilos.datos}>
          <span>👤 {paciente.dueno ?? 'Sin dueño registrado'}</span>
          {paciente.telefono && <span>📞 {paciente.telefono}</span>}
        </p>

        {paciente.alergias && (
          <p className={estilos.alergias}>⚠️ Alergias: {paciente.alergias}</p>
        )}

        {paciente.estado === 'fallecido' && (
          <p className={estilos.datos}>🕯️ Paciente fallecido.</p>
        )}

        {puede(sesion, 'consulta.crear') && paciente.estado === 'activo' && (
          <form action={abrirConsulta} style={{ marginTop: '1rem' }}>
            <button className={estilos.botonPrimario} type="submit">
              Abrir consulta
            </button>
          </form>
        )}
      </section>

      <h2 className={estilos.titulo}>Historia clínica</h2>
      <p className={estilos.subtitulo}>
        {historia.length === 0
          ? 'Todavía no tiene consultas firmadas.'
          : `${historia.length} consulta(s) firmada(s).`}
      </p>

      <ul className={estilos.historia}>
        {historia.map((linea) => (
          <li key={linea.consulta_id} className={estilos.entrada}>
            <div>
              <span className={estilos.entradaFecha}>{formatearFecha(linea.fecha)}</span>{' '}
              <span className={estilos.entradaAutor}>{linea.veterinario ?? '—'}</span>
            </div>
            {linea.motivo && <p className={estilos.entradaCampo}>📝 {linea.motivo}</p>}
            {linea.examen && <p className={estilos.entradaCampo}>🩺 {linea.examen}</p>}
            {linea.diagnostico && (
              <p className={estilos.entradaCampo}>🔬 {linea.diagnostico}</p>
            )}
            {linea.plan && <p className={estilos.entradaCampo}>💊 {linea.plan}</p>}
            {linea.medicamentos && (
              <p className={estilos.entradaCampo}>💉 {linea.medicamentos}</p>
            )}
            <p className={estilos.entradaCampo}>
              <Link href={`/consulta/${linea.consulta_id}`}>Ver la consulta completa</Link>
            </p>
          </li>
        ))}
      </ul>
    </>
  );
}

function formatearFecha(iso: string): string {
  const [anio, mes, dia] = iso.split('-');
  return `${dia}/${mes}/${anio}`;
}
