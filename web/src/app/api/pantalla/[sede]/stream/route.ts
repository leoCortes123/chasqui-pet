import { buscarSedeActiva, obtenerPantalla } from '@/lib/pantalla';
import { suscribirSede } from '@/lib/notificaciones';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const revalidate = 0;

/** Latido para que proxies y navegadores no den la conexión por muerta. */
const HEARTBEAT_MS = 20_000;

/**
 * Server-Sent Events del estado de la pantalla.
 *
 * - Al conectar emite el estado actual (evento `estado`), para que el cliente
 *   no tenga que esperar al primer cambio.
 * - Luego reemite en cada `NOTIFY pantalla_turnos` cuya carga sea esta sede.
 * - Cada 20 s manda un comentario `: latido` como heartbeat.
 * - Al desconectarse el cliente cancela la suscripción y los temporizadores.
 */
export async function GET(
  peticion: Request,
  { params }: { params: Promise<{ sede: string }> },
): Promise<Response> {
  const { sede } = await params;

  const sedeActiva = await buscarSedeActiva(sede).catch(() => null);
  if (!sedeActiva) {
    return new Response('La sede no existe o no está activa.', {
      status: 404,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }

  const codificador = new TextEncoder();

  const flujo = new ReadableStream<Uint8Array>({
    start(controlador) {
      let cerrado = false;
      let enviando = false;
      let pendiente = false;

      const escribir = (texto: string): void => {
        if (cerrado) return;
        try {
          controlador.enqueue(codificador.encode(texto));
        } catch {
          cerrado = true;
        }
      };

      const emitirEstado = async (): Promise<void> => {
        // Serializa los envíos: varias NOTIFY seguidas no deben lanzar
        // consultas en paralelo ni entregar estados desordenados.
        if (enviando) {
          pendiente = true;
          return;
        }
        enviando = true;
        try {
          do {
            pendiente = false;
            const datos = await obtenerPantalla(sede);
            if (cerrado) return;
            if (datos) {
              escribir(`event: estado\ndata: ${JSON.stringify(datos)}\n\n`);
            }
          } while (pendiente && !cerrado);
        } catch (error) {
          console.error('[sse] no se pudo leer la pantalla:', error);
          escribir('event: error\ndata: {"error":"consulta_fallida"}\n\n');
        } finally {
          enviando = false;
        }
      };

      // Sugerencia de reconexión al navegador y estado inicial.
      escribir('retry: 3000\n\n');
      void emitirEstado();

      const cancelarSuscripcion = suscribirSede(sede, () => {
        void emitirEstado();
      });

      const latido = setInterval(() => {
        escribir(`: latido ${Date.now()}\n\n`);
      }, HEARTBEAT_MS);

      const limpiar = (): void => {
        if (cerrado) return;
        cerrado = true;
        clearInterval(latido);
        cancelarSuscripcion();
        try {
          controlador.close();
        } catch {
          /* ya estaba cerrado */
        }
      };

      peticion.signal.addEventListener('abort', limpiar, { once: true });
    },
  });

  return new Response(flujo, {
    status: 200,
    headers: {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-store, no-transform',
      Connection: 'keep-alive',
      // Nginx bufferiza por defecto y eso congela el SSE.
      'X-Accel-Buffering': 'no',
    },
  });
}
