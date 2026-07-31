'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import estilos from './entrar.module.css';

/** Cada cuánto se pregunta a la base si ya aprobaron el ingreso. */
const SONDEO_MS = 2_000;

interface Challenge {
  challenge_id: string;
  codigo: string;
  enlace: string | null;
  expira_at: string;
}

type Estado = 'pidiendo' | 'esperando' | 'entrando' | 'rechazado' | 'expirado' | 'error';

export default function Ingreso({ volver }: { volver: string }) {
  const router = useRouter();
  const [challenge, setChallenge] = useState<Challenge | null>(null);
  const [estado, setEstado] = useState<Estado>('pidiendo');
  const [mensaje, setMensaje] = useState<string | null>(null);
  const [restante, setRestante] = useState<number>(300);
  const pedido = useRef(false);

  const pedirCodigo = useCallback(async () => {
    setEstado('pidiendo');
    setMensaje(null);
    try {
      const r = await fetch('/api/entrar', { method: 'POST' });
      const datos = await r.json();
      if (!datos.ok) {
        setEstado('error');
        setMensaje(datos.mensaje ?? 'No se pudo iniciar el ingreso.');
        return;
      }
      setChallenge(datos);
      setEstado('esperando');
    } catch {
      setEstado('error');
      setMensaje('No hay conexión con el servidor.');
    }
  }, []);

  // Un solo código por carga de página. `useRef` y no `useState` porque en
  // desarrollo React monta dos veces y no queremos dos challenges.
  useEffect(() => {
    if (pedido.current) return;
    pedido.current = true;
    void pedirCodigo();
  }, [pedirCodigo]);

  // Sondeo: mientras no lo aprueben, la respuesta es «pendiente».
  useEffect(() => {
    if (estado !== 'esperando' || !challenge) return;

    let vivo = true;
    const temporizador = setInterval(async () => {
      try {
        const r = await fetch(`/api/entrar/${challenge.challenge_id}`, { method: 'POST' });
        const datos = await r.json();
        if (!vivo) return;

        if (datos.ok) {
          setEstado('entrando');
          clearInterval(temporizador);
          router.replace(volver);
          router.refresh();
          return;
        }

        if (datos.estado === 'rechazado') setEstado('rechazado');
        if (datos.estado === 'expirado') setEstado('expirado');
      } catch {
        /* Un fallo de red suelto no cancela el ingreso: se reintenta solo. */
      }
    }, SONDEO_MS);

    return () => {
      vivo = false;
      clearInterval(temporizador);
    };
  }, [estado, challenge, router, volver]);

  // Cuenta atrás visible: el código dura cinco minutos y hay que saberlo.
  useEffect(() => {
    if (estado !== 'esperando' || !challenge) return;

    const fin = new Date(challenge.expira_at).getTime();
    const tic = setInterval(() => {
      const seg = Math.max(0, Math.round((fin - Date.now()) / 1000));
      setRestante(seg);
      if (seg === 0) setEstado('expirado');
    }, 1000);

    return () => clearInterval(tic);
  }, [estado, challenge]);

  return (
    <main className={estilos.pantalla}>
      <section className={estilos.tarjeta}>
        <h1 className={estilos.titulo}>Chasqui Pet</h1>
        <p className={estilos.subtitulo}>Portal de la clínica</p>

        {estado === 'pidiendo' && <p className={estilos.nota}>Generando el código…</p>}

        {estado === 'esperando' && challenge && (
          <>
            <p className={estilos.instruccion}>
              Abre el bot en Telegram y confirma que este código es el que ves aquí.
            </p>
            <p
              className={estilos.codigo}
              aria-label={`Código ${challenge.codigo.split('').join(' ')}`}
            >
              {challenge.codigo}
            </p>
            {challenge.enlace ? (
              <a
                className={estilos.boton}
                href={challenge.enlace}
                target="_blank"
                rel="noreferrer"
              >
                Abrir Telegram
              </a>
            ) : (
              <p className={estilos.nota}>
                Escríbele <code>/start</code> al bot de la clínica desde tu Telegram.
              </p>
            )}
            <p className={estilos.nota}>
              Esperando tu confirmación… el código vence en {formatear(restante)}.
            </p>
          </>
        )}

        {estado === 'entrando' && <p className={estilos.nota}>Entrando…</p>}

        {estado === 'rechazado' && (
          <>
            <p className={estilos.aviso}>Bloqueaste este intento desde Telegram.</p>
            <button className={estilos.boton} onClick={pedirCodigo}>
              Intentar de nuevo
            </button>
          </>
        )}

        {estado === 'expirado' && (
          <>
            <p className={estilos.aviso}>El código venció.</p>
            <button className={estilos.boton} onClick={pedirCodigo}>
              Pedir otro código
            </button>
          </>
        )}

        {estado === 'error' && (
          <>
            <p className={estilos.aviso}>{mensaje}</p>
            <button className={estilos.boton} onClick={pedirCodigo}>
              Reintentar
            </button>
          </>
        )}

        <p className={estilos.pie}>
          Sólo entra el personal que un administrador haya registrado en Telegram.
        </p>
      </section>
    </main>
  );
}

function formatear(segundos: number): string {
  const m = Math.floor(segundos / 60);
  const s = segundos % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}
