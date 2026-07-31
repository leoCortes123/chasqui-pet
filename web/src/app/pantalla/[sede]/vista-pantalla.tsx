'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import type { ConsultorioPantalla, DatosPantalla } from '@/lib/pantalla';
import estilos from './pantalla.module.css';

/** Cada cuánto se consulta la API cuando el SSE no está disponible (§5.5). */
const POLLING_MS = 5_000;
/** Si el SSE no da señales de vida en este tiempo, se asume caído. */
const SSE_SIN_SENAL_MS = 60_000;
/** Cuánto dura el resaltado visual de un consultorio que cambió de turno. */
const DESTACADO_MS = 1_800;

type Fuente = 'sse' | 'polling';

interface Props {
  sedeId: string;
  clinica: string;
  datosIniciales: DatosPantalla;
}

export default function VistaPantalla({
  sedeId,
  clinica,
  datosIniciales,
}: Props) {
  const [datos, setDatos] = useState<DatosPantalla>(datosIniciales);
  const [fuente, setFuente] = useState<Fuente>('sse');
  const [desconectado, setDesconectado] = useState(false);
  const [destacados, setDestacados] = useState<Record<string, number>>({});

  // Turno que tenía cada consultorio en el render anterior, para saber cuál
  // cambió y animar sólo ese.
  const turnosPrevios = useRef<Map<string, string | null>>(
    new Map(datosIniciales.consultorios.map((c) => [c.consultorio, c.turno])),
  );

  useEffect(() => {
    const cambiados: string[] = [];
    for (const c of datos.consultorios) {
      const previo = turnosPrevios.current.get(c.consultorio);
      if (previo !== undefined && previo !== c.turno && c.turno !== null) {
        cambiados.push(c.consultorio);
      }
      turnosPrevios.current.set(c.consultorio, c.turno);
    }
    if (cambiados.length === 0) return;

    const sello = Date.now();
    setDestacados((previos) => {
      const siguiente = { ...previos };
      for (const nombre of cambiados) siguiente[nombre] = sello;
      return siguiente;
    });

    const temporizador = setTimeout(() => {
      setDestacados((previos) => {
        const siguiente: Record<string, number> = {};
        for (const [nombre, valor] of Object.entries(previos)) {
          if (valor !== sello) siguiente[nombre] = valor;
        }
        return siguiente;
      });
    }, DESTACADO_MS);

    return () => clearTimeout(temporizador);
  }, [datos]);

  // --- Transporte: SSE con caída automática a polling ----------------------
  useEffect(() => {
    let vivo = true;
    let sse: EventSource | null = null;
    let polling: ReturnType<typeof setInterval> | null = null;
    let vigilante: ReturnType<typeof setInterval> | null = null;
    let ultimaSenal = Date.now();

    const traer = async (): Promise<void> => {
      try {
        const respuesta = await fetch(`/api/pantalla/${sedeId}`, {
          cache: 'no-store',
        });
        if (!respuesta.ok) throw new Error(`HTTP ${respuesta.status}`);
        const cuerpo = (await respuesta.json()) as DatosPantalla;
        if (!vivo) return;
        setDatos(cuerpo);
        setDesconectado(false);
      } catch {
        if (vivo) setDesconectado(true);
      }
    };

    const iniciarPolling = (): void => {
      if (!vivo || polling) return;
      setFuente('polling');
      void traer();
      polling = setInterval(() => void traer(), POLLING_MS);
    };

    const detenerPolling = (): void => {
      if (polling) {
        clearInterval(polling);
        polling = null;
      }
    };

    const iniciarSse = (): void => {
      if (!vivo) return;
      // EventSource reconecta solo; el polling sólo entra si eso no basta.
      if (typeof EventSource === 'undefined') {
        iniciarPolling();
        return;
      }

      sse = new EventSource(`/api/pantalla/${sedeId}/stream`);

      sse.addEventListener('open', () => {
        ultimaSenal = Date.now();
        if (!vivo) return;
        detenerPolling();
        setFuente('sse');
        setDesconectado(false);
      });

      sse.addEventListener('estado', (evento) => {
        ultimaSenal = Date.now();
        if (!vivo) return;
        try {
          setDatos(JSON.parse((evento as MessageEvent<string>).data));
          detenerPolling();
          setFuente('sse');
          setDesconectado(false);
        } catch {
          /* payload corrupto: se ignora y se espera el siguiente */
        }
      });

      sse.addEventListener('error', () => {
        if (!vivo) return;
        // El navegador reintenta por su cuenta; mientras tanto se sirve por
        // polling para que la pantalla NUNCA se quede congelada.
        iniciarPolling();
      });
    };

    // Vigilante: si el SSE dejó de dar señales (ni datos ni heartbeat) se
    // considera muerto aunque el navegador no haya emitido `error`.
    vigilante = setInterval(() => {
      if (!vivo) return;
      if (Date.now() - ultimaSenal > SSE_SIN_SENAL_MS) iniciarPolling();
    }, POLLING_MS);

    iniciarSse();

    return () => {
      vivo = false;
      sse?.close();
      detenerPolling();
      if (vigilante) clearInterval(vigilante);
    };
  }, [sedeId]);

  const hayAtencion = useMemo(
    () => datos.consultorios.some((c) => c.abierto && c.turno !== null),
    [datos.consultorios],
  );

  return (
    <main className={estilos.pantalla}>
      <header className={estilos.encabezado}>
        <div className={estilos.marca}>
          <h1 className={estilos.clinica}>{clinica}</h1>
          <span className={estilos.sede}>{datos.sede}</span>
        </div>
        <div className={estilos.datos}>
          <span className={estilos.dato}>
            En espera{' '}
            <strong className={estilos.datoValor}>{datos.en_espera}</strong>
          </span>
          <span className={estilos.dato}>
            <strong className={estilos.datoValor}>{datos.actualizado}</strong>
          </span>
        </div>
      </header>

      {hayAtencion ? (
        <section className={estilos.consultorios} aria-live="polite">
          {datos.consultorios.map((consultorio) => (
            <TarjetaConsultorio
              key={consultorio.consultorio}
              consultorio={consultorio}
              destacado={Boolean(destacados[consultorio.consultorio])}
            />
          ))}
        </section>
      ) : (
        <section className={estilos.vacio} aria-live="polite">
          <p className={estilos.vacioMarca}>{clinica}</p>
          <p className={estilos.vacioTexto}>Sin turnos en atención</p>
        </section>
      )}

      <footer className={estilos.siguientes}>
        <span className={estilos.siguientesTitulo}>Siguientes</span>
        {datos.siguientes.length > 0 ? (
          datos.siguientes.map((turno) => (
            <span key={turno} className={estilos.siguienteTurno}>
              {turno}
            </span>
          ))
        ) : (
          <span className={estilos.sinSiguientes}>No hay turnos en espera</span>
        )}
      </footer>

      {desconectado && (
        <p className={estilos.aviso} role="status">
          Reconectando…
        </p>
      )}
      {!desconectado && fuente === 'polling' && (
        <p className={estilos.aviso} role="status">
          Actualización cada 5 s
        </p>
      )}
    </main>
  );
}

function TarjetaConsultorio({
  consultorio,
  destacado,
}: {
  consultorio: ConsultorioPantalla;
  destacado: boolean;
}) {
  const clases = [estilos.consultorio];
  if (!consultorio.abierto) clases.push(estilos.cerrado);
  if (destacado && consultorio.abierto) clases.push(estilos.destacado);

  return (
    <article className={clases.join(' ')}>
      <h2 className={estilos.consultorioNombre}>{consultorio.consultorio}</h2>

      {!consultorio.abierto ? (
        <p className={estilos.etiquetaCerrado}>Cerrado</p>
      ) : consultorio.turno ? (
        <>
          <p className={estilos.turno}>{consultorio.turno}</p>
          <span
            className={`${estilos.estado} ${
              consultorio.estado === 'en_atencion'
                ? estilos.estadoEnAtencion
                : estilos.estadoLlamado
            }`}
          >
            {consultorio.estado === 'en_atencion' ? 'En atención' : 'Llamando'}
          </span>
        </>
      ) : (
        <p className={estilos.libre}>Libre</p>
      )}
    </article>
  );
}
