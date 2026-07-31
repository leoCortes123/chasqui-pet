'use client';

import { useActionState } from 'react';
import { operarTarea } from '../acciones';
import tabla from '../../admin.module.css';

/**
 * Reintentar es devolver la tarea a la cola con el contador a cero.
 * Descartar la da por perdida y la saca de la bandeja, dejando el hecho
 * en la auditoría. No hay «editar el payload»: si el contenido está mal,
 * se descarta y se vuelve a provocar desde donde salió.
 */
export function AccionesTarea({ tareaId, procesando }: { tareaId: string; procesando: boolean }) {
  const [estado, accion, enviando] = useActionState(operarTarea, null);

  return (
    <form className={tabla.enLinea} action={accion}>
      <input type="hidden" name="tarea_id" value={tareaId} />
      <button
        className={tabla.botonCompacto}
        type="submit"
        name="accion"
        value="reintentar"
        disabled={enviando || procesando}
      >
        Reintentar
      </button>
      <button
        className={`${tabla.botonCompacto} ${tabla.peligro}`}
        type="submit"
        name="accion"
        value="descartar"
        disabled={enviando || procesando}
      >
        Descartar
      </button>
      {estado && !estado.ok && <span className={tabla.peligro}>{estado.mensaje}</span>}
    </form>
  );
}
