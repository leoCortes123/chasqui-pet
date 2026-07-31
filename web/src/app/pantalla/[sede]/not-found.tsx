import estilos from './no-encontrada.module.css';

/** 404 de la pantalla: sede inexistente, inactiva o identificador mal escrito. */
export default function SedeNoEncontrada() {
  return (
    <main className={estilos.contenedor}>
      <p className={estilos.codigo}>404</p>
      <h1 className={estilos.titulo}>Sede no encontrada</h1>
      <p className={estilos.detalle}>
        La sede solicitada no existe o está inactiva. Verifique el enlace del
        monitor: debe ser <code className={estilos.codigoUrl}>/pantalla/</code>{' '}
        seguido del identificador de la sede.
      </p>
    </main>
  );
}
