'use client';

import { useActionState } from 'react';
import { guardarConfig, guardarTarifa, type Resultado } from '../acciones';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export interface FilaConfig {
  clave: string;
  valor: string;
  tipo: string;
  descripcion: string | null;
  editable: boolean;
}

export interface FilaTarifa {
  tarifa_id: string;
  codigo: string;
  nombre: string;
  tipo_servicio: string | null;
  valor_sugerido: string;
  permite_valor_libre: boolean;
  activa: boolean;
  usos: string;
}

function mensaje(estado: Resultado | null): string | null {
  if (!estado) return null;
  return estado.ok ? 'Guardado' : (estado.mensaje ?? 'No se pudo');
}

export function FilaParametro({ fila }: { fila: FilaConfig }) {
  const [estado, accion, enviando] = useActionState(guardarConfig, null);

  return (
    <tr className={fila.editable ? undefined : tabla.tenue}>
      <td>
        <code>{fila.clave}</code>
      </td>
      <td>{fila.descripcion ?? '—'}</td>
      <td>
        {fila.editable ? (
          <form className={tabla.enLinea} action={accion}>
            <input type="hidden" name="clave" value={fila.clave} />
            <input
              className={tabla.compacto}
              name="valor"
              defaultValue={fila.valor}
              inputMode={fila.tipo === 'entero' ? 'numeric' : 'text'}
            />
            <button className={tabla.botonCompacto} type="submit" disabled={enviando}>
              {enviando ? '…' : 'Guardar'}
            </button>
            {estado && (
              <span className={estado.ok ? undefined : tabla.peligro}>{mensaje(estado)}</span>
            )}
          </form>
        ) : (
          <>
            {fila.valor}
            <span className={tabla.tenue}> · no editable desde el portal</span>
          </>
        )}
      </td>
    </tr>
  );
}

export function FilaTarifaEditable({ fila }: { fila: FilaTarifa }) {
  const [estado, accion, enviando] = useActionState(guardarTarifa, null);

  return (
    <tr className={fila.activa ? undefined : tabla.tenue}>
      <td>
        <code>{fila.codigo}</code>
      </td>
      <td>{fila.tipo_servicio ?? '—'}</td>
      <td className={tabla.derecha}>{fila.usos}</td>
      <td>
        <form className={tabla.enLinea} action={accion}>
          <input type="hidden" name="tarifa_id" value={fila.tarifa_id} />
          <input className={tabla.compacto} name="nombre" defaultValue={fila.nombre} />
          <input
            className={tabla.compacto}
            type="number"
            name="valor_sugerido"
            min="0"
            step="1"
            defaultValue={Number(fila.valor_sugerido)}
          />
          <label className={tabla.enLinea}>
            <input
              type="checkbox"
              name="permite_valor_libre"
              defaultChecked={fila.permite_valor_libre}
            />
            valor libre
          </label>
          <label className={tabla.enLinea}>
            <input type="checkbox" name="activa" defaultChecked={fila.activa} />
            activa
          </label>
          <button className={tabla.botonCompacto} type="submit" disabled={enviando}>
            {enviando ? '…' : 'Guardar'}
          </button>
          {estado && (
            <span className={estado.ok ? undefined : tabla.peligro}>{mensaje(estado)}</span>
          )}
        </form>
      </td>
    </tr>
  );
}

/** Alta de tarifa. Sin `tarifa_id`, la misma función SQL crea en vez de editar. */
export function NuevaTarifa() {
  const [estado, accion, enviando] = useActionState(guardarTarifa, null);

  return (
    <form className={estilos.bloque} action={accion} style={{ marginTop: '1rem' }}>
      <p className={estilos.leyenda}>Tarifa nueva</p>
      <div className={tabla.enLinea}>
        <input className={estilos.campo} name="nombre" placeholder="Nombre del cobro" required />
        <input
          className={estilos.campo}
          type="number"
          name="valor_sugerido"
          min="0"
          step="1"
          defaultValue={0}
        />
        <label className={tabla.enLinea}>
          <input type="checkbox" name="permite_valor_libre" />
          el valor se escribe al cobrar
        </label>
        <input type="hidden" name="activa" value="on" />
        <button className={estilos.botonPrimario} type="submit" disabled={enviando}>
          {enviando ? 'Creando…' : 'Crear'}
        </button>
      </div>
      {estado && !estado.ok && <p className={estilos.error}>{estado.mensaje}</p>}
    </form>
  );
}
