'use server';

import { revalidatePath } from 'next/cache';
import { consultarUna } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';

/**
 * Acciones de la agenda (Fase B1b). Cada una es una llamada a una función de
 * `160_agenda.sql`: la validación, el choque de horarios y la auditoría viven
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

export async function agendarCita(
  _previo: Resultado | null,
  datos: FormData,
): Promise<Resultado> {
  const sesion = await exigirPermiso('agenda.gestionar', '/agenda');

  const paciente = texto(datos, 'paciente_id');
  const fecha = texto(datos, 'fecha');
  const hora = texto(datos, 'hora');

  if (!paciente) return { ok: false, mensaje: 'Elige la mascota de la cita.' };
  if (!fecha || !hora) return { ok: false, mensaje: 'Falta la fecha o la hora.' };

  const fila = await consultarUna<{ r: Resultado }>(
    'SELECT crear_cita($1, $2::jsonb, $3) AS r',
    [
      sesion.usuario_id,
      JSON.stringify({
        paciente_id: paciente,
        // La función interpreta «sin zona» como hora de Bogotá, que es la que
        // acaba de escribir quien está en el mostrador.
        inicio: `${fecha} ${hora}`,
        tipo: texto(datos, 'tipo') ?? 'general',
        veterinario_id: texto(datos, 'veterinario_id'),
        consultorio_id: texto(datos, 'consultorio_id'),
        sede_id: sesion.sede_id,
        notas: texto(datos, 'notas'),
      }),
      'web',
    ],
  );

  revalidatePath('/agenda');
  return fila?.r ?? FALLO;
}

export async function registrarLlegada(
  _previo: Resultado | null,
  datos: FormData,
): Promise<Resultado> {
  const sesion = await exigirPermiso('agenda.gestionar', '/agenda');
  const cita = texto(datos, 'cita_id');
  if (!cita) return FALLO;

  const fila = await consultarUna<{ r: Resultado }>(
    "SELECT confirmar_asistencia($1, $2, 'web') AS r",
    [sesion.usuario_id, cita],
  );

  revalidatePath('/agenda');
  return fila?.r ?? FALLO;
}

export async function cancelarCita(
  _previo: Resultado | null,
  datos: FormData,
): Promise<Resultado> {
  const sesion = await exigirPermiso('agenda.gestionar', '/agenda');
  const cita = texto(datos, 'cita_id');
  if (!cita) return FALLO;

  const fila = await consultarUna<{ r: Resultado }>(
    "SELECT cancelar_cita($1, $2, $3, 'web') AS r",
    [sesion.usuario_id, cita, texto(datos, 'motivo')],
  );

  revalidatePath('/agenda');
  return fila?.r ?? FALLO;
}

export async function reprogramarCita(
  _previo: Resultado | null,
  datos: FormData,
): Promise<Resultado> {
  const sesion = await exigirPermiso('agenda.gestionar', '/agenda');
  const cita = texto(datos, 'cita_id');
  const fecha = texto(datos, 'fecha');
  const hora = texto(datos, 'hora');
  if (!cita) return FALLO;
  if (!fecha || !hora) return { ok: false, mensaje: 'Falta la fecha o la hora nueva.' };

  const fila = await consultarUna<{ r: Resultado }>(
    "SELECT reprogramar_cita($1, $2, $3, NULL, $4, 'web') AS r",
    [sesion.usuario_id, cita, `${fecha} ${hora}`, texto(datos, 'motivo')],
  );

  revalidatePath('/agenda');
  return fila?.r ?? FALLO;
}
