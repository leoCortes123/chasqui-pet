// ---------------------------------------------------------------------------
// Cliente mínimo de la Bot API de Telegram.
//
// Sin librerías: `fetch` nativo de Node 22 basta. El worker solo necesita
// mandar y editar mensajes; los updates entrantes los recibe n8n por webhook.
//
// Reglas de error (§2.2 — a prueba de fallas):
//   - 429  → Telegram nos frena. Respetamos `parameters.retry_after`, esperamos
//            y reintentamos UNA vez. Si vuelve a fallar, se lanza y la cola
//            aplica su propio backoff exponencial (fallar_tarea).
//   - 403  → el usuario bloqueó el bot o nunca inició conversación. Esto NO se
//            arregla reintentando: sería quemar los 5 intentos para nada. Se
//            devuelve {ok:false, motivo:'bloqueado'} y el manejador completa
//            la tarea dejando constancia en el resultado.
//   - resto → se lanza un TelegramError y la tarea se reintenta.
// ---------------------------------------------------------------------------

import { log } from './log.js';

const TOKEN = process.env.TELEGRAM_BOT_TOKEN || '';
const BASE = `https://api.telegram.org/bot${TOKEN}`;
const TIMEOUT_MS = Number(process.env.TELEGRAM_TIMEOUT_MS || 15000);

export class TelegramError extends Error {
  constructor(mensaje, { codigo = null, metodo = null } = {}) {
    super(mensaje);
    this.name = 'TelegramError';
    this.codigo = codigo;
    this.metodo = metodo;
  }
}

/**
 * Escapa los caracteres que rompen el `parse_mode: HTML` de Telegram.
 * Se aplica SIEMPRE a los valores interpolados (códigos, nombres, errores),
 * nunca a las etiquetas que ponemos nosotros a propósito.
 */
export function esc(valor) {
  if (valor === null || valor === undefined) return '';
  return String(valor)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

/** Teclado inline de una fila por arreglo: [[{texto, dato}], …]. */
export function teclado(filas) {
  return {
    inline_keyboard: filas.map((fila) =>
      fila.map(({ texto, dato, url }) =>
        url ? { text: texto, url } : { text: texto, callback_data: dato },
      ),
    ),
  };
}

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Llama un método de la Bot API. Devuelve el `result` de Telegram.
 * @returns {Promise<{ok: true, resultado: any} | {ok: false, motivo: string, detalle: string}>}
 */
async function llamar(metodo, cuerpo, { reintentado = false } = {}) {
  if (!TOKEN) {
    throw new TelegramError('TELEGRAM_BOT_TOKEN no está configurado', { metodo });
  }

  let respuesta;
  try {
    respuesta = await fetch(`${BASE}/${metodo}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(cuerpo),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    // Red caída, DNS, timeout: es recuperable, que lo reintente la cola.
    throw new TelegramError(`No se pudo contactar a Telegram: ${err.message}`, { metodo });
  }

  let datos = null;
  try {
    datos = await respuesta.json();
  } catch {
    datos = null;
  }

  if (respuesta.ok && datos?.ok) {
    return { ok: true, resultado: datos.result };
  }

  const descripcion = datos?.description || `HTTP ${respuesta.status}`;

  // 429: nos pasamos del límite. Una espera y un reintento.
  if (respuesta.status === 429 && !reintentado) {
    const espera = Number(datos?.parameters?.retry_after ?? 1);
    log.aviso(`Telegram 429 en ${metodo}: espero ${espera}s y reintento una vez`);
    await dormir(Math.min(espera, 60) * 1000);
    return llamar(metodo, cuerpo, { reintentado: true });
  }

  // 403: bloqueado / chat inexistente. No es recuperable: no se reintenta.
  if (respuesta.status === 403) {
    log.aviso(`Telegram 403 en ${metodo}: ${descripcion} (no se reintenta)`);
    return { ok: false, motivo: 'bloqueado', detalle: descripcion };
  }

  // 400 con chat no encontrado: mismo caso práctico que el 403.
  if (respuesta.status === 400 && /chat not found|user is deactivated/i.test(descripcion)) {
    log.aviso(`Telegram 400 en ${metodo}: ${descripcion} (no se reintenta)`);
    return { ok: false, motivo: 'chat_invalido', detalle: descripcion };
  }

  throw new TelegramError(`Telegram ${metodo} falló (${respuesta.status}): ${descripcion}`, {
    codigo: respuesta.status,
    metodo,
  });
}

/**
 * Envía un mensaje HTML a un chat.
 * @param {number|string} chatId
 * @param {string} texto  ya escapado por quien lo arma (usar `esc` en los valores)
 * @param {{reply_markup?: object, disable_notification?: boolean,
 *          reply_to_message_id?: number, disable_web_page_preview?: boolean}} [opciones]
 */
export function enviarMensaje(chatId, texto, opciones = {}) {
  return llamar('sendMessage', {
    chat_id: chatId,
    text: texto,
    parse_mode: 'HTML',
    disable_web_page_preview: opciones.disable_web_page_preview ?? true,
    ...(opciones.reply_markup ? { reply_markup: opciones.reply_markup } : {}),
    ...(opciones.disable_notification !== undefined
      ? { disable_notification: opciones.disable_notification }
      : {}),
    ...(opciones.reply_to_message_id
      ? { reply_to_message_id: opciones.reply_to_message_id }
      : {}),
  });
}

/** Edita el texto de un mensaje ya enviado (p. ej. para apagar sus botones). */
export function editarMensaje(chatId, messageId, texto, opciones = {}) {
  return llamar('editMessageText', {
    chat_id: chatId,
    message_id: messageId,
    text: texto,
    parse_mode: 'HTML',
    disable_web_page_preview: opciones.disable_web_page_preview ?? true,
    ...(opciones.reply_markup ? { reply_markup: opciones.reply_markup } : {}),
  });
}
