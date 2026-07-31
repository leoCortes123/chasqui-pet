import type { Metadata } from 'next';
import Link from 'next/link';
import { consultarUna } from '@/lib/db';
import { exigirSesion, puede } from '@/lib/sesion';
import { fecha, numero, pesos } from '@/lib/formato';
import estilos from './vistas.module.css';
import tabla from './admin.module.css';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Panel — Chasqui Pet',
  robots: { index: false, follow: false },
};

interface Dashboard {
  fecha: string;
  cola: {
    en_espera: number;
    atendidos: number;
    ausentes: number;
    espera_min: number;
    consultorios: {
      consultorio: string;
      abierto: boolean;
      veterinario: string | null;
      turno: string | null;
      estado: string | null;
      paciente: string | null;
    }[];
  };
  inventario: {
    bajo_minimo: number;
    por_vencer: number;
    vencidos: number;
    criticos: { medicamento: string; disponible: string; minimo: string; unidad: string }[];
  };
  caja: {
    total_ingresos: string;
    ingresos: { efectivo: string; transferencia: string; datafono: string };
    descuentos: string;
    por_cobrar: string;
    cuentas_cerradas: number;
    ticket_promedio: string;
  };
  tareas_fallidas: number;
  consultas_borrador: number;
  entradas_borrador: number;
}

/**
 * La portada del portal (§11.2): la cola en vivo, el stock crítico y la
 * caja del día. Una sola llamada a `dashboard()`, que resuelve todo en
 * Postgres: la página no hace seis consultas para pintar seis cifras.
 */
export default async function PaginaPanel() {
  const sesion = await exigirSesion('/');

  // Hay usuarios sin sede propia (el superadmin del seed, por ejemplo):
  // ven la sede activa, que en el MVP es la única que hay.
  const fila = await consultarUna<{ d: Dashboard }>(
    `SELECT dashboard(COALESCE($1::uuid,
              (SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1))) AS d`,
    [sesion.sede_id],
  );
  const d = fila?.d;

  if (!d) {
    return <p className={estilos.vacio}>No hay ninguna sede activa configurada.</p>;
  }

  const verDinero = puede(sesion, 'reportes.financieros') || puede(sesion, 'cobro.ver');

  return (
    <>
      <h1 className={estilos.titulo}>Hoy, {fecha(d.fecha)}</h1>
      <p className={estilos.subtitulo}>
        Lo que está pasando ahora mismo en la clínica.
      </p>

      <section>
        <h2 className={estilos.titulo}>Consultorios</h2>
        <div className={tabla.tarjetas}>
          {d.cola.consultorios.map((c) => (
            <div key={c.consultorio} className={tabla.tarjeta}>
              <span className={tabla.tarjetaTitulo}>{c.consultorio}</span>
              <span className={tabla.tarjetaDetalle}>
                {c.abierto ? c.veterinario ?? 'Abierto' : 'Cerrado'}
              </span>
              <span className={tabla.tarjetaTitulo}>
                {c.turno
                  ? `${c.turno}${c.paciente ? ` · ${c.paciente}` : ''}`
                  : c.abierto
                    ? 'Libre'
                    : '—'}
              </span>
              {c.estado && <span className={tabla.tarjetaDetalle}>{c.estado.replace('_', ' ')}</span>}
            </div>
          ))}
          {d.cola.consultorios.length === 0 && (
            <p className={estilos.vacio}>No hay consultorios configurados.</p>
          )}
        </div>
      </section>

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Cola</h2>
        <div className={tabla.indicadores}>
          <Indicador
            valor={numero(d.cola.en_espera)}
            etiqueta="En espera"
            tono={d.cola.en_espera > 10 ? 'alerta' : undefined}
          />
          <Indicador valor={numero(d.cola.atendidos)} etiqueta="Atendidos" tono="bien" />
          <Indicador valor={numero(d.cola.ausentes)} etiqueta="Ausentes" />
          <Indicador
            valor={`${numero(d.cola.espera_min)} min`}
            etiqueta="Espera actual"
            tono={Number(d.cola.espera_min) > 45 ? 'alerta' : undefined}
          />
        </div>
      </section>

      {verDinero && (
        <section className={tabla.seccion}>
          <h2 className={estilos.titulo}>Caja del día</h2>
          <div className={tabla.indicadores}>
            <Indicador valor={pesos(d.caja.total_ingresos)} etiqueta="Ingresos" tono="bien" />
            <Indicador valor={pesos(d.caja.ingresos.efectivo)} etiqueta="Efectivo" />
            <Indicador valor={pesos(d.caja.ingresos.transferencia)} etiqueta="Transferencia" />
            <Indicador valor={pesos(d.caja.ingresos.datafono)} etiqueta="Datáfono" />
            <Indicador
              valor={pesos(d.caja.por_cobrar)}
              etiqueta="Por cobrar"
              tono={Number(d.caja.por_cobrar) > 0 ? 'alerta' : undefined}
            />
            <Indicador valor={numero(d.caja.cuentas_cerradas)} etiqueta="Cuentas cerradas" />
          </div>
        </section>
      )}

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Inventario</h2>
        <div className={tabla.indicadores}>
          <Indicador
            valor={numero(d.inventario.bajo_minimo)}
            etiqueta="Bajo mínimo"
            tono={d.inventario.bajo_minimo > 0 ? 'alerta' : undefined}
          />
          <Indicador
            valor={numero(d.inventario.por_vencer)}
            etiqueta="Por vencer"
            tono={d.inventario.por_vencer > 0 ? 'alerta' : undefined}
          />
          <Indicador
            valor={numero(d.inventario.vencidos)}
            etiqueta="Vencidos con existencia"
            tono={d.inventario.vencidos > 0 ? 'grave' : undefined}
          />
        </div>

        {d.inventario.criticos.length > 0 && (
          <ul className={estilos.lista} style={{ marginTop: '0.75rem' }}>
            {d.inventario.criticos.map((c) => (
              <li key={c.medicamento} className={estilos.fila}>
                <span className={estilos.emoji}>🔻</span>
                <span className={estilos.filaTexto}>
                  <span className={estilos.filaNombre}>{c.medicamento}</span>
                  <span className={estilos.filaDetalle}>
                    quedan {numero(c.disponible)} {c.unidad} · mínimo {numero(c.minimo)}
                  </span>
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className={tabla.seccion}>
        <h2 className={estilos.titulo}>Pendientes</h2>
        <div className={tabla.tarjetas}>
          <Link className={tabla.tarjeta} href="/consultas">
            <span className={tabla.tarjetaTitulo}>
              {numero(d.consultas_borrador)} consulta(s) sin firmar
            </span>
            <span className={tabla.tarjetaDetalle}>
              Un borrador no es registro clínico válido hasta que se firma.
            </span>
          </Link>

          {puede(sesion, 'inventario.entrada') && (
            <Link className={tabla.tarjeta} href="/compras">
              <span className={tabla.tarjetaTitulo}>
                {numero(d.entradas_borrador)} compra(s) sin confirmar
              </span>
              <span className={tabla.tarjetaDetalle}>
                Mientras estén en borrador no han entrado al inventario.
              </span>
            </Link>
          )}

          {puede(sesion, 'sistema.operar') && (
            <Link className={tabla.tarjeta} href="/admin/tareas">
              <span className={tabla.tarjetaTitulo}>
                {numero(d.tareas_fallidas)} tarea(s) fallida(s)
              </span>
              <span className={tabla.tarjetaDetalle}>
                Avisos y recibos que no se pudieron entregar.
              </span>
            </Link>
          )}
        </div>
      </section>
    </>
  );
}

function Indicador({
  valor,
  etiqueta,
  tono,
}: {
  valor: string;
  etiqueta: string;
  tono?: 'alerta' | 'grave' | 'bien';
}) {
  return (
    <div className={`${tabla.indicador} ${tono ? tabla[tono] : ''}`}>
      <span className={tabla.indicadorValor}>{valor}</span>
      <span className={tabla.indicadorEtiqueta}>{etiqueta}</span>
    </div>
  );
}
