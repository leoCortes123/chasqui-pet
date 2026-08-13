// ---------------------------------------------------------------------------
// chasqui_responder — payload {chat_id, usuario_id, sede_id}
//
// El lado lento de «Habla con Chasqui»: llama a la API de DeepSeek, ejecuta
// las herramientas que pida y manda la respuesta por Telegram.
//
// Este archivo es deliberadamente tonto. No sabe qué es un turno, ni cuánto
// cuesta una consulta, ni quién puede cobrar. Solo sabe tres cosas:
//
//   1. pedirle a la base el catálogo de herramientas y el historial,
//   2. reenviar cada llamada de herramienta a `ia_llamar`,
//   3. parar en seco cuando `ia_llamar` responde que algo necesita
//      confirmación, y mostrar la tarjeta que armó la base.
//
// Todo el criterio —qué se puede hacer, con qué permisos, qué texto ve el
// usuario— vive en 078_chasqui_ia.sql. Si mañana hay que agregar una
// herramienta, se agrega allá y aquí no se toca nada.
//
// El punto 3 es el que sostiene «las acciones las confirma la persona»: en
// cuanto una herramienta devuelve `requiere_confirmacion`, se abandona el
// turno del modelo. Lo que dijera después daría igual, porque no va a
// ejecutarse nada hasta que alguien toque el botón. Las llamadas que el
// modelo hubiera pedido en el mismo lote ya no se ejecutan: se les responde
// que hay algo esperando confirmación (ver el bucle de herramientas).
//
// Sobre el cliente: DeepSeek expone una API compatible con la de OpenAI, así
// que se usa el SDK de OpenAI apuntado a su servidor. Es el camino que la
// propia DeepSeek documenta, y evita reescribir reintentos y timeouts.
// ---------------------------------------------------------------------------

import OpenAI from 'openai';
import { enviarMensaje, esc, teclado } from '../telegram.js';

export const tipo = 'chasqui_responder';

// Tope de vueltas del bucle consultar → responder. Con 8 le alcanza de
// sobra para buscar un medicamento, mirar sus lotes y responder; si se pasa
// de ahí es que se enredó, y es mejor cortar que dejarlo girando contra la
// API cobrando por vuelta.
const MAX_VUELTAS = 8;

const BASE_URL = process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com';

// Se construye una sola vez y se reutiliza: abre menos conexiones y el SDK
// ya trae reintentos con espera creciente para 429 y 5xx.
const cliente = process.env.DEEPSEEK_API_KEY
  ? new OpenAI({
      apiKey: process.env.DEEPSEEK_API_KEY,
      baseURL: BASE_URL,
      timeout: Number(process.env.IA_TIMEOUT_MS || 90_000),
      maxRetries: 2,
    })
  : null;

/**
 * Instrucciones del asistente. Se arman aquí y no en la base porque son
 * sobre CÓMO conversar; lo que puede hacer ya se lo dice el catálogo de
 * herramientas, que sí viene de la base.
 */
function instrucciones(ctx) {
  return [
    `Eres Chasqui, el asistente de ${ctx.clinica}, una clínica veterinaria en Colombia.`,
    `Hablas por Telegram con ${ctx.usuario}, que trabaja aquí.`,
    '',
    'Contexto de este momento:',
    `- Hoy es ${ctx.fecha_hoy} y son las ${ctx.hora_local} en Bogotá.`,
    ctx.sede ? `- Está en la ${ctx.sede}.` : null,
    ctx.consultorio_abierto
      ? `- Tiene abierto el ${ctx.consultorio_abierto}.`
      : '- No tiene ningún consultorio abierto.',
    `- Roles: ${(ctx.roles ?? []).join(', ') || 'sin rol asignado'}.`,
    `- El dinero es en ${ctx.moneda}.`,
    ctx.sobre_el_negocio ? `\nSobre la clínica:\n${ctx.sobre_el_negocio}` : null,
    '',
    'Cómo trabajas:',
    '- Responde en español neutro y trata de "tú". Nunca uses "vos" ni "tenés".',
    '- Estás en un chat de celular, no escribiendo un informe. Contesta en',
    '  pocas frases, sin encabezados ni secciones. Usa viñetas sólo cuando de',
    '  verdad estés enumerando varias cosas.',
    '- Responde LO QUE TE PREGUNTARON y nada más. Si te preguntan por un',
    '  medicamento, no listes el resto del inventario; si te preguntan un',
    '  precio, no expliques el catálogo entero. Lo demás lo pueden pedir',
    '  después.',
    '- Consulta antes de responder. Si te preguntan por la cola, el stock, la',
    '  caja o un paciente, usa la herramienta correspondiente: nunca respondas',
    '  con datos de memoria ni inventes cifras, nombres o identificadores.',
    '- Llama solamente las herramientas que hagan falta para lo que te',
    '  preguntaron. Cada consulta de más es tiempo que la persona espera.',
    '- Si una herramienta no encuentra nada, dilo tal cual. No rellenes.',
    '- Si te piden algo que no puedes hacer, dilo con naturalidad y ofrece la',
    '  alternativa más cercana. No insistas por otro camino.',
    '- Los identificadores internos (UUID, lote_id, cuenta_id) son para usar',
    '  las herramientas, no para mostrarlos. Habla de nombres y códigos.',
    '',
    'Sobre las acciones que cambian datos (llamar un turno, sacar un',
    'medicamento, cobrar): tú no las ejecutas. Al usarlas, el sistema le',
    'muestra al usuario un resumen con un botón de confirmar, y solo él',
    'decide. Así que úsalas cuando te lo pidan, sin pedir permiso antes por',
    'chat: el botón ES el permiso. Después de invocarla no digas nada más,',
    'el sistema se encarga de mostrarla.',
    '',
    'También respondes dudas sobre cómo funciona la clínica —servicios,',
    'horarios, cómo está configurado algo, cómo se hace un flujo en el bot—.',
    'Para eso tienes informacion_clinica. Si algo no está en los datos y no lo',
    'sabes, dilo en vez de suponerlo.',
  ]
    .filter((l) => l !== null)
    .join('\n');
}

/** Convierte lo que devuelve la Bot API en algo legible para el log. */
function resumenEnvio(r) {
  return r.ok ? 'enviado' : `no enviado (${r.motivo})`;
}

/**
 * Pasa la respuesta del modelo al HTML que entiende Telegram.
 *
 * Se le pide en el prompt que no use markdown y aun así lo usa: es lo que
 * tiene entrenado. Pedirlo más fuerte no lo arregla de forma confiable, y
 * un `**negrita**` sin convertir se ve literal en el chat. Así que se
 * convierte aquí, que sí es determinista.
 *
 * El orden importa: primero se escapa —lo que llega es texto sin
 * confianza— y sólo después se reintroducen las etiquetas que queremos.
 * Al revés, un `<b>` escrito por el modelo entraría como etiqueta real.
 */
function formatearParaTelegram(texto) {
  let t = esc(texto);

  // Encabezados markdown: Telegram no los tiene. Se vuelven negrita.
  t = t.replace(/^\s{0,3}#{1,6}\s+(.+)$/gm, '<b>$1</b>');

  // Bloques y trozos de código antes que nada: adentro no se toca. Se
  // apartan detrás de un centinela de control (U+0000), que no puede venir
  // en el texto del modelo. Con un marcador visible tipo " 3 " se
  // confundiría con las cifras de una respuesta llena de cantidades y
  // precios, y el reemplazo final destrozaría la respuesta.
  const codigos = [];
  const apartar = (html) => `\u0000${codigos.push(html) - 1}\u0000`;
  t = t.replace(/```[a-z]*\n?([\s\S]*?)```/g, (_, c) => apartar(`<pre>${c.trim()}</pre>`));
  t = t.replace(/`([^`\n]+)`/g, (_, c) => apartar(`<code>${c}</code>`));

  t = t.replace(/\*\*\*(.+?)\*\*\*/g, '<b><i>$1</i></b>');
  t = t.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
  t = t.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,;:!?]|$)/g, '$1<i>$2</i>');
  // El guión bajo se deja fuera a propósito: aquí abundan los nombres de
  // herramienta y los códigos de lote con guiones bajos, y volverlos
  // cursiva a media palabra rompe más de lo que arregla.

  // Viñetas: el punto medio se ve mejor que el guión en un celular.
  t = t.replace(/^(\s*)[-*]\s+/gm, '$1• ');

  t = t.replace(/\u0000(\d+)\u0000/g, (_, i) => codigos[Number(i)]);

  // Telegram corta en 4096 caracteres; se recorta antes para no perder el
  // mensaje entero por pasarse de largo.
  return t.length > 3900 ? `${t.slice(0, 3900)}…` : t;
}

export async function manejar({ payload }, { db, log }) {
  const chatId = payload?.chat_id;
  const usuarioId = payload?.usuario_id;
  const sedeId = payload?.sede_id ?? null;

  if (!chatId || !usuarioId) throw new Error('payload sin chat_id o usuario_id');

  if (!cliente) {
    // Falta la llave: no es recuperable reintentando, así que se avisa al
    // usuario y se completa la tarea en vez de quemar los intentos.
    await enviarMensaje(
      chatId,
      '💬 Chasqui no está configurado todavía (falta la llave de la API). ' +
        'Avísale al administrador. Mientras tanto usa /menu.',
    );
    log.aviso('DEEPSEEK_API_KEY no está configurada: Chasqui no puede responder');
    return { respondido: false, motivo: 'sin_api_key' };
  }

  // Todo el estado viene de la base en una sola consulta: catálogo,
  // historial, contexto y parámetros. El worker no guarda nada entre
  // tareas, así que dos workers en paralelo no se pisan.
  const { rows } = await db.query(
    `SELECT ia_herramientas($1)          AS herramientas,
            ia_historial($2)             AS historial,
            ia_contexto($1, $3)          AS contexto,
            config_txt('ia_modelo', 'nemotron-3-ultra-free')  AS modelo,
            config_txt('ia_temperatura', '0.3')         AS temperatura`,
    [usuarioId, chatId, sedeId],
  );
  const { herramientas, historial, contexto, modelo, temperatura } = rows[0];

  if (!historial.length) {
    log.aviso(`chat ${chatId}: no hay nada que responder`);
    return { respondido: false, motivo: 'sin_historial' };
  }

  // El prompt de sistema va de primero y el historial detrás, tal como lo
  // guardó la base: texto plano por turno.
  const mensajes = [
    { role: 'system', content: instrucciones(contexto) },
    ...historial.map((m) => ({ role: m.role, content: m.content })),
  ];

  let pendiente = null; // primera acción que pidió confirmación
  let mensajeFinal = null;
  let vueltas = 0;
  let tokens = { entrada: 0, salida: 0 };

  while (vueltas < MAX_VUELTAS && !pendiente) {
    vueltas += 1;

    const respuesta = await cliente.chat.completions.create({
      model: modelo,
      messages: mensajes,
      tools: herramientas,
      temperature: Number(temperatura) || 0.3,
      max_tokens: 2048,
    });

    if (respuesta.usage) {
      tokens.entrada += respuesta.usage.prompt_tokens ?? 0;
      tokens.salida += respuesta.usage.completion_tokens ?? 0;
    }

    mensajeFinal = respuesta.choices?.[0]?.message;
    if (!mensajeFinal) break;

    // El turno del asistente entra al historial de esta vuelta con sus
    // tool_calls: la API exige que cada resultado que se mande después
    // corresponda a una llamada que ella misma pidió.
    //
    // `reasoning_content` se deja fuera a propósito: DeepSeek lo devuelve
    // pero no lo acepta de vuelta, y reenviarlo hace fallar la petición.
    mensajes.push({
      role: 'assistant',
      content: mensajeFinal.content ?? '',
      ...(mensajeFinal.tool_calls?.length ? { tool_calls: mensajeFinal.tool_calls } : {}),
    });

    const llamadas = mensajeFinal.tool_calls ?? [];
    if (llamadas.length === 0) break;

    for (const llamada of llamadas) {
      const nombre = llamada.function?.name;
      let argumentos = {};
      try {
        argumentos = JSON.parse(llamada.function?.arguments || '{}');
      } catch {
        // El modelo mandó JSON roto. Se le dice y que reintente.
        mensajes.push({
          role: 'tool',
          tool_call_id: llamada.id,
          content: JSON.stringify({ ok: false, error: 'Los argumentos no son JSON válido.' }),
        });
        continue;
      }

      // Ya hay una propuesta esperando confirmación en este turno: la
      // llamada NO llega a `ia_llamar`. Si llegara y fuera una escritura,
      // dejaría otra fila en `ia_accion_pendiente` de la que nadie va a
      // saber nunca, porque el bot muestra una sola tarjeta. Se prefiere
      // no crear la basura a tener que purgarla después.
      //
      // Aun así hay que devolver un resultado por cada llamada: la API
      // rechaza la petición entera si falta uno. Se le explica al modelo
      // qué pasó para que no insista en la siguiente vuelta.
      if (pendiente) {
        log.info(`chat ${chatId} · herramienta ${nombre} → omitida (hay una propuesta sin confirmar)`);
        mensajes.push({
          role: 'tool',
          tool_call_id: llamada.id,
          content: JSON.stringify({
            ok: false,
            error:
              'Ya hay una acción esperando la confirmación de la persona. No propongas ' +
              'nada más ni la repitas: cuando confirme o cancele, seguimos.',
          }),
        });
        continue;
      }

      let datos;
      try {
        const r = await db.query('SELECT ia_llamar($1, $2, $3, $4, $5) AS r', [
          usuarioId,
          chatId,
          sedeId,
          nombre,
          JSON.stringify(argumentos),
        ]);
        datos = r.rows[0].r;
      } catch (err) {
        // Un error de base se le devuelve al modelo como resultado para que
        // lo cuente o corrija; no se cae la tarea por una consulta mala.
        datos = { ok: false, error: err.message };
      }

      log.info(
        `chat ${chatId} · herramienta ${nombre} → ` +
          (datos?.requiere_confirmacion ? 'propuesta' : datos?.ok ? 'ok' : 'error'),
      );

      if (datos?.requiere_confirmacion) {
        pendiente = { ...datos, herramienta: nombre };
      }

      // Un resultado por cada llamada, sin saltarse ninguna: si falta uno,
      // la siguiente petición se rechaza entera.
      mensajes.push({
        role: 'tool',
        tool_call_id: llamada.id,
        content: JSON.stringify(datos),
      });
    }
  }

  // --- Caso 1: hay algo que confirmar ------------------------------------
  //
  // Se ignora lo que el modelo haya escrito y se manda la tarjeta que armó
  // la base. Esto es a propósito: el texto de una confirmación tiene que
  // salir de los datos, no de la redacción del modelo.
  if (pendiente) {
    const { rows: t } = await db.query('SELECT bot_ia_tarjeta_confirmacion($1) AS t', [
      pendiente.accion_id,
    ]);
    const tarjeta = t[0].t;

    const r = await enviarMensaje(chatId, tarjeta.texto, {
      reply_markup: teclado(
        (tarjeta.botones ?? []).map((fila) => fila.map((b) => ({ texto: b.t, dato: b.d }))),
      ),
    });

    return {
      respondido: r.ok,
      confirmacion: pendiente.accion_id,
      herramienta: pendiente.herramienta,
      vueltas,
      tokens,
      envio: resumenEnvio(r),
    };
  }

  // --- Caso 2: respuesta de texto ----------------------------------------
  const texto = (mensajeFinal?.content ?? '').trim();

  if (!texto) {
    // Se quedó sin vueltas o contestó vacío. Pasa poco, pero un chat mudo
    // es peor que un aviso honesto.
    await enviarMensaje(
      chatId,
      '💬 Me enredé con eso y no logré armar la respuesta. Vuelve a preguntármelo ' +
        'de otra forma, o usa /menu.',
    );
    return { respondido: false, motivo: 'sin_texto', vueltas, tokens };
  }

  // Solo se guarda la respuesta final, no las llamadas a herramientas: los
  // datos que consultó ya están dentro del texto.
  await db.query('SELECT ia_registrar($1, $2, $3, $4)', [
    chatId,
    usuarioId,
    'assistant',
    JSON.stringify(texto),
  ]);

  const r = await enviarMensaje(chatId, formatearParaTelegram(texto), {
    reply_markup: teclado([[{ texto: '⬅️ Menú', dato: 'ia:salir' }]]),
  });

  return {
    respondido: r.ok,
    vueltas,
    caracteres: texto.length,
    tokens,
    envio: resumenEnvio(r),
  };
}
