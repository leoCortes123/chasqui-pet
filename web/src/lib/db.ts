import { Client, Pool, type QueryResultRow } from 'pg';

/**
 * Acceso a PostgreSQL sin ORM.
 *
 * Se mantienen DOS rutas de conexión distintas y a propósito:
 *
 *  1. `pool` — el pool normal para consultas. Puede ir a través de pgbouncer.
 *  2. `crearClienteEscucha()` — conexiones dedicadas para `LISTEN`. Una conexión
 *     que está escuchando notificaciones NO puede además atender consultas del
 *     pool, y pgbouncer en modo transaction rompe `LISTEN`. Por eso usan
 *     `DATABASE_URL_DIRECTA` si existe, cayendo a `DATABASE_URL`.
 */

const MAX_CONEXIONES = Number(process.env.DB_POOL_MAX ?? 10);

function urlConsultas(): string {
  const url = process.env.DATABASE_URL;
  if (!url) {
    throw new Error(
      'Falta la variable de entorno DATABASE_URL. La aplicación no puede conectarse a PostgreSQL.',
    );
  }
  return url;
}

/** URL sin pgbouncer, para las conexiones que hacen LISTEN. */
export function urlDirecta(): string {
  return process.env.DATABASE_URL_DIRECTA ?? urlConsultas();
}

// En desarrollo Next recarga los módulos en caliente; sin este caché global se
// abriría un pool nuevo en cada recarga hasta agotar las conexiones de Postgres.
const global_ = globalThis as unknown as { __chasquipetPool?: Pool };

export function obtenerPool(): Pool {
  if (!global_.__chasquipetPool) {
    const pool = new Pool({
      connectionString: urlConsultas(),
      max: MAX_CONEXIONES,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 5_000,
      application_name: 'chasquipet-web',
    });

    // Un error en un cliente ocioso no debe tumbar el proceso de Node.
    pool.on('error', (error) => {
      console.error('[db] error en cliente ocioso del pool:', error.message);
    });

    global_.__chasquipetPool = pool;
  }
  return global_.__chasquipetPool;
}

/** Consulta suelta contra el pool. */
export async function consultar<T extends QueryResultRow = QueryResultRow>(
  texto: string,
  valores: readonly unknown[] = [],
): Promise<T[]> {
  const resultado = await obtenerPool().query<T>(texto, valores as unknown[]);
  return resultado.rows;
}

/** Consulta que devuelve una sola fila (o `null` si no hay ninguna). */
export async function consultarUna<T extends QueryResultRow = QueryResultRow>(
  texto: string,
  valores: readonly unknown[] = [],
): Promise<T | null> {
  const filas = await consultar<T>(texto, valores);
  return filas[0] ?? null;
}

/**
 * Cliente dedicado y ya conectado, fuera del pool de consultas.
 * Quien lo pide es responsable de cerrarlo con `cliente.end()`.
 */
export async function crearClienteEscucha(): Promise<Client> {
  const cliente = new Client({
    connectionString: urlDirecta(),
    application_name: 'chasquipet-web-listen',
  });
  await cliente.connect();
  return cliente;
}

/** `SELECT 1` para el health check. Lanza si la base no responde. */
export async function verificarBase(): Promise<void> {
  await consultar('SELECT 1');
}
