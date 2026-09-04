'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useEffect, useRef } from 'react';
import estilos from './portal.module.css';

/**
 * Navegación del portal (§11.2).
 *
 * Es cliente por una sola razón: marcar la sección actual con `aria-current`
 * necesita la ruta del navegador. Los enlaces los decide el servidor a partir
 * de los permisos reales de la sesión (ver `layout.tsx`); aquí no se decide
 * nada, sólo se pinta.
 *
 * Dos formas del mismo menú:
 *  - Celular: barra fija al alcance del pulgar con los cuatro destinos más
 *    usados y un «Más» para el resto. El portal se consulta de pie, en
 *    consulta, con una mano.
 *  - Escritorio: fila horizontal en la cabecera.
 * No se duplica el HTML por gusto: la barra inferior necesita icono sobre
 * etiqueta y la superior no, y hacerlo con una sola lista obligaba a esconder
 * y reordenar nodos con CSS, que es peor para el lector de pantalla.
 */

export interface Enlace {
  href: string;
  texto: string;
  /** Emoji decorativo: va con aria-hidden, la etiqueta ya nombra el destino. */
  icono: string;
}

/** Cuántos destinos caben en la barra inferior antes de «Más». */
const VISIBLES_MOVIL = 4;

/** Marca la sección: `/pacientes/abc` sigue siendo «Pacientes». */
function esActual(ruta: string, href: string): boolean {
  if (href === '/') return ruta === '/';
  return ruta === href || ruta.startsWith(`${href}/`);
}

export function NavegacionEscritorio({ enlaces }: { enlaces: Enlace[] }) {
  const ruta = usePathname();

  return (
    <nav className={estilos.navEscritorio} aria-label="Secciones">
      <ul className={estilos.navLista}>
        {enlaces.map((e) => {
          const actual = esActual(ruta, e.href);
          return (
            <li key={e.href}>
              <Link
                href={e.href}
                className={estilos.navEnlace}
                aria-current={actual ? 'page' : undefined}
                data-actual={actual ? '' : undefined}
              >
                {e.texto}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}

export function NavegacionMovil({ enlaces }: { enlaces: Enlace[] }) {
  const ruta = usePathname();
  const mas = useRef<HTMLDetailsElement>(null);

  const principales = enlaces.slice(0, VISIBLES_MOVIL);
  const restantes = enlaces.slice(VISIBLES_MOVIL);

  // Al navegar se cierra el desplegable: si no, queda abierto tapando la
  // página a la que se acaba de entrar.
  useEffect(() => {
    if (mas.current) mas.current.open = false;
  }, [ruta]);

  const hayActualEnMas = restantes.some((e) => esActual(ruta, e.href));

  return (
    <nav className={estilos.navMovil} aria-label="Secciones">
      <ul className={estilos.navMovilLista}>
        {principales.map((e) => {
          const actual = esActual(ruta, e.href);
          return (
            <li key={e.href}>
              <Link
                href={e.href}
                className={estilos.navMovilEnlace}
                aria-current={actual ? 'page' : undefined}
                data-actual={actual ? '' : undefined}
              >
                <span className={estilos.navIcono} aria-hidden="true">
                  {e.icono}
                </span>
                <span className={estilos.navTexto}>{e.texto}</span>
              </Link>
            </li>
          );
        })}

        {restantes.length > 0 && (
          <li>
            {/* <details> en vez de un menú con JavaScript: se abre con teclado,
                lo anuncian los lectores de pantalla y funciona aunque el
                hidratado se retrase. */}
            <details className={estilos.mas} ref={mas}>
              <summary
                className={estilos.navMovilEnlace}
                data-actual={hayActualEnMas ? '' : undefined}
              >
                <span className={estilos.navIcono} aria-hidden="true">
                  ⋯
                </span>
                <span className={estilos.navTexto}>Más</span>
              </summary>
              <ul className={estilos.masLista}>
                {restantes.map((e) => {
                  const actual = esActual(ruta, e.href);
                  return (
                    <li key={e.href}>
                      <Link
                        href={e.href}
                        className={estilos.masEnlace}
                        aria-current={actual ? 'page' : undefined}
                        data-actual={actual ? '' : undefined}
                      >
                        <span className={estilos.navIcono} aria-hidden="true">
                          {e.icono}
                        </span>
                        {e.texto}
                      </Link>
                    </li>
                  );
                })}
              </ul>
            </details>
          </li>
        )}
      </ul>
    </nav>
  );
}
