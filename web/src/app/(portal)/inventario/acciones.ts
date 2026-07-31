'use server';

import { revalidatePath } from 'next/cache';
import { consultarUna } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';

/**
 * Acciones del catálogo (§11.2). Cada una es una llamada a una función de
 * `085_admin.sql`: la validación y la auditoría viven en Postgres, no
 * aquí. Esta capa sólo traduce un `FormData` a parámetros.
 *
 * El `exigirPermiso` de arriba es la segunda cerradura, no la única: la
 * función SQL vuelve a exigirlo con el `usuario_id` de la sesión.
 */

type Resultado = { ok: boolean; mensaje?: string };

export async function guardarMedicamento(_previo: Resultado | null, datos: FormData): Promise<Resultado> {
  const sesion = await exigirPermiso('inventario.catalogo', '/inventario');
  const id = String(datos.get('medicamento_id') ?? '');

  const campos: Record<string, unknown> = {};
  for (const clave of [
    'nombre_generico',
    'nombre_comercial',
    'principio_activo',
    'presentacion',
    'concentracion',
    'categoria',
    'unidad_base',
  ]) {
    const valor = datos.get(clave);
    if (valor !== null) campos[clave] = String(valor);
  }
  for (const clave of ['precio_venta', 'stock_minimo']) {
    const valor = datos.get(clave);
    if (valor !== null && String(valor) !== '') campos[clave] = Number(String(valor).replace(',', '.'));
  }
  if (datos.has('requiere_receta')) campos.requiere_receta = datos.get('requiere_receta') === 'on';
  if (datos.has('activo')) campos.activo = datos.get('activo') === 'on';

  if (id) {
    const fila = await consultarUna<{ r: Resultado }>(
      'SELECT editar_medicamento($1, $2, $3::jsonb) AS r',
      [sesion.usuario_id, id, JSON.stringify(campos)],
    );
    revalidatePath('/inventario');
    return fila?.r ?? { ok: false, mensaje: 'No se pudo guardar.' };
  }

  const nombre = String(datos.get('nombre_generico') ?? '').trim();
  if (!nombre) return { ok: false, mensaje: 'El medicamento necesita un nombre genérico.' };

  const fila = await consultarUna<{ r: Resultado }>(
    `SELECT crear_medicamento($1, $2, $3::numeric, $4, $5, NULL, $6, $7, $8, $9, $10::numeric, 'web') AS r`,
    [
      sesion.usuario_id,
      nombre,
      Number(String(datos.get('precio_venta') ?? '0').replace(',', '.')) || 0,
      String(datos.get('unidad_base') ?? 'unidad'),
      String(datos.get('nombre_comercial') ?? '') || null,
      String(datos.get('presentacion') ?? '') || null,
      String(datos.get('concentracion') ?? '') || null,
      String(datos.get('categoria') ?? '') || null,
      datos.get('requiere_receta') === 'on',
      Number(String(datos.get('stock_minimo') ?? '0').replace(',', '.')) || 0,
    ],
  );

  revalidatePath('/inventario');
  return fila?.r ?? { ok: false, mensaje: 'No se pudo crear.' };
}
