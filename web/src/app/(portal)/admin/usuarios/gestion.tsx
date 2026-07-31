'use client';

import { useActionState, useState } from 'react';
import {
  cambiarEstadoUsuario,
  cambiarPermiso,
  crearUsuario,
  guardarRoles,
  type Resultado,
} from '../acciones';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export interface Usuario {
  usuario_id: string;
  nombre: string;
  telegram_user_id: string;
  telefono: string | null;
  roles: string[];
  permisos_extra: string[];
  activo: boolean;
  ultimo_acceso: string | null;
  sesiones: string;
}

export interface Rol {
  codigo: string;
  nombre: string;
  descripcion: string;
}

export interface Permiso {
  codigo: string;
  modulo: string;
  descripcion: string;
}

function Aviso({ estado }: { estado: Resultado | null }) {
  if (!estado) return null;
  return (
    <p className={estado.ok ? estilos.exito : estilos.error} style={{ marginTop: '0.5rem' }}>
      {estado.mensaje ?? (estado.ok ? 'Listo.' : 'No se pudo.')}
    </p>
  );
}

/** Alta de personal: la única forma de que alguien exista (§4). */
export function AltaUsuario({ roles }: { roles: Rol[] }) {
  const [estado, accion, enviando] = useActionState(crearUsuario, null);
  const [abierto, setAbierto] = useState(false);

  if (!abierto) {
    return (
      <div className={tabla.filtros}>
        <button className={estilos.botonPrimario} type="button" onClick={() => setAbierto(true)}>
          + Dar acceso a alguien
        </button>
      </div>
    );
  }

  return (
    <form className={estilos.bloque} action={accion} style={{ marginBottom: '1.5rem' }}>
      <p className={estilos.ayuda}>
        Nadie se autoregistra. El id de Telegram lo da <strong>@userinfobot</strong>: que
        la persona le escriba y copie el número que responde.
      </p>

      <div className={estilos.rejilla}>
        <label className={estilos.grupo}>
          Nombre completo
          <input className={estilos.campo} name="nombre" required />
        </label>
        <label className={estilos.grupo}>
          Id de Telegram
          <input className={estilos.campo} name="telegram_user_id" inputMode="numeric" required />
        </label>
        <label className={estilos.grupo}>
          Teléfono
          <input className={estilos.campo} name="telefono" />
        </label>
      </div>

      <fieldset className={estilos.bloque} style={{ marginTop: '0.75rem' }}>
        <legend className={estilos.leyenda}>Roles</legend>
        {roles.map((r) => (
          <label key={r.codigo} className={tabla.enLinea} style={{ marginTop: '0.35rem' }}>
            <input type="checkbox" name="roles" value={r.codigo} />
            <strong>{r.nombre}</strong>
            <span className={tabla.tenue}>{r.descripcion}</span>
          </label>
        ))}
      </fieldset>

      <Aviso estado={estado} />

      <div className={estilos.acciones}>
        <button className={estilos.botonPrimario} type="submit" disabled={enviando}>
          {enviando ? 'Creando…' : 'Crear usuario'}
        </button>
        <button className={estilos.boton} type="button" onClick={() => setAbierto(false)}>
          Cerrar
        </button>
      </div>
    </form>
  );
}

export function FilaUsuario({
  usuario,
  roles,
  permisos,
  yo,
}: {
  usuario: Usuario;
  roles: Rol[];
  permisos: Permiso[];
  yo: boolean;
}) {
  const [abierto, setAbierto] = useState(false);
  const [estadoRoles, accionRoles, guardandoRoles] = useActionState(guardarRoles, null);
  const [estadoPermiso, accionPermiso, guardandoPermiso] = useActionState(cambiarPermiso, null);
  const [, accionEstado, cambiandoEstado] = useActionState(cambiarEstadoUsuario, null);

  return (
    <>
      <tr className={usuario.activo ? undefined : tabla.tenue}>
        <td>
          <strong>{usuario.nombre}</strong>
          {yo && <span className={tabla.tenue}> · tú</span>}
        </td>
        <td>{usuario.telegram_user_id}</td>
        <td>{usuario.roles.join(', ') || '—'}</td>
        <td>{usuario.permisos_extra.join(', ') || '—'}</td>
        <td>{usuario.sesiones}</td>
        <td>{usuario.activo ? 'activo' : 'inactivo'}</td>
        <td>
          <div className={tabla.enLinea}>
            <button className={tabla.botonCompacto} type="button" onClick={() => setAbierto((v) => !v)}>
              {abierto ? 'Cerrar' : 'Editar'}
            </button>
            {!yo && (
              <form action={accionEstado}>
                <input type="hidden" name="usuario_id" value={usuario.usuario_id} />
                <input
                  type="hidden"
                  name="accion"
                  value={usuario.activo ? 'desactivar' : 'activar'}
                />
                <button
                  className={`${tabla.botonCompacto} ${usuario.activo ? tabla.peligro : ''}`}
                  type="submit"
                  disabled={cambiandoEstado}
                >
                  {usuario.activo ? 'Desactivar' : 'Reactivar'}
                </button>
              </form>
            )}
          </div>
        </td>
      </tr>

      {abierto && (
        <tr>
          <td colSpan={7}>
            <div className={estilos.rejilla} style={{ gridTemplateColumns: '1fr 1fr' }}>
              <form className={estilos.bloque} action={accionRoles}>
                <input type="hidden" name="usuario_id" value={usuario.usuario_id} />
                <p className={estilos.leyenda}>Roles</p>
                {roles.map((r) => (
                  <label key={r.codigo} className={tabla.enLinea} style={{ marginTop: '0.3rem' }}>
                    <input
                      type="checkbox"
                      name="roles"
                      value={r.codigo}
                      defaultChecked={usuario.roles.includes(r.codigo)}
                    />
                    {r.nombre}
                  </label>
                ))}
                <Aviso estado={estadoRoles} />
                <button
                  className={estilos.botonPrimario}
                  type="submit"
                  disabled={guardandoRoles}
                  style={{ marginTop: '0.75rem' }}
                >
                  {guardandoRoles ? 'Guardando…' : 'Guardar roles'}
                </button>
              </form>

              <form className={estilos.bloque} action={accionPermiso}>
                <input type="hidden" name="usuario_id" value={usuario.usuario_id} />
                <p className={estilos.leyenda}>Permiso individual</p>
                <p className={estilos.ayuda}>
                  La excepción de §4: el auxiliar al que se le habilitan descuentos o
                  entradas de inventario, sin inventar un rol nuevo.
                </p>
                <label className={estilos.grupo}>
                  Permiso
                  <select className={estilos.selector} name="permiso">
                    {permisos.map((p) => (
                      <option key={p.codigo} value={p.codigo}>
                        {p.modulo} · {p.codigo}
                      </option>
                    ))}
                  </select>
                </label>
                <label className={estilos.grupo}>
                  Motivo
                  <input className={estilos.campo} name="motivo" placeholder="Queda en la auditoría" />
                </label>
                <Aviso estado={estadoPermiso} />
                <div className={tabla.enLinea} style={{ marginTop: '0.75rem' }}>
                  <button
                    className={tabla.botonCompacto}
                    type="submit"
                    name="accion"
                    value="otorgar"
                    disabled={guardandoPermiso}
                  >
                    Otorgar
                  </button>
                  <button
                    className={`${tabla.botonCompacto} ${tabla.peligro}`}
                    type="submit"
                    name="accion"
                    value="revocar"
                    disabled={guardandoPermiso}
                  >
                    Revocar
                  </button>
                  <button
                    className={tabla.botonCompacto}
                    type="submit"
                    name="accion"
                    value="limpiar"
                    disabled={guardandoPermiso}
                  >
                    Dejar como el rol
                  </button>
                </div>
              </form>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}
