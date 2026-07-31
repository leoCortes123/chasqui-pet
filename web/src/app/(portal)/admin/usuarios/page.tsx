import type { Metadata } from 'next';
import Link from 'next/link';
import { consultar } from '@/lib/db';
import { exigirPermiso } from '@/lib/sesion';
import { AltaUsuario, FilaUsuario, type Permiso, type Rol, type Usuario } from './gestion';
import estilos from '../../vistas.module.css';
import tabla from '../../admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Usuarios — Chasqui Pet',
  robots: { index: false, follow: false },
};

export default async function PaginaUsuarios() {
  const sesion = await exigirPermiso('usuarios.gestionar', '/admin/usuarios');

  const [usuarios, roles, permisos] = await Promise.all([
    consultar<Usuario>('SELECT * FROM usuarios_listado()'),
    consultar<Rol>('SELECT codigo, nombre, descripcion FROM roles_disponibles()'),
    consultar<Permiso>('SELECT codigo, modulo, descripcion FROM permisos_disponibles()'),
  ]);

  return (
    <>
      <p className={tabla.migaja}>
        <Link href="/admin">← Administración</Link>
      </p>
      <h1 className={estilos.titulo}>Usuarios</h1>
      <p className={estilos.subtitulo}>
        Quién puede hacer qué son datos, no código: cambiarlo es un guardar, no un
        despliegue.
      </p>

      <AltaUsuario roles={roles} />

      <div className={tabla.desplazable}>
        <table className={tabla.tabla}>
          <thead>
            <tr>
              <th>Nombre</th>
              <th>Telegram</th>
              <th>Roles</th>
              <th>Permisos extra</th>
              <th>Sesiones</th>
              <th>Estado</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {usuarios.map((u) => (
              <FilaUsuario
                key={u.usuario_id}
                usuario={u}
                roles={roles}
                permisos={permisos}
                yo={u.usuario_id === sesion.usuario_id}
              />
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
