import type { Metadata } from 'next';
import Link from 'next/link';
import {
  agendaDelDia,
  controlesPendientes,
  cuposDelDia,
  desplazarFecha,
  esFecha,
  ETIQUETA_ESTADO,
  fechaLarga,
  hoyBogota,
  tiposDeServicio,
  type Cita,
} from '@/lib/agenda';
import { buscarPacientes } from '@/lib/clinico';
import { exigirPermiso, puede } from '@/lib/sesion';
import { AccionesCita, BotonAgendarControl, FormularioAgendar } from './panel';
import estilos from '../vistas.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Agenda — Chasqui Pet',
  robots: { index: false, follow: false },
};

const ICONO: Record<Cita['estado'], string> = {
  programada: '🕐',
  confirmada: '☑️',
  cumplida: '✅',
  cancelada: '✖️',
  no_asistio: '🚫',
};

/**
 * Agenda del día (Fase B1b).
 *
 * Todo el estado vive en la URL —fecha, búsqueda de mascota, cupo elegido— y
 * no en el cliente: así el día que se está mirando se puede compartir por
 * chat, recargar y volver atrás con el botón del navegador. Es la misma
 * decisión que en el buscador de pacientes.
 *
 * Lo que se ve es exactamente lo que devuelven `agenda_del_dia` y
 * `horarios_disponibles`. Si un cupo no aparece es porque está tomado o
 * bloqueado, y eso lo decide la base, no esta página.
 */
export default async function PaginaAgenda({
  searchParams,
}: {
  searchParams: Promise<{ fecha?: string; q?: string; hora?: string; vet?: string }>;
}) {
  const sesion = await exigirPermiso('agenda.ver', '/agenda');
  const { fecha: fechaParam, q, hora, vet } = await searchParams;

  const hoy = await hoyBogota();
  const fecha = fechaParam && esFecha(fechaParam) ? fechaParam : hoy;
  const puedeGestionar = puede(sesion, 'agenda.gestionar');

  const [agenda, cupos, tipos, controles] = await Promise.all([
    agendaDelDia(sesion.usuario_id, sesion.sede_id, fecha),
    puedeGestionar ? cuposDelDia(sesion.usuario_id, sesion.sede_id, fecha) : null,
    puedeGestionar ? tiposDeServicio() : [],
    controlesPendientes(sesion.usuario_id, sesion.sede_id),
  ]);

  const texto = (q ?? '').trim();
  const pacientes = puedeGestionar && texto ? await buscarPacientes(texto) : [];

  const citas = agenda?.citas ?? [];
  const activas = citas.filter((c) => c.estado === 'programada' || c.estado === 'confirmada');
  const cerradas = citas.filter((c) => c.estado !== 'programada' && c.estado !== 'confirmada');

  /** Conserva la búsqueda al cambiar de día: se está agendando, no navegando. */
  const enlace = (f: string) =>
    `/agenda?fecha=${f}${texto ? `&q=${encodeURIComponent(texto)}` : ''}`;

  return (
    <>
      <h1 className={estilos.titulo}>Agenda</h1>
      <p className={estilos.subtitulo}>
        {fechaLarga(fecha)}
        {fecha === hoy && ' · hoy'}
        {fecha === desplazarFecha(hoy, 1) && ' · mañana'}
        {' · '}
        {citas.length === 0 ? 'sin citas' : `${citas.length} cita(s)`}
      </p>

      <nav className={estilos.acciones} aria-label="Cambiar de día">
        <Link className={estilos.boton} href={enlace(desplazarFecha(fecha, -1))}>
          ◀️ Día anterior
        </Link>
        <Link className={estilos.boton} href={enlace(hoy)}>
          Hoy
        </Link>
        <Link className={estilos.boton} href={enlace(desplazarFecha(fecha, 1))}>
          Día siguiente ▶️
        </Link>
      </nav>

      {citas.length === 0 && (
        <p className={estilos.vacio}>
          Ese día no tiene citas. Se agendan desde aquí, desde el bot o pidiéndoselo
          a Chasqui.
        </p>
      )}

      {activas.length > 0 && (
        <>
          <h2 className={estilos.tituloSeccion}>Por atender</h2>
          <ul className={estilos.lista}>
            {activas.map((c) => (
              <li key={c.cita_id}>
                <FilaCita cita={c} />
                {puedeGestionar && <AccionesCita cita={c} />}
              </li>
            ))}
          </ul>
        </>
      )}

      {cerradas.length > 0 && (
        <>
          <h2 className={`${estilos.tituloSeccion} ${estilos.tituloDespues}`}>
            Cerradas
          </h2>
          <ul className={estilos.lista}>
            {cerradas.map((c) => (
              <li key={c.cita_id}>
                <FilaCita cita={c} />
              </li>
            ))}
          </ul>
        </>
      )}

      {controles && controles.total > 0 && (
        <>
          <h2 className={`${estilos.tituloSeccion} ${estilos.tituloDespues}`}>
            Controles por agendar
          </h2>
          <p className={estilos.subtitulo}>
            Revisiones que anotó el veterinario y todavía no tienen cita
            {controles.vencidos > 0 && ` · ${controles.vencidos} ya vencida(s)`}.
          </p>
          <ul className={estilos.lista}>
            {controles.controles.map((c) => (
              <li key={c.consulta_id}>
                <Link className={estilos.fila} href={`/consulta/${c.consulta_id}`}>
                  <span className={estilos.emoji}>{c.vencido ? '⚠️' : '🔔'}</span>
                  <span className={estilos.filaTexto}>
                    <span className={estilos.filaNombre}>
                      {c.paciente} · {fechaLarga(c.fecha_control)}
                    </span>
                    <span className={estilos.filaDetalle}>
                      {[
                        c.dueno,
                        c.telefono,
                        c.vencido
                          ? `vencido hace ${-c.dias_faltan} día(s)`
                          : `en ${c.dias_faltan} día(s)`,
                        // Lo que no se puede avisar por Telegram hay que
                        // llamarlo: decirlo aquí evita esperar un mensaje
                        // que nunca va a salir (§12).
                        c.avisable ? (c.avisado ? 'ya avisado' : null) : 'sin Telegram: llamar',
                      ]
                        .filter(Boolean)
                        .join(' · ')}
                    </span>
                  </span>
                </Link>
                {puedeGestionar && <BotonAgendarControl control={c} />}
              </li>
            ))}
          </ul>
        </>
      )}

      {puedeGestionar && (
        <>
          <h2 className={`${estilos.tituloSeccion} ${estilos.tituloDespues}`}>
            Agendar una cita
          </h2>

          {cupos && cupos.slots.length > 0 && (
            <>
              <p className={estilos.subtitulo}>
                Cupos libres del {fechaLarga(fecha)} ({cupos.duracion_min} min cada uno):
              </p>
              <nav className={estilos.acciones} aria-label="Cupos libres">
                {cupos.slots.slice(0, 24).map((s) => (
                  <Link
                    key={`${s.inicio}-${s.veterinario_id}`}
                    className={estilos.boton}
                    href={`${enlace(fecha)}&hora=${s.hora}${
                      s.veterinario_id ? `&vet=${s.veterinario_id}` : ''
                    }`}
                  >
                    {s.hora}
                    {s.veterinario ? ` · ${s.veterinario.split(' ')[0]}` : ''}
                  </Link>
                ))}
              </nav>
            </>
          )}

          <form className={estilos.buscador} method="get">
            <input type="hidden" name="fecha" value={fecha} />
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
            <FormularioAgendar
              fecha={fecha}
              pacientes={pacientes}
              tipos={tipos}
              cupos={cupos?.slots ?? []}
              horaElegida={hora ?? null}
              veterinarioElegido={vet ?? null}
            />
          )}
        </>
      )}
    </>
  );
}

function FilaCita({ cita }: { cita: Cita }) {
  const detalle = [
    cita.dueno,
    cita.tipo_nombre,
    cita.veterinario,
    cita.turno ? `turno ${cita.turno}` : null,
    cita.motivo_cancelacion,
  ]
    .filter(Boolean)
    .join(' · ');

  const contenido = (
    <>
      <span className={estilos.emoji}>{ICONO[cita.estado]}</span>
      <span className={estilos.filaTexto}>
        <span className={estilos.filaNombre}>
          {cita.hora} · {cita.paciente?.nombre ?? 'sin mascota'}
        </span>
        <span className={estilos.filaDetalle}>{detalle}</span>
      </span>
      <span className={estilos.etiqueta}>{ETIQUETA_ESTADO[cita.estado]}</span>
    </>
  );

  // La ficha de la mascota es el destino útil desde una cita; una cita sin
  // mascota (no debería existir, pero el modelo lo permite) no lleva a ningún
  // lado y no se pinta como enlace.
  return cita.paciente_id ? (
    <Link className={estilos.fila} href={`/pacientes/${cita.paciente_id}`}>
      {contenido}
    </Link>
  ) : (
    <span className={estilos.fila}>{contenido}</span>
  );
}
