'use client';

import { useActionState } from 'react';
import type { Remision } from '@/lib/remisiones';
import type { ResultadoPaciente } from '@/lib/clinico';
import {
  anularRemision,
  cargarResultado,
  crearRemision,
  type Resultado,
} from './acciones';
import estilos from '../vistas.module.css';

/**
 * Piezas interactivas de remisiones (Fase B3).
 *
 * Cliente sólo para mostrar el resultado de la acción sin recargar. Las
 * acciones que cierran o anulan una remisión van dentro de un `<details>`:
 * piden un dato más antes de ejecutarse, así que no se disparan con un toque
 * accidental en la lista.
 */

function Aviso({ estado }: { estado: Resultado | null }) {
  if (!estado) return null;
  return (
    <p className={estado.ok ? estilos.exito : estilos.error} role="status">
      {estado.mensaje ?? (estado.ok ? 'Listo.' : 'No se pudo.')}
    </p>
  );
}

export function AccionesRemision({ remision }: { remision: Remision }) {
  const [resultado, accionResultado, enviandoResultado] = useActionState(cargarResultado, null);
  const [anulada, accionAnular, enviandoAnular] = useActionState(anularRemision, null);

  return (
    <div className={estilos.acciones}>
      <details>
        <summary className={estilos.botonPrimario}>Cargar resultado</summary>
        <form className={estilos.formulario} action={accionResultado}>
          <input type="hidden" name="remision_id" value={remision.remision_id} />
          <div className={estilos.grupo}>
            <label htmlFor={`t-${remision.remision_id}`}>Lo que dice el resultado</label>
            <textarea
              className={estilos.area}
              id={`t-${remision.remision_id}`}
              name="texto"
              rows={4}
              placeholder="Hemograma dentro de parámetros normales…"
            />
            <p className={estilos.ayuda}>
              Si el dueño autorizó el contacto y tiene Telegram, se le avisa que ya
              llegó. Para adjuntar la hoja escaneada, mándala por el bot.
            </p>
          </div>
          <div className={estilos.grupo}>
            <label htmlFor={`u-${remision.remision_id}`}>Enlace al archivo (opcional)</label>
            <input
              className={estilos.campo}
              id={`u-${remision.remision_id}`}
              name="url"
              type="url"
              placeholder="https://…"
            />
          </div>
          <button className={estilos.botonPrimario} type="submit" disabled={enviandoResultado}>
            {enviandoResultado ? '…' : 'Guardar el resultado'}
          </button>
          <Aviso estado={resultado} />
        </form>
      </details>

      {remision.estado === 'pendiente' && (
        <details>
          <summary className={estilos.boton}>Anular</summary>
          <form className={estilos.formulario} action={accionAnular}>
            <input type="hidden" name="remision_id" value={remision.remision_id} />
            <div className={estilos.grupo}>
              <label htmlFor={`m-${remision.remision_id}`}>¿Por qué se anula?</label>
              <input
                className={estilos.campo}
                id={`m-${remision.remision_id}`}
                name="motivo"
                placeholder="El dueño decidió no hacerlo"
              />
            </div>
            <button className={estilos.boton} type="submit" disabled={enviandoAnular}>
              {enviandoAnular ? '…' : 'Anular la remisión'}
            </button>
            <Aviso estado={anulada} />
          </form>
        </details>
      )}
    </div>
  );
}

export function FormularioRemision({
  pacientes,
  fechaEsperada,
}: {
  pacientes: ResultadoPaciente[];
  fechaEsperada: string;
}) {
  const [estado, accion, enviando] = useActionState(crearRemision, null);

  return (
    <form className={estilos.formulario} action={accion}>
      <fieldset className={estilos.grupo}>
        <legend className={estilos.leyenda}>Mascota</legend>
        {pacientes.map((p, i) => (
          <label key={p.paciente_id} className={estilos.filaDetalle}>
            <input
              type="radio"
              name="paciente_id"
              value={p.paciente_id}
              defaultChecked={i === 0}
              required
            />{' '}
            {p.nombre}
            {p.dueno ? ` · ${p.dueno}` : ' · sin dueño'}
          </label>
        ))}
      </fieldset>

      <div className={estilos.rejilla}>
        <div className={estilos.grupo}>
          <label htmlFor="destino">¿A dónde se remite?</label>
          <input
            className={estilos.campo}
            id="destino"
            name="destino"
            required
            placeholder="Laboratorio Veterinario del Norte"
          />
        </div>

        <div className={estilos.grupo}>
          <label htmlFor="tipo-remision">Tipo</label>
          <select
            className={estilos.selector}
            id="tipo-remision"
            name="tipo"
            defaultValue="laboratorio"
          >
            <option value="laboratorio">Laboratorio</option>
            <option value="imagenes">Imágenes</option>
            <option value="especialista">Especialista</option>
            <option value="otro">Otro</option>
          </select>
        </div>
      </div>

      <div className={estilos.grupo}>
        <label htmlFor="examenes">¿Qué se pidió?</label>
        <input
          className={estilos.campo}
          id="examenes"
          name="examenes"
          required
          placeholder="Hemograma y química sanguínea"
        />
      </div>

      <div className={estilos.rejilla}>
        <div className={estilos.grupo}>
          <label htmlFor="fecha-esperada">¿Cuándo debería volver?</label>
          <input
            className={estilos.campo}
            id="fecha-esperada"
            name="fecha_esperada"
            type="date"
            defaultValue={fechaEsperada}
          />
          <p className={estilos.ayuda}>
            Pasada esta fecha, la remisión sale en la alerta de la mañana.
          </p>
        </div>

        <div className={estilos.grupo}>
          <label htmlFor="motivo-remision">Motivo clínico (opcional)</label>
          <input className={estilos.campo} id="motivo-remision" name="motivo" />
        </div>
      </div>

      <button className={estilos.botonPrimario} type="submit" disabled={enviando}>
        {enviando ? 'Registrando…' : 'Registrar la remisión'}
      </button>
      <Aviso estado={estado} />
    </form>
  );
}
