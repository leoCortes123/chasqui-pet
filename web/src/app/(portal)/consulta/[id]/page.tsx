import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { obtenerConsulta, opciones } from '@/lib/clinico';
import { exigirPermiso, puede } from '@/lib/sesion';
import FormularioConsulta from './formulario';
import Adenda from './adenda';
import estilos from '../../vistas.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Consulta — Chasqui Pet',
  robots: { index: false, follow: false },
};

/**
 * Consulta en el portal: formulario si es borrador, lectura si ya se firmó.
 * Lo firmado no se edita (§8.2.4); se le añaden adendas.
 */
export default async function PaginaConsulta({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const sesion = await exigirPermiso('pacientes.ver', `/consulta/${id}`);

  const consulta = await obtenerConsulta(id);
  if (!consulta) notFound();

  const paciente = consulta.paciente;
  const editable = consulta.estado === 'borrador' && puede(sesion, 'consulta.crear');

  const [mucosas, hidratacion, cc] = await Promise.all([
    opciones('mucosas'),
    opciones('hidratacion'),
    opciones('cc'),
  ]);

  return (
    <>
      <p className={estilos.subtitulo}>
        <Link href={`/pacientes/${paciente.paciente_id}`}>
          ← {paciente.emoji} {paciente.nombre}
        </Link>
      </p>

      <h1 className={estilos.titulo}>
        Consulta del {formatearFecha(consulta.fecha)}{' '}
        <span className={`${estilos.etiqueta} ${estilos[consulta.estado] ?? ''}`}>
          {consulta.estado}
        </span>
      </h1>
      <p className={estilos.subtitulo}>
        {[
          consulta.veterinario,
          consulta.consultorio,
          consulta.turno ? `turno ${consulta.turno}` : null,
          paciente.dueno,
        ]
          .filter(Boolean)
          .join(' · ')}
      </p>

      {paciente.alergias && (
        <p className={estilos.alergias}>⚠️ Alergias: {paciente.alergias}</p>
      )}

      {consulta.medicamentos.length > 0 && (
        <p className={estilos.subtitulo}>
          💉 Despachado en esta consulta:{' '}
          {consulta.medicamentos
            .map((m) => `${m.nombre} ${m.cantidad} ${m.unidad}`)
            .join(', ')}
        </p>
      )}

      {editable ? (
        <FormularioConsulta
          consulta={consulta}
          opciones={{ mucosas, hidratacion, cc }}
          puedeFirmar={puede(sesion, 'consulta.firmar')}
        />
      ) : (
        <Lectura consulta={consulta} />
      )}

      {consulta.adendas.length > 0 && (
        <>
          <h2 className={estilos.titulo} style={{ marginTop: '2rem' }}>
            Adendas
          </h2>
          <ul className={estilos.historia}>
            {consulta.adendas.map((a) => (
              <li key={a.created_at} className={estilos.entrada}>
                <div className={estilos.entradaAutor}>
                  {a.autor} · {formatearMomento(a.created_at)}
                </div>
                <p className={estilos.entradaCampo}>{a.texto}</p>
              </li>
            ))}
          </ul>
        </>
      )}

      {consulta.estado === 'firmada' && puede(sesion, 'consulta.crear') && (
        <Adenda consultaId={consulta.consulta_id} />
      )}
    </>
  );
}

function Lectura({ consulta }: { consulta: NonNullable<Awaited<ReturnType<typeof obtenerConsulta>>> }) {
  const campos: [string, string | null][] = [
    ['Motivo', consulta.motivo_consulta],
    ['Anamnesis', consulta.anamnesis],
    ['Examen físico', consulta.examen_texto],
    ['Diagnóstico presuntivo', consulta.diagnostico_presuntivo],
    ['Diagnóstico definitivo', consulta.diagnostico_definitivo],
    ['Plan de tratamiento', consulta.plan_tratamiento],
    ['Recomendaciones', consulta.recomendaciones],
    ['Remisión externa', consulta.remision_externa],
    [
      'Próxima revisión',
      consulta.proxima_revision ? formatearFecha(consulta.proxima_revision) : null,
    ],
    ['Motivo de anulación', consulta.motivo_anulacion],
  ];

  return (
    <section className={estilos.bloque}>
      {campos
        .filter(([, valor]) => valor)
        .map(([titulo, valor]) => (
          <div key={titulo} className={estilos.grupo} style={{ marginBottom: '1rem' }}>
            <span className={estilos.leyenda}>{titulo}</span>
            <p className={estilos.entradaCampo} style={{ whiteSpace: 'pre-wrap' }}>
              {valor}
            </p>
          </div>
        ))}
    </section>
  );
}

function formatearFecha(iso: string): string {
  const [anio, mes, dia] = iso.split('-');
  return `${dia}/${mes}/${anio}`;
}

/** §12: guardado en UTC, presentado en hora de Bogotá. */
function formatearMomento(iso: string): string {
  return new Date(iso).toLocaleString('es-CO', {
    timeZone: 'America/Bogota',
    dateStyle: 'short',
    timeStyle: 'short',
  });
}
