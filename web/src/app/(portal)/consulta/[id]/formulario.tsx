'use client';

import { useActionState } from 'react';
import { useFormStatus } from 'react-dom';
import type { Consulta, Opcion } from '@/lib/clinico';
import { ESTADO_INICIAL, guardarFormulario } from './acciones';
import estilos from '../../vistas.module.css';

/**
 * Formulario completo de consulta (§8.2.5): el mismo contenido que el bot
 * pregunta paso a paso, aquí todo a la vista.
 *
 * Guardar y firmar son dos botones distintos del mismo formulario. El borrador
 * se guarda con lo que haya; firmar exige motivo, diagnóstico y tratamiento, y
 * quien decide eso es Postgres, no esta pantalla.
 */
export default function FormularioConsulta({
  consulta,
  opciones,
  puedeFirmar,
}: {
  consulta: Consulta;
  opciones: { mucosas: Opcion[]; hidratacion: Opcion[]; cc: Opcion[] };
  puedeFirmar: boolean;
}) {
  const [estado, accion] = useActionState(guardarFormulario, ESTADO_INICIAL);
  const examen = consulta.examen_fisico ?? {};

  return (
    <form className={estilos.formulario} action={accion}>
      <input type="hidden" name="consulta_id" value={consulta.consulta_id} />

      {estado.mensaje && (
        <p className={estado.ok ? estilos.exito : estilos.error}>{estado.mensaje}</p>
      )}

      <div className={estilos.grupo}>
        <label htmlFor="motivo_consulta">Motivo de la consulta</label>
        <span className={estilos.ayuda}>Obligatorio para firmar.</span>
        <textarea
          className={estilos.area}
          id="motivo_consulta"
          name="motivo_consulta"
          defaultValue={consulta.motivo_consulta ?? ''}
          placeholder="¿Por qué lo traen?"
        />
      </div>

      <div className={estilos.grupo}>
        <label htmlFor="anamnesis">Anamnesis</label>
        <span className={estilos.ayuda}>Lo que cuenta el dueño. Opcional.</span>
        <textarea
          className={estilos.area}
          id="anamnesis"
          name="anamnesis"
          defaultValue={consulta.anamnesis ?? ''}
        />
      </div>

      <fieldset className={estilos.bloque}>
        <legend className={estilos.leyenda}>Examen físico</legend>
        <div className={estilos.rejilla}>
          <Numero nombre="peso_kg" etiqueta="Peso (kg)" valor={examen.peso_kg} paso="0.01" />
          <Numero
            nombre="temperatura_c"
            etiqueta="Temperatura (°C)"
            valor={examen.temperatura_c}
            paso="0.1"
          />
          <Numero nombre="fc" etiqueta="FC (lpm)" valor={examen.fc} paso="1" />
          <Numero nombre="fr" etiqueta="FR (rpm)" valor={examen.fr} paso="1" />
          <Numero nombre="tllc_seg" etiqueta="TLLC (s)" valor={examen.tllc_seg} paso="0.1" />
          <Lista
            nombre="mucosas"
            etiqueta="Mucosas"
            opciones={opciones.mucosas}
            valor={examen.mucosas}
          />
          <Lista
            nombre="hidratacion"
            etiqueta="Hidratación"
            opciones={opciones.hidratacion}
            valor={examen.hidratacion}
          />
          <Lista
            nombre="cc"
            etiqueta="Condición corporal"
            opciones={opciones.cc}
            valor={examen.cc}
          />
        </div>
      </fieldset>

      <div className={estilos.grupo}>
        <label htmlFor="diagnostico_presuntivo">Diagnóstico presuntivo</label>
        <span className={estilos.ayuda}>
          Para firmar hace falta al menos uno de los dos diagnósticos.
        </span>
        <textarea
          className={estilos.area}
          id="diagnostico_presuntivo"
          name="diagnostico_presuntivo"
          defaultValue={consulta.diagnostico_presuntivo ?? ''}
        />
      </div>

      <div className={estilos.grupo}>
        <label htmlFor="diagnostico_definitivo">Diagnóstico definitivo</label>
        <textarea
          className={estilos.area}
          id="diagnostico_definitivo"
          name="diagnostico_definitivo"
          defaultValue={consulta.diagnostico_definitivo ?? ''}
        />
      </div>

      <div className={estilos.grupo}>
        <label htmlFor="plan_tratamiento">Plan de tratamiento</label>
        <span className={estilos.ayuda}>Obligatorio para firmar.</span>
        <textarea
          className={estilos.area}
          id="plan_tratamiento"
          name="plan_tratamiento"
          defaultValue={consulta.plan_tratamiento ?? ''}
        />
      </div>

      <div className={estilos.grupo}>
        <label htmlFor="recomendaciones">Recomendaciones para la casa</label>
        <span className={estilos.ayuda}>
          Es lo que se le envía al dueño por Telegram al firmar, si dio su
          consentimiento.
        </span>
        <textarea
          className={estilos.area}
          id="recomendaciones"
          name="recomendaciones"
          defaultValue={consulta.recomendaciones ?? ''}
        />
      </div>

      <div className={estilos.grupo}>
        <label htmlFor="remision_externa">Remisión externa</label>
        <span className={estilos.ayuda}>Qué examen se solicitó y a dónde.</span>
        <textarea
          className={estilos.area}
          id="remision_externa"
          name="remision_externa"
          defaultValue={consulta.remision_externa ?? ''}
        />
      </div>

      <div className={estilos.grupo}>
        <label htmlFor="proxima_revision">Próxima revisión</label>
        <input
          className={estilos.campo}
          id="proxima_revision"
          name="proxima_revision"
          type="date"
          defaultValue={consulta.proxima_revision ?? ''}
        />
      </div>

      <Botones puedeFirmar={puedeFirmar} />
    </form>
  );
}

function Botones({ puedeFirmar }: { puedeFirmar: boolean }) {
  const { pending } = useFormStatus();

  return (
    <div className={estilos.acciones}>
      <button
        className={estilos.boton}
        type="submit"
        name="accion"
        value="guardar"
        disabled={pending}
      >
        {pending ? 'Guardando…' : 'Guardar borrador'}
      </button>
      {puedeFirmar && (
        <button
          className={estilos.botonPrimario}
          type="submit"
          name="accion"
          value="firmar"
          disabled={pending}
        >
          Guardar y firmar
        </button>
      )}
      <span className={estilos.ayuda}>
        Mientras esté en borrador no es registro clínico válido.
      </span>
    </div>
  );
}

function Numero({
  nombre,
  etiqueta,
  valor,
  paso,
}: {
  nombre: string;
  etiqueta: string;
  valor: string | number | undefined;
  paso: string;
}) {
  return (
    <div className={estilos.grupo}>
      <label htmlFor={nombre}>{etiqueta}</label>
      <input
        className={estilos.campo}
        id={nombre}
        name={`examen.${nombre}`}
        type="number"
        step={paso}
        inputMode="decimal"
        defaultValue={valor ?? ''}
      />
    </div>
  );
}

function Lista({
  nombre,
  etiqueta,
  opciones,
  valor,
}: {
  nombre: string;
  etiqueta: string;
  opciones: Opcion[];
  valor: string | number | undefined;
}) {
  return (
    <div className={estilos.grupo}>
      <label htmlFor={nombre}>{etiqueta}</label>
      <select
        className={estilos.selector}
        id={nombre}
        name={`examen.${nombre}`}
        defaultValue={valor ? String(valor) : ''}
      >
        <option value="">Sin registrar</option>
        {opciones.map((o) => (
          <option key={o.v} value={o.v}>
            {o.t}
          </option>
        ))}
      </select>
    </div>
  );
}
