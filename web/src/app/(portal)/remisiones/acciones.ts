'use server';

import { revalidatePath } from 'next/cache';
import { consultarUna } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';

/**
 * Acciones de remisiones (Fase B3). Cada una es una llamada a una función de
 * `190_remisiones.sql`: la validación, el aviso al dueño y la auditoría viven
 * en Postgres. Esta capa sólo traduce un `FormData` a parámetros.
 *
 * El `exigirPermiso` de arriba es la segunda cerradura, no la única: la
 * función SQL vuelve a exigirlo con el `usuario_id` de la sesión.
 */

export type Resultado = { ok: boolean; mensaje?: string; motivo?: string };

const FALLO: Resultado = { ok: false, mensaje: 'No se pudo completar la operación.' };

function texto(datos: FormData, clave: string): string | null {
  const valor = datos.get(clave);
  if (valor === null) return null;
  const limpio = String(valor).trim();
  return limpio === '' ? null : limpio;
}

export async function crearRemision(
  _previo: Resultado | null,
  datos: FormData,
): Promise<Resultado> {
  const sesion = await exigirPermiso('remision.gestionar', '/remisiones');

  const paciente = texto(datos, 'paciente_id');
  if (!paciente) return { ok: false, mensaje: 'Elige la mascota que se remite.' };

  const fila = await consultarUna<{ r: Resultado }>(
    "SELECT crear_remision($1, $2::jsonb, 'web') AS r",
    [
      sesion.usuario_id,
      JSON.stringify({
        paciente_id: paciente,
        destino: texto(datos, 'destino'),
        examenes: texto(datos, 'examenes'),
        tipo: texto(datos, 'tipo') ?? 'laboratorio',
        fecha_esperada: texto(datos, 'fecha_esperada'),
        motivo: texto(datos, 'motivo'),
        consulta_id: texto(datos, 'consulta_id'),
      }),
    ],
  );

  revalidatePath('/remisiones');
  return fila?.r ?? FALLO;
}

/**
 * Carga el resultado que llegó. El aviso al dueño lo decide y lo encola la
 * función SQL, respetando el consentimiento (§12); aquí no se decide nada.
 */
export async function cargarResultado(
  _previo: Resultado | null,
  datos: FormData,
): Promise<Resultado> {
  const sesion = await exigirPermiso('remision.gestionar', '/remisiones');
  const remision = texto(datos, 'remision_id');
  if (!remision) return FALLO;

  const fila = await consultarUna<{ r: Resultado }>(
    "SELECT registrar_resultado($1, $2, $3::jsonb, 'web') AS r",
    [
      sesion.usuario_id,
      remision,
      JSON.stringify({ texto: texto(datos, 'texto'), url: texto(datos, 'url') }),
    ],
  );

  revalidatePath('/remisiones');
  return fila?.r ?? FALLO;
}

export async function anularRemision(
  _previo: Resultado | null,
  datos: FormData,
): Promise<Resultado> {
  const sesion = await exigirPermiso('remision.gestionar', '/remisiones');
  const remision = texto(datos, 'remision_id');
  if (!remision) return FALLO;

  const fila = await consultarUna<{ r: Resultado }>(
    "SELECT anular_remision($1, $2, $3, 'web') AS r",
    [sesion.usuario_id, remision, texto(datos, 'motivo')],
  );

  revalidatePath('/remisiones');
  return fila?.r ?? FALLO;
}
