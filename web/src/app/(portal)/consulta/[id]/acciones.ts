'use server';

import { revalidatePath } from 'next/cache';
import { consultarUna } from '@/lib/db';
import { esUuid } from '@/lib/clinico';
import { exigirSesion, puede } from '@/lib/sesion';

/**
 * Acciones del formulario de consulta (§8.2.5).
 *
 * Ninguna decide nada: arman el jsonb y llaman a las mismas funciones SQL que
 * usa el bot. Los rangos del examen, los campos obligatorios para firmar y la
 * inmutabilidad de lo firmado se validan una sola vez, en Postgres.
 */

/** Campos de texto de la consulta que el formulario puede enviar. */
const CAMPOS = [
  'motivo_consulta',
  'anamnesis',
  'diagnostico_presuntivo',
  'diagnostico_definitivo',
  'plan_tratamiento',
  'recomendaciones',
  'remision_externa',
  'proxima_revision',
] as const;

/** Claves del examen físico. Van con prefijo `examen.` al jsonb. */
const EXAMEN = [
  'peso_kg',
  'temperatura_c',
  'fc',
  'fr',
  'tllc_seg',
  'mucosas',
  'hidratacion',
  'cc',
] as const;

export interface EstadoFormulario {
  ok: boolean | null;
  mensaje: string | null;
}

export const ESTADO_INICIAL: EstadoFormulario = { ok: null, mensaje: null };

export async function guardarFormulario(
  _previo: EstadoFormulario,
  datos: FormData,
): Promise<EstadoFormulario> {
  const sesion = await exigirSesion();
  const consultaId = String(datos.get('consulta_id') ?? '');
  const accion = String(datos.get('accion') ?? 'guardar');

  if (!esUuid(consultaId)) {
    return { ok: false, mensaje: 'Esa consulta no existe.' };
  }

  if (!puede(sesion, 'consulta.crear')) {
    return { ok: false, mensaje: 'No tienes permiso para editar consultas.' };
  }

  if (accion === 'adenda') {
    return agregarAdenda(sesion.usuario_id, consultaId, String(datos.get('texto') ?? ''));
  }

  const cambios: Record<string, string> = {};
  for (const campo of CAMPOS) {
    if (datos.has(campo)) cambios[campo] = String(datos.get(campo) ?? '').trim();
  }
  for (const clave of EXAMEN) {
    if (datos.has(`examen.${clave}`)) {
      cambios[`examen.${clave}`] = String(datos.get(`examen.${clave}`) ?? '').trim();
    }
  }

  const guardado = await consultarUna<{ r: { ok: boolean; mensaje?: string } }>(
    'SELECT guardar_consulta_completa($1, $2, $3::jsonb, $4) AS r',
    [sesion.usuario_id, consultaId, JSON.stringify(cambios), 'web'],
  );

  if (!guardado?.r?.ok) {
    return { ok: false, mensaje: guardado?.r?.mensaje ?? 'No se pudo guardar.' };
  }

  if (accion !== 'firmar') {
    revalidatePath(`/consulta/${consultaId}`);
    return { ok: true, mensaje: 'Borrador guardado.' };
  }

  if (!puede(sesion, 'consulta.firmar')) {
    return { ok: false, mensaje: 'Guardado, pero no tienes permiso para firmar consultas.' };
  }

  const firmado = await consultarUna<{ r: { ok: boolean; mensaje?: string } }>(
    'SELECT firmar_consulta($1, $2, $3) AS r',
    [sesion.usuario_id, consultaId, 'web'],
  );

  revalidatePath(`/consulta/${consultaId}`);

  if (!firmado?.r?.ok) {
    return { ok: false, mensaje: firmado?.r?.mensaje ?? 'No se pudo firmar.' };
  }

  return { ok: true, mensaje: 'Consulta firmada. A partir de ahora sólo admite adendas.' };
}

async function agregarAdenda(
  usuarioId: string,
  consultaId: string,
  texto: string,
): Promise<EstadoFormulario> {
  const r = await consultarUna<{ r: { ok: boolean; mensaje?: string } }>(
    'SELECT agregar_adenda($1, $2, $3, $4) AS r',
    [usuarioId, consultaId, texto, 'web'],
  );

  revalidatePath(`/consulta/${consultaId}`);

  return r?.r?.ok
    ? { ok: true, mensaje: 'Adenda agregada.' }
    : { ok: false, mensaje: r?.r?.mensaje ?? 'No se pudo agregar la adenda.' };
}
