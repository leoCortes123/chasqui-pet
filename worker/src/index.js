// ---------------------------------------------------------------------------
// Chasqui Pet — worker de tareas asíncronas (§2.2 puntos 3 y 4)
//
// El webhook de Telegram tiene que responder en menos de un segundo, así que
// todo el trabajo diferido (notificaciones, recibos, reportes) se encola en
// tarea_async y lo procesa este proceso.
//
// Reparto de responsabilidades con la base de datos:
//   - La BASE decide qué se reclama (FOR UPDATE SKIP LOCKED), cuánto se espera
//     para reintentar (backoff exponencial), cuándo una tarea muere y a quién
//     se le avisa. Todo eso ya está en reclamar_tareas/fallar_tarea.
//   - El WORKER solo despacha, ejecuta y reporta el resultado. No reimplementa
//     backoff, no lleva estado en memoria, no decide prioridades.
// Consecuencia: se pueden correr N workers en paralelo sin coordinarlos.
// ---------------------------------------------------------------------------

import pg from 'pg';
import { log, textoError } from './log.js';
import { manejadores, tiposConocidos } from './tareas/index.js';

const { Pool } = pg;

const INTERVALO_MS = Number(process.env.WORKER_INTERVALO_MS || 2000);
const LOTE = Number(process.env.WORKER_LOTE || 10);
const RESCATE_MS = 5 * 60 * 1000; // cada 5 minutos
const RESCATE_MINUTOS = Number(process.env.WORKER_RESCATE_MIN || 15);

// Los enteros de 64 bits (bigint) llegan como string por defecto en node-pg.
// tarea_async.id y telegram_chat_id caben de sobra en un Number de JS, y así
// los logs y los JSON quedan legibles.
pg.types.setTypeParser(20, (v) => (v === null ? null : Number(v)));

if (!process.env.DATABASE_URL) {
  log.error('Falta DATABASE_URL. El worker no puede arrancar.');
  process.exit(1);
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: Number(process.env.WORKER_POOL_MAX || Math.max(4, LOTE)),
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
  application_name: 'chasquipet-worker',
});

// Un error de conexión en un cliente ocioso no debe tumbar el proceso.
pool.on('error', (err) => {
  log.error(`error en cliente ocioso del pool: ${textoError(err)}`);
});

// --- Estado del proceso ------------------------------------------------------
let apagando = false;
const enVuelo = new Set(); // promesas de tareas que aún no terminan
let avisoTablaAvisos = false; // para no repetir la advertencia en cada pasada

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// Contexto que reciben los manejadores
// ---------------------------------------------------------------------------

/**
 * Reserva el aviso `tipo` para un turno. Devuelve true si el aviso es nuevo
 * (hay que enviarlo) y false si ya se había enviado.
 *
 * Es un INSERT ... ON CONFLICT DO NOTHING: atómico, así que dos workers que
 * miren la misma cola al tiempo no mandan el mismo mensaje dos veces.
 * Si la tabla todavía no está migrada (ver worker/sql/010_aviso_turno.sql),
 * se avisa una vez y se sigue sin deduplicar: es preferible un aviso repetido
 * a no avisarle a nadie que ya viene su turno.
 */
async function marcarAviso(turnoId, tipoAviso) {
  try {
    const { rowCount } = await pool.query(
      `INSERT INTO aviso_turno_enviado (turno_id, tipo)
       VALUES ($1, $2) ON CONFLICT DO NOTHING`,
      [turnoId, tipoAviso],
    );
    return rowCount > 0;
  } catch (err) {
    if (err.code === '42P01') {
      if (!avisoTablaAvisos) {
        avisoTablaAvisos = true;
        log.aviso(
          'la tabla aviso_turno_enviado no existe: los avisos de turno pueden repetirse. ' +
            'Integre worker/sql/010_aviso_turno.sql en db/migrations/.',
        );
      }
      return true;
    }
    throw err;
  }
}

const ctx = { db: pool, log, marcarAviso };

// ---------------------------------------------------------------------------
// Procesamiento de una tarea
// ---------------------------------------------------------------------------

async function procesar(tarea) {
  const t0 = Date.now();
  const manejar = manejadores.get(tarea.tipo);

  if (!manejar) {
    const msg =
      `tipo de tarea desconocido: '${tarea.tipo}'. ` +
      `Tipos registrados: ${tiposConocidos.join(', ')}`;
    await reportarFallo(tarea, msg, Date.now() - t0);
    return;
  }

  try {
    const resultado = await manejar(tarea, ctx);
    await pool.query('SELECT completar_tarea($1, $2)', [
      tarea.id,
      resultado === undefined ? null : JSON.stringify(resultado),
    ]);
    log.info(
      `tarea ${tarea.id} ${tarea.tipo} → completada en ${Date.now() - t0} ms` +
        (resultado ? ` ${resumen(resultado)}` : ''),
    );
  } catch (err) {
    await reportarFallo(tarea, textoError(err), Date.now() - t0);
  }
}

async function reportarFallo(tarea, mensaje, ms) {
  try {
    const { rows } = await pool.query('SELECT fallar_tarea($1, $2) AS desenlace', [
      tarea.id,
      mensaje,
    ]);
    const desenlace = rows[0]?.desenlace ?? 'desconocido';
    const nivel = desenlace === 'fallida' ? log.error : log.aviso;
    nivel(
      `tarea ${tarea.id} ${tarea.tipo} → ${desenlace} ` +
        `(intento ${tarea.intentos}/${tarea.max_intentos}) en ${ms} ms: ${mensaje}`,
    );
  } catch (err) {
    // Si ni siquiera se pudo registrar el fallo, la tarea queda 'procesando'
    // y la rescata rescatar_tareas_colgadas más adelante.
    log.error(
      `tarea ${tarea.id} ${tarea.tipo}: no se pudo registrar el fallo (${textoError(err)}). ` +
        `Error original: ${mensaje}`,
    );
  }
}

/** Resumen corto y de una sola línea del resultado, para el log. */
function resumen(resultado) {
  try {
    const s = JSON.stringify(resultado);
    return s.length > 220 ? `${s.slice(0, 217)}…` : s;
  } catch {
    return '';
  }
}

// ---------------------------------------------------------------------------
// Ciclo principal
// ---------------------------------------------------------------------------

async function pasada() {
  const { rows: tareas } = await pool.query('SELECT * FROM reclamar_tareas($1)', [LOTE]);
  if (tareas.length === 0) return 0;

  log.info(`reclamadas ${tareas.length} tarea(s)`);

  // En paralelo: son sobre todo llamadas HTTP a Telegram. Cada tarea maneja su
  // propio error, así que allSettled no debería ver rechazos, pero se usa por
  // seguridad: un rechazo suelto no puede tumbar la pasada.
  const promesas = tareas.map((t) => {
    const p = procesar(t).finally(() => enVuelo.delete(p));
    enVuelo.add(p);
    return p;
  });
  await Promise.allSettled(promesas);
  return tareas.length;
}

async function rescatar() {
  try {
    const { rows } = await pool.query('SELECT rescatar_tareas_colgadas($1) AS n', [
      RESCATE_MINUTOS,
    ]);
    const n = rows[0]?.n ?? 0;
    if (n > 0) {
      log.aviso(
        `rescatadas ${n} tarea(s) colgadas en 'procesando' por más de ${RESCATE_MINUTOS} min`,
      );
    }
  } catch (err) {
    log.error(`no se pudo rescatar tareas colgadas: ${textoError(err)}`);
  }
}

/**
 * Espera a que la base responda antes de empezar. Si Postgres todavía está
 * arrancando (compose levanta todo a la vez) no tiene sentido morir en bucle:
 * se reintenta con espera creciente hasta 30 s.
 */
async function esperarBase() {
  let intento = 0;
  for (;;) {
    if (apagando) return false;
    try {
      const { rows } = await pool.query(
        "SELECT current_database() AS db, config_txt('nombre_clinica', 'Chasqui Pet') AS clinica",
      );
      log.info(`conectado a la base '${rows[0].db}' (${rows[0].clinica})`);
      return true;
    } catch (err) {
      intento += 1;
      const espera = Math.min(30_000, 1000 * 2 ** Math.min(intento - 1, 5));
      log.aviso(
        `base no disponible (intento ${intento}): ${textoError(err)}. ` +
          `Reintento en ${Math.round(espera / 1000)} s`,
      );
      await dormir(espera);
    }
  }
}

async function principal() {
  log.info(
    `worker iniciado — intervalo ${INTERVALO_MS} ms, lote ${LOTE}, ` +
      `manejadores: ${tiposConocidos.join(', ')}`,
  );

  if (!(await esperarBase())) return;

  let proximoRescate = Date.now(); // el primer rescate va de una

  while (!apagando) {
    try {
      if (Date.now() >= proximoRescate) {
        proximoRescate = Date.now() + RESCATE_MS;
        await rescatar();
      }
      await pasada();
    } catch (err) {
      // Falla de la base (reinicio, red): no se muere el proceso, se reintenta.
      log.error(`error en la pasada: ${textoError(err)}`);
      await dormir(Math.max(INTERVALO_MS, 5000));
      continue;
    }
    if (apagando) break;
    await dormir(INTERVALO_MS);
  }
}

// ---------------------------------------------------------------------------
// Apagado limpio: deja de reclamar, termina lo que está en vuelo, cierra pool.
// Sin esto, un `docker compose restart` dejaría tareas en 'procesando' hasta
// que las rescatara el barrido de 15 minutos.
// ---------------------------------------------------------------------------

let apagadoIniciado = false;

async function apagar(senal) {
  if (apagadoIniciado) {
    log.aviso(`${senal} recibida de nuevo, ya se está apagando`);
    return;
  }
  apagadoIniciado = true;
  apagando = true;
  log.info(`${senal} recibida: no se reclaman más tareas`);

  if (enVuelo.size > 0) {
    log.info(`esperando ${enVuelo.size} tarea(s) en vuelo`);
    const limite = dormir(Number(process.env.WORKER_APAGADO_MS || 25_000)).then(
      () => 'timeout',
    );
    const fin = await Promise.race([Promise.allSettled([...enVuelo]), limite]);
    if (fin === 'timeout') {
      log.aviso(
        `${enVuelo.size} tarea(s) no alcanzaron a terminar; quedan para rescatar_tareas_colgadas`,
      );
    }
  }

  try {
    await pool.end();
    log.info('pool de Postgres cerrado');
  } catch (err) {
    log.error(`error al cerrar el pool: ${textoError(err)}`);
  }

  log.info('worker detenido');
  process.exit(0);
}

process.on('SIGTERM', () => void apagar('SIGTERM'));
process.on('SIGINT', () => void apagar('SIGINT'));

process.on('unhandledRejection', (err) => {
  log.error(`promesa sin manejar: ${textoError(err)}`);
});
process.on('uncaughtException', (err) => {
  log.error(`excepción no capturada: ${textoError(err)}`);
  void apagar('excepción');
});

principal().catch(async (err) => {
  log.error(`fallo irrecuperable: ${textoError(err)}`);
  await pool.end().catch(() => {});
  process.exit(1);
});
