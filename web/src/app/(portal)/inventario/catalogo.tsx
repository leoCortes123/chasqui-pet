'use client';

import { useActionState, useState } from 'react';
import { guardarMedicamento } from './acciones';
import estilos from '../vistas.module.css';
import tabla from '../admin.module.css';

export interface FilaCatalogo {
  medicamento_id: string;
  nombre_generico: string;
  nombre_comercial: string | null;
  presentacion: string | null;
  concentracion: string | null;
  categoria: string | null;
  unidad_base: string;
  requiere_receta: boolean;
  precio_venta: string;
  stock_minimo: string;
  disponible: string;
  costo_ultimo: string | null;
  activo: boolean;
}

const UNIDADES = ['ml', 'mg', 'tableta', 'unidad', 'dosis'];

/**
 * Edición del catálogo en la misma tabla (§11.2: «alta y edición
 * masiva»). Cada fila es un formulario independiente: se corrigen diez
 * precios seguidos sin abrir diez pantallas, y un error en uno no pierde
 * los otros nueve.
 */
export function Catalogo({
  filas,
  puedeEditar,
}: {
  filas: FilaCatalogo[];
  puedeEditar: boolean;
}) {
  const [nuevo, setNuevo] = useState(false);

  return (
    <>
      {puedeEditar && (
        <div className={tabla.filtros}>
          <button className={estilos.boton} type="button" onClick={() => setNuevo((v) => !v)}>
            {nuevo ? 'Cancelar' : '+ Medicamento nuevo'}
          </button>
        </div>
      )}

      {nuevo && <FormularioNuevo alTerminar={() => setNuevo(false)} />}

      <div className={tabla.desplazable}>
        <table className={tabla.tabla}>
          <thead>
            <tr>
              <th>Medicamento</th>
              <th>Presentación</th>
              <th>Unidad</th>
              <th className={tabla.derecha}>Existencia</th>
              <th className={tabla.derecha}>Último costo</th>
              <th className={tabla.derecha}>Precio</th>
              <th className={tabla.derecha}>Mínimo</th>
              <th>Activo</th>
              {puedeEditar && <th />}
            </tr>
          </thead>
          <tbody>
            {filas.map((f) => (
              <Fila key={f.medicamento_id} fila={f} puedeEditar={puedeEditar} />
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}

function Fila({ fila, puedeEditar }: { fila: FilaCatalogo; puedeEditar: boolean }) {
  const [estado, accion, enviando] = useActionState(guardarMedicamento, null);
  const idForm = `med-${fila.medicamento_id}`;

  return (
    <tr className={fila.activo ? undefined : tabla.tenue}>
      <td>
        <strong>{fila.nombre_generico}</strong>
        {fila.nombre_comercial ? ` (${fila.nombre_comercial})` : ''}
        {fila.requiere_receta ? ' 📄' : ''}
        {estado && !estado.ok && (
          <div className={tabla.tarjetaDetalle} style={{ color: '#ff9d92' }}>
            {estado.mensaje}
          </div>
        )}
      </td>
      <td>{[fila.presentacion, fila.concentracion].filter(Boolean).join(' · ') || '—'}</td>
      <td>{fila.unidad_base}</td>
      <td className={tabla.derecha}>{Number(fila.disponible).toLocaleString('es-CO')}</td>
      <td className={tabla.derecha}>
        {fila.costo_ultimo ? Number(fila.costo_ultimo).toLocaleString('es-CO') : '—'}
      </td>
      <td className={tabla.derecha}>
        {puedeEditar ? (
          <>
            <form id={idForm} action={accion} />
            <input type="hidden" name="medicamento_id" value={fila.medicamento_id} form={idForm} />
            <input
              className={tabla.compacto}
              type="number"
              name="precio_venta"
              step="1"
              min="0"
              defaultValue={Number(fila.precio_venta)}
              form={idForm}
            />
          </>
        ) : (
          Number(fila.precio_venta).toLocaleString('es-CO')
        )}
      </td>
      <td className={tabla.derecha}>
        {puedeEditar ? (
          <input
            className={tabla.compacto}
            type="number"
            name="stock_minimo"
            step="0.001"
            min="0"
            defaultValue={Number(fila.stock_minimo)}
            form={idForm}
          />
        ) : (
          Number(fila.stock_minimo).toLocaleString('es-CO')
        )}
      </td>
      <td>
        {puedeEditar ? (
          <input type="checkbox" name="activo" defaultChecked={fila.activo} form={idForm} />
        ) : fila.activo ? (
          'sí'
        ) : (
          'no'
        )}
      </td>
      {puedeEditar && (
        <td>
          <button className={tabla.botonCompacto} type="submit" form={idForm} disabled={enviando}>
            {enviando ? 'Guardando…' : 'Guardar'}
          </button>
        </td>
      )}
    </tr>
  );
}

function FormularioNuevo({ alTerminar }: { alTerminar: () => void }) {
  const [estado, accion, enviando] = useActionState(guardarMedicamento, null);

  if (estado?.ok) {
    // El listado ya se revalidó en el servidor; sólo hay que cerrar.
    queueMicrotask(alTerminar);
  }

  return (
    <form className={estilos.bloque} action={accion} style={{ marginBottom: '1.5rem' }}>
      <div className={estilos.rejilla}>
        <label className={estilos.grupo}>
          Nombre genérico
          <input className={estilos.campo} name="nombre_generico" required />
        </label>
        <label className={estilos.grupo}>
          Nombre comercial
          <input className={estilos.campo} name="nombre_comercial" />
        </label>
        <label className={estilos.grupo}>
          Presentación
          <input className={estilos.campo} name="presentacion" placeholder="frasco 100 ml" />
        </label>
        <label className={estilos.grupo}>
          Concentración
          <input className={estilos.campo} name="concentracion" placeholder="50 mg/ml" />
        </label>
        <label className={estilos.grupo}>
          Categoría
          <input className={estilos.campo} name="categoria" placeholder="Antibiótico" />
        </label>
        <label className={estilos.grupo}>
          Unidad
          <select className={estilos.selector} name="unidad_base" defaultValue="unidad">
            {UNIDADES.map((u) => (
              <option key={u} value={u}>
                {u}
              </option>
            ))}
          </select>
        </label>
        <label className={estilos.grupo}>
          Precio de venta
          <input className={estilos.campo} type="number" name="precio_venta" min="0" step="1" defaultValue={0} />
        </label>
        <label className={estilos.grupo}>
          Stock mínimo
          <input className={estilos.campo} type="number" name="stock_minimo" min="0" step="0.001" defaultValue={0} />
        </label>
      </div>

      <label className={estilos.grupo} style={{ flexDirection: 'row', gap: '0.5rem', marginTop: '0.75rem' }}>
        <input type="checkbox" name="requiere_receta" />
        Requiere receta
      </label>

      {estado && !estado.ok && <p className={estilos.error}>{estado.mensaje}</p>}

      <div className={estilos.acciones}>
        <button className={estilos.botonPrimario} type="submit" disabled={enviando}>
          {enviando ? 'Creando…' : 'Crear medicamento'}
        </button>
        <button className={estilos.boton} type="button" onClick={alTerminar}>
          Cancelar
        </button>
      </div>
    </form>
  );
}
