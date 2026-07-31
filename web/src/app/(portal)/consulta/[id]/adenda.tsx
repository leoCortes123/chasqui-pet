'use client';

import { useActionState } from 'react';
import { ESTADO_INICIAL, guardarFormulario } from './acciones';
import estilos from '../../vistas.module.css';

/**
 * Corrección de una consulta ya firmada (§8.2.4): no se edita, se le añade.
 * La adenda queda con el nombre de quien la escribe y la hora.
 */
export default function Adenda({ consultaId }: { consultaId: string }) {
  const [estado, accion] = useActionState(guardarFormulario, ESTADO_INICIAL);

  return (
    <form className={estilos.formulario} action={accion} style={{ marginTop: '1.5rem' }}>
      <input type="hidden" name="consulta_id" value={consultaId} />
      <input type="hidden" name="accion" value="adenda" />

      {estado.mensaje && (
        <p className={estado.ok ? estilos.exito : estilos.error}>{estado.mensaje}</p>
      )}

      <div className={estilos.grupo}>
        <label htmlFor="texto">Agregar una adenda</label>
        <span className={estilos.ayuda}>
          Lo firmado no se modifica. Escribe aquí la corrección o el dato que faltó.
        </span>
        <textarea className={estilos.area} id="texto" name="texto" required />
      </div>

      <div className={estilos.acciones}>
        <button className={estilos.botonPrimario} type="submit">
          Agregar adenda
        </button>
      </div>
    </form>
  );
}
