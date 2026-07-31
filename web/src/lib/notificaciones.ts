import type { Client } from 'pg';
import { crearClienteEscucha } from './db';

/**
 * Multiplexor de `LISTEN pantalla_turnos`.
 *
 * Postgres emite `NOTIFY pantalla_turnos, '<sede_id>'` en cada cambio de la
 * cola. Abrir una conexión `LISTEN` por cada monitor conectado agotaría las
 * conexiones de la base, así que este módulo mantiene UNA sola conexión
 * dedicada para todo el proceso y reparte los avisos entre los suscriptores.
 *
 * La conexión se abre con la primera suscripción y se cierra cuando se va el
 * último suscriptor, así un servidor sin pantallas abiertas no consume nada.
 */

const CANAL = 'pantalla_turnos';
const REINTENTO_MS = 3_000;

type Oyente = (sedeId: string) => void;

interface Hub {
  cliente: Client | null;
  conectando: Promise<void> | null;
  oyentes: Set<Oyente>;
  reintento: NodeJS.Timeout | null;
  cerrado: boolean;
}

// Igual que el pool: sobrevive al hot reload de desarrollo.
const global_ = globalThis as unknown as { __chasquipetHub?: Hub };

function hub(): Hub {
  if (!global_.__chasquipetHub) {
    global_.__chasquipetHub = {
      cliente: null,
      conectando: null,
      oyentes: new Set(),
      reintento: null,
      cerrado: false,
    };
  }
  return global_.__chasquipetHub;
}

function programarReintento(h: Hub): void {
  if (h.reintento || h.oyentes.size === 0) return;
  h.reintento = setTimeout(() => {
    h.reintento = null;
    void asegurarConexion().catch(() => {
      /* el propio asegurarConexion vuelve a programar el reintento */
    });
  }, REINTENTO_MS);
}

async function asegurarConexion(): Promise<void> {
  const h = hub();
  if (h.cliente) return;
  if (h.conectando) return h.conectando;

  h.conectando = (async () => {
    try {
      const cliente = await crearClienteEscucha();

      cliente.on('notification', (msg) => {
        const sedeId = msg.payload?.trim();
        if (!sedeId) return;
        for (const oyente of hub().oyentes) {
          try {
            oyente(sedeId);
          } catch (error) {
            console.error('[notificaciones] oyente falló:', error);
          }
        }
      });

      cliente.on('error', (error) => {
        console.error('[notificaciones] conexión LISTEN caída:', error.message);
        const actual = hub();
        actual.cliente = null;
        cliente.end().catch(() => {});
        programarReintento(actual);
      });

      cliente.on('end', () => {
        const actual = hub();
        if (actual.cliente === cliente) {
          actual.cliente = null;
          programarReintento(actual);
        }
      });

      await cliente.query(`LISTEN ${CANAL}`);
      h.cliente = cliente;
    } catch (error) {
      console.error(
        '[notificaciones] no se pudo abrir LISTEN:',
        error instanceof Error ? error.message : error,
      );
      programarReintento(h);
      throw error;
    } finally {
      h.conectando = null;
    }
  })();

  return h.conectando;
}

function cerrarSiSobra(h: Hub): void {
  if (h.oyentes.size > 0) return;
  if (h.reintento) {
    clearTimeout(h.reintento);
    h.reintento = null;
  }
  const cliente = h.cliente;
  h.cliente = null;
  cliente?.end().catch(() => {});
}

/**
 * Suscribe a los avisos de una sede concreta. Devuelve la función para darse de
 * baja; llamarla es obligatorio cuando el cliente SSE se desconecta.
 *
 * Si la conexión LISTEN no se puede abrir, la suscripción queda igual registrada
 * y se reintenta en segundo plano: el cliente SSE seguirá vivo gracias al
 * heartbeat y, si aun así no llegan datos, cae a polling por su cuenta.
 */
export function suscribirSede(
  sedeId: string,
  alNotificar: () => void,
): () => void {
  const h = hub();

  const oyente: Oyente = (sede) => {
    if (sede === sedeId) alNotificar();
  };

  h.oyentes.add(oyente);
  void asegurarConexion().catch(() => {
    /* ya registrado y reprogramado */
  });

  let dadoDeBaja = false;
  return () => {
    if (dadoDeBaja) return;
    dadoDeBaja = true;
    h.oyentes.delete(oyente);
    cerrarSiSobra(h);
  };
}
