'use client';

import { useActionState } from 'react';
import type { Cita, ControlPendiente, Cupo, TipoServicio } from '@/lib/agenda';
import type { ResultadoPaciente } from '@/lib/clinico';
import {
  agendarCita,
  agendarControl,
  cancelarCita,
  registrarLlegada,
  reprogramarCita,
  type Resultado,
} from './acciones';
import estilos from '../vistas.module.css';

/**
 * Las piezas interactivas de la agenda (Fase B1b).
 *
 * Son cliente por una sola razón: mostrar el resultado de la acción sin
 * recargar y sin perder lo escrito. Nada se decide aquí — cada formulario
 * llama a su server action, que llama a la función SQL, que vuelve a exigir
 * el permiso.
 *
 * Las acciones destructivas (cancelar, reprogramar) van dentro de un
 * `<details>`: piden un dato más antes de ejecutarse, así que no se disparan
 * con un toque accidental en la lista.
 */

function Aviso({ estado }: { estado: Resultado | null }) {
  if (!estado) return null;
  return (
    <p className={estado.ok ? estilos.exito : estilos.error} role="status">
      {estado.mensaje ?? (estado.ok ? 'Listo.' : 'No se pudo.')}
    </p>
  );
}

export function AccionesCita({ cita }: { cita: Cita }) {
  const [llegada, accionLlegada, enviandoLlegada] = useActionState(registrarLlegada, null);
  const [cancel, accionCancelar, enviandoCancelar] = useActionState(cancelarCita, null);
  const [reprog, accionReprogramar, enviandoReprog] = useActionState(reprogramarCita, null);

  return (
    <div className={estilos.acciones}>
      <form action={accionLlegada}>
        <input type="hidden" name="cita_id" value={cita.cita_id} />
        <button className={estilos.botonPrimario} type="submit" disabled={enviandoLlegada}>
          {enviandoLlegada ? '…' : 'Llegó'}
        </button>
      </form>

      <details>
        <summary className={estilos.boton}>Reprogramar</summary>
        <form className={estilos.formulario} action={accionReprogramar}>
          <input type="hidden" name="cita_id" value={cita.cita_id} />
          <div className={estilos.grupo}>
            <label htmlFor={`f-${cita.cita_id}`}>Fecha nueva</label>
            <input
              className={estilos.campo}
              id={`f-${cita.cita_id}`}
              type="date"
              name="fecha"
              defaultValue={cita.fecha}
              required
            />
          </div>
          <div className={estilos.grupo}>
            <label htmlFor={`h-${cita.cita_id}`}>Hora nueva</label>
            <input
              className={estilos.campo}
              id={`h-${cita.cita_id}`}
              type="time"
              name="hora"
              defaultValue={cita.hora}
              required
            />
          </div>
          <div className={estilos.grupo}>
            <label htmlFor={`mr-${cita.cita_id}`}>Motivo (opcional)</label>
            <input className={estilos.campo} id={`mr-${cita.cita_id}`} name="motivo" />
          </div>
          <button className={estilos.botonPrimario} type="submit" disabled={enviandoReprog}>
            {enviandoReprog ? '…' : 'Mover la cita'}
          </button>
          <Aviso estado={reprog} />
        </form>
      </details>

      <details>
        <summary className={estilos.boton}>Cancelar</summary>
        <form className={estilos.formulario} action={accionCancelar}>
          <input type="hidden" name="cita_id" value={cita.cita_id} />
          <div className={estilos.grupo}>
            <label htmlFor={`mc-${cita.cita_id}`}>¿Por qué se cancela?</label>
            <input
              className={estilos.campo}
              id={`mc-${cita.cita_id}`}
              name="motivo"
              placeholder="El dueño no puede venir"
            />
            <p className={estilos.ayuda}>
              Queda registrado con la cita. La cita no se borra.
            </p>
          </div>
          <button className={estilos.boton} type="submit" disabled={enviandoCancelar}>
            {enviandoCancelar ? '…' : 'Cancelar la cita'}
          </button>
          <Aviso estado={cancel} />
        </form>
      </details>

      <Aviso estado={llegada} />
    </div>
  );
}

/**
 * Un control por agendar (Fase B2). El botón agenda con la fecha que anotó
 * el veterinario y la hora que proponga la base; para moverlo, se usa
 * «Reprogramar» sobre la cita ya creada, que es el camino que ya existe.
 */
export function BotonAgendarControl({ control }: { control: ControlPendiente }) {
  const [estado, accion, enviando] = useActionState(agendarControl, null);

  return (
    <form className={estilos.acciones} action={accion}>
      <input type="hidden" name="consulta_id" value={control.consulta_id} />
      <button className={estilos.botonPrimario} type="submit" disabled={enviando}>
        {enviando ? '…' : `Agendar el ${control.fecha_control.slice(8, 10)}/${control.fecha_control.slice(5, 7)}`}
      </button>
      <Aviso estado={estado} />
    </form>
  );
}

export function FormularioAgendar({
  fecha,
  pacientes,
  tipos,
  cupos,
  horaElegida,
  veterinarioElegido,
}: {
  fecha: string;
  pacientes: ResultadoPaciente[];
  tipos: TipoServicio[];
  cupos: Cupo[];
  horaElegida: string | null;
  veterinarioElegido: string | null;
}) {
  const [estado, accion, enviando] = useActionState(agendarCita, null);

  return (
    <form className={estilos.formulario} action={accion}>
      <input type="hidden" name="fecha" value={fecha} />
      {veterinarioElegido && (
        <input type="hidden" name="veterinario_id" value={veterinarioElegido} />
      )}

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
          <label htmlFor="hora-nueva">Hora</label>
          <input
            className={estilos.campo}
            id="hora-nueva"
            type="time"
            name="hora"
            defaultValue={horaElegida ?? cupos[0]?.hora ?? '09:00'}
            required
          />
          <p className={estilos.ayuda}>
            {cupos.length > 0
              ? 'Elige un cupo libre de arriba o escribe otra hora.'
              : 'No hay franja declarada ese día: escribe la hora que necesites.'}
          </p>
        </div>

        <div className={estilos.grupo}>
          <label htmlFor="tipo-cita">Servicio</label>
          <select className={estilos.selector} id="tipo-cita" name="tipo" defaultValue="general">
            {tipos.map((t) => (
              <option key={t.codigo} value={t.codigo}>
                {t.nombre} ({t.duracion_estimada_min} min)
              </option>
            ))}
          </select>
        </div>
      </div>

      <div className={estilos.grupo}>
        <label htmlFor="notas-cita">Nota (opcional)</label>
        <input
          className={estilos.campo}
          id="notas-cita"
          name="notas"
          placeholder="Control posoperatorio"
        />
      </div>

      <button className={estilos.botonPrimario} type="submit" disabled={enviando}>
        {enviando ? 'Agendando…' : 'Agendar cita'}
      </button>
      <Aviso estado={estado} />
    </form>
  );
}
