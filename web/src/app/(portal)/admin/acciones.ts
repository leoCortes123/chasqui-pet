'use server';

import { revalidatePath } from 'next/cache';
import { consultarUna } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';

/**
 * Acciones administrativas. Todas delegan en las funciones de
 * `085_admin.sql`, que son las que comprueban el permiso de verdad y
 * escriben la auditoría. Aquí sólo se traduce el formulario y se decide
 * qué revalidar.
 */

export type Resultado = { ok: boolean; mensaje?: string };

const FALLO: Resultado = { ok: false, mensaje: 'No se pudo completar la operación.' };

function texto(datos: FormData, clave: string): string {
  return String(datos.get(clave) ?? '').trim();
}

// --- Usuarios --------------------------------------------------------------

export async function crearUsuario(_previo: Resultado | null, datos: FormData): Promise<Resultado> {
  const sesion = await exigirPermiso('usuarios.gestionar', '/admin/usuarios');

  const telegram = texto(datos, 'telegram_user_id');
  const nombre = texto(datos, 'nombre');
  const roles = datos.getAll('roles').map(String).filter(Boolean);

  if (!/^\d+$/.test(telegram)) {
    return { ok: false, mensaje: 'El id de Telegram es un número. Se obtiene con @userinfobot.' };
  }
  if (!nombre) return { ok: false, mensaje: 'Falta el nombre.' };
  if (roles.length === 0) return { ok: false, mensaje: 'Elige al menos un rol.' };

  try {
    await consultarUna(
      `SELECT crear_usuario($1, $2::bigint, $3, $4::text[], NULL, $5, 'web') AS id`,
      [sesion.usuario_id, telegram, nombre, roles, texto(datos, 'telefono') || null],
    );
  } catch (error) {
    const mensaje = error instanceof Error ? error.message : 'Error desconocido';
    return {
      ok: false,
      mensaje: mensaje.includes('usuario_telegram_user_id_key')
        ? 'Ya hay un usuario con ese Telegram.'
        : mensaje,
    };
  }

  revalidatePath('/admin/usuarios');
  return { ok: true, mensaje: `${nombre} ya puede entrar con su Telegram.` };
}

export async function guardarRoles(_previo: Resultado | null, datos: FormData): Promise<Resultado> {
  const sesion = await exigirPermiso('usuarios.gestionar', '/admin/usuarios');
  const roles = datos.getAll('roles').map(String).filter(Boolean);

  const fila = await consultarUna<{ r: Resultado }>(
    'SELECT asignar_roles($1, $2, $3::text[]) AS r',
    [sesion.usuario_id, texto(datos, 'usuario_id'), roles],
  );

  revalidatePath('/admin/usuarios');
  return fila?.r ?? FALLO;
}

export async function cambiarPermiso(_previo: Resultado | null, datos: FormData): Promise<Resultado> {
  const sesion = await exigirPermiso('usuarios.gestionar', '/admin/usuarios');
  const accion = texto(datos, 'accion'); // otorgar | revocar | limpiar

  const fila =
    accion === 'limpiar'
      ? await consultarUna<{ r: Resultado }>('SELECT limpiar_permiso_usuario($1, $2, $3) AS r', [
          sesion.usuario_id,
          texto(datos, 'usuario_id'),
          texto(datos, 'permiso'),
        ])
      : await consultarUna<{ r: Resultado }>(
          'SELECT ajustar_permiso_usuario($1, $2, $3, $4, $5) AS r',
          [
            sesion.usuario_id,
            texto(datos, 'usuario_id'),
            texto(datos, 'permiso'),
            accion === 'otorgar',
            texto(datos, 'motivo') || null,
          ],
        );

  revalidatePath('/admin/usuarios');
  return fila?.r ?? FALLO;
}

export async function cambiarEstadoUsuario(
  _previo: Resultado | null,
  datos: FormData,
): Promise<Resultado> {
  const sesion = await exigirPermiso('usuarios.gestionar', '/admin/usuarios');
  const usuario = texto(datos, 'usuario_id');
  const activar = texto(datos, 'accion') === 'activar';

  try {
    if (activar) {
      await consultarUna('SELECT reactivar_usuario($1, $2) AS r', [sesion.usuario_id, usuario]);
    } else {
      await consultarUna('SELECT desactivar_usuario($1, $2) AS r', [sesion.usuario_id, usuario]);
    }
  } catch (error) {
    return { ok: false, mensaje: error instanceof Error ? error.message : 'Error desconocido' };
  }

  revalidatePath('/admin/usuarios');
  return { ok: true };
}

// --- Configuración ---------------------------------------------------------

export async function guardarConfig(_previo: Resultado | null, datos: FormData): Promise<Resultado> {
  const sesion = await exigirPermiso('config.editar', '/admin/config');

  const fila = await consultarUna<{ r: Resultado }>('SELECT guardar_config($1, $2, $3) AS r', [
    sesion.usuario_id,
    texto(datos, 'clave'),
    texto(datos, 'valor'),
  ]);

  revalidatePath('/admin/config');
  return fila?.r ?? FALLO;
}

export async function guardarTarifa(_previo: Resultado | null, datos: FormData): Promise<Resultado> {
  const sesion = await exigirPermiso('config.editar', '/admin/config');

  const campos = {
    nombre: texto(datos, 'nombre'),
    valor_sugerido: Number(texto(datos, 'valor_sugerido').replace(',', '.')) || 0,
    permite_valor_libre: datos.get('permite_valor_libre') === 'on',
    activa: datos.get('activa') === 'on',
  };

  const fila = await consultarUna<{ r: Resultado }>(
    'SELECT guardar_tarifa($1, $2::uuid, $3::jsonb) AS r',
    [sesion.usuario_id, texto(datos, 'tarifa_id') || null, JSON.stringify(campos)],
  );

  revalidatePath('/admin/config');
  return fila?.r ?? FALLO;
}

// --- Tareas ----------------------------------------------------------------

export async function operarTarea(_previo: Resultado | null, datos: FormData): Promise<Resultado> {
  const sesion = await exigirPermiso('sistema.operar', '/admin/tareas');
  const id = texto(datos, 'tarea_id');

  const fila =
    texto(datos, 'accion') === 'descartar'
      ? await consultarUna<{ r: Resultado }>(
          'SELECT descartar_tarea($1, $2::bigint, $3) AS r',
          [sesion.usuario_id, id, 'Descartada desde el portal'],
        )
      : await consultarUna<{ r: Resultado }>('SELECT reintentar_tarea($1, $2::bigint) AS r', [
          sesion.usuario_id,
          id,
        ]);

  revalidatePath('/admin/tareas');
  return fila?.r ?? FALLO;
}
