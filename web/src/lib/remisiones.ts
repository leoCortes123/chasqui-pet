import { consultar, consultarUna } from './db';

/**
 * Lectura de remisiones externas para el portal (Fase B3).
 *
 * Igual que `agenda.ts` y `clinico.ts`: lo que devuelven las funciones SQL se
 * muestra tal cual. Si una remisión aparece como vencida es porque la base lo
 * dice, no porque esta capa compare fechas.
 */

export interface Resultado {
  resultado_id: string;
  texto: string | null;
  tiene_adjunto: boolean;
  adjunto_file_id: string | null;
  adjunto_url: string | null;
  cargado_por: string | null;
  cargado_at: string;
}

export interface Remision {
  remision_id: string;
  estado: 'pendiente' | 'recibida' | 'anulada';
  tipo: 'laboratorio' | 'imagenes' | 'especialista' | 'otro';
  destino: string;
  examenes: string;
  motivo: string | null;
  paciente_id: string;
  paciente: string;
  especie: string;
  emoji: string;
  dueno_id: string | null;
  dueno: string | null;
  telefono: string | null;
  consulta_id: string | null;
  fecha_solicitud: string;
  fecha_esperada: string | null;
  dias_esperando: number;
  vencida: boolean;
  solicitada_por: string | null;
  motivo_anulacion: string | null;
  /** Si al dueño ya se le avisó que el resultado llegó. */
  avisado: boolean;
  resultados: Resultado[];
}

export interface Pendientes {
  ok: boolean;
  sede_id: string;
  remisiones: Remision[];
  total: number;
  vencidas: number;
}

export async function remisionesPendientes(
  usuarioId: string,
  sedeId: string | null,
  limite = 30,
): Promise<Pendientes | null> {
  const fila = await consultarUna<{ r: Pendientes | null }>(
    'SELECT remisiones_pendientes($1, $2, $3) AS r',
    [usuarioId, sedeId, limite],
  );
  return fila?.r ?? null;
}

/**
 * Las cerradas de los últimos días: se leen para consultar un resultado que
 * ya llegó, no para operar sobre ellas. No hay función SQL propia porque no
 * hay regla de negocio detrás — es una consulta de listado.
 */
export async function remisionesCerradas(
  sedeId: string | null,
  dias = 30,
): Promise<Remision[]> {
  const filas = await consultar<{ r: Remision }>(
    `SELECT remision_json(id) AS r
       FROM remision
      WHERE estado <> 'pendiente'
        AND ($1::uuid IS NULL OR sede_id = $1)
        AND fecha_solicitud >= hoy_bogota() - $2::int
      ORDER BY COALESCE(recibida_at, anulada_at) DESC NULLS LAST
      LIMIT 30`,
    [sedeId, dias],
  );
  return filas.map((f) => f.r);
}

export const ETIQUETA_TIPO: Record<Remision['tipo'], string> = {
  laboratorio: 'Laboratorio',
  imagenes: 'Imágenes',
  especialista: 'Especialista',
  otro: 'Otro',
};
