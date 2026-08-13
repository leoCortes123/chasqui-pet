import type { Metadata } from 'next';
import Link from 'next/link';
import { desplazarFecha, hoyBogota } from '@/lib/agenda';
import { buscarPacientes } from '@/lib/clinico';
import {
  ETIQUETA_TIPO,
  remisionesCerradas,
  remisionesPendientes,
  type Remision,
} from '@/lib/remisiones';
import { exigirPermiso, puede } from '@/lib/sesion';
import { AccionesRemision, FormularioRemision } from './panel';
import estilos from '../vistas.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Remisiones — Chasqui Pet',
  robots: { index: false, follow: false },
};

/**
 * Remisiones externas (Fase B3).
 *
 * Lo primero de la página es lo que hay que perseguir: lo que se mandó y no
 * ha vuelto, con las vencidas arriba. Lo cerrado va después, para consultar.
 *
 * La búsqueda de la mascota vive en la URL, igual que en `/pacientes` y
 * `/agenda`: así el estado de la página se comparte y se recarga sin
 * repetir el formulario.
 */
export default async function PaginaRemisiones({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const sesion = await exigirPermiso('remision.ver', '/remisiones');
  const { q } = await searchParams;

  const puedeGestionar = puede(sesion, 'remision.gestionar');
  const texto = (q ?? '').trim();

  const [pendientes, cerradas, hoy] = await Promise.all([
    remisionesPendientes(sesion.usuario_id, sesion.sede_id),
    remisionesCerradas(sesion.sede_id),
    hoyBogota(),
  ]);

  const pacientes = puedeGestionar && texto ? await buscarPacientes(texto) : [];

  const lista = pendientes?.remisiones ?? [];
  const vencidas = lista.filter((r) => r.vencida);
  const enPlazo = lista.filter((r) => !r.vencida);

  return (
    <>
      <h1 className={estilos.titulo}>Remisiones</h1>
      <p className={estilos.subtitulo}>
        Exámenes e interconsultas enviados afuera
        {pendientes ? ` · ${pendientes.total} sin resultado` : ''}
        {pendientes && pendientes.vencidas > 0 && ` · ${pendientes.vencidas} vencida(s)`}.
      </p>

      {lista.length === 0 && (
        <p className={estilos.vacio}>
          No hay nada pendiente de volver. Las remisiones se registran aquí, desde el
          bot o pidiéndoselo a Chasqui.
        </p>
      )}

      {vencidas.length > 0 && (
        <>
          <h2 className={estilos.tituloSeccion}>Vencidas</h2>
          <Lista remisiones={vencidas} gestionar={puedeGestionar} />
        </>
      )}

      {enPlazo.length > 0 && (
        <>
          <h2 className={`${estilos.tituloSeccion} ${vencidas.length > 0 ? estilos.tituloDespues : ''}`}>
            Dentro de plazo
          </h2>
          <Lista remisiones={enPlazo} gestionar={puedeGestionar} />
        </>
      )}

      {puedeGestionar && (
        <>
          <h2 className={`${estilos.tituloSeccion} ${estilos.tituloDespues}`}>
            Registrar una remisión
          </h2>

          <form className={estilos.buscador} method="get">
            <input
              className={estilos.campo}
              type="search"
              name="q"
              defaultValue={texto}
              placeholder="Busca la mascota: Firulais, Gómez, 3001234567…"
            />
            <button className={estilos.botonPrimario} type="submit">
              Buscar
            </button>
          </form>

          {texto && pacientes.length === 0 && (
            <p className={estilos.vacio}>Sin resultados para «{texto}».</p>
          )}

          {pacientes.length > 0 && (
            <FormularioRemision
              pacientes={pacientes}
              fechaEsperada={desplazarFecha(hoy, 5)}
            />
          )}
        </>
      )}

      {cerradas.length > 0 && (
        <>
          <h2 className={`${estilos.tituloSeccion} ${estilos.tituloDespues}`}>
            Cerradas hace poco
          </h2>
          <Lista remisiones={cerradas} gestionar={false} />
        </>
      )}
    </>
  );
}

function Lista({
  remisiones,
  gestionar,
}: {
  remisiones: Remision[];
  gestionar: boolean;
}) {
  return (
    <ul className={estilos.lista}>
      {remisiones.map((r) => (
        <li key={r.remision_id}>
          <Link className={estilos.fila} href={`/pacientes/${r.paciente_id}`}>
            <span className={estilos.emoji}>
              {r.estado === 'recibida' ? '✅' : r.estado === 'anulada' ? '✖️' : r.vencida ? '⚠️' : '⏳'}
            </span>
            <span className={estilos.filaTexto}>
              <span className={estilos.filaNombre}>
                {r.paciente} · {r.destino}
              </span>
              <span className={estilos.filaDetalle}>
                {[
                  r.examenes,
                  ETIQUETA_TIPO[r.tipo],
                  r.estado === 'pendiente'
                    ? r.vencida
                      ? `esperada el ${r.fecha_esperada} · vencida`
                      : `esperada el ${r.fecha_esperada}`
                    : null,
                  r.motivo_anulacion,
                  r.resultados.length > 0
                    ? `${r.resultados.length} resultado(s)`
                    : null,
                  // Sin canal no hay aviso automático: hay que llamar (§12).
                  r.estado === 'recibida' && !r.avisado ? 'avisar al dueño' : null,
                ]
                  .filter(Boolean)
                  .join(' · ')}
              </span>
            </span>
            <span className={estilos.etiqueta}>{r.estado}</span>
          </Link>

          {r.resultados.length > 0 && (
            <ul className={estilos.historia}>
              {r.resultados.map((x) => (
                <li key={x.resultado_id} className={estilos.entrada}>
                  <span className={estilos.entradaFecha}>{x.cargado_at}</span>
                  {x.cargado_por && (
                    <span className={estilos.entradaAutor}> · {x.cargado_por}</span>
                  )}
                  {x.texto && <p>{x.texto}</p>}
                  {x.tiene_adjunto && (
                    <p className={estilos.entradaCampo}>
                      {x.adjunto_url ? (
                        <a href={x.adjunto_url} rel="noreferrer noopener" target="_blank">
                          Ver el archivo
                        </a>
                      ) : (
                        'Archivo adjunto en el chat de Telegram'
                      )}
                    </p>
                  )}
                </li>
              ))}
            </ul>
          )}

          {gestionar && <AccionesRemision remision={r} />}
        </li>
      ))}
    </ul>
  );
}
