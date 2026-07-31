import { consultar } from './db';
import { fecha, fechaHora } from './formato';

/**
 * Los nueve reportes de §10, declarados como datos.
 *
 * Cada uno es una función SQL de `080_reportes.sql` que devuelve una
 * tabla. Aquí sólo se declara cómo se llama, qué permiso pide y cómo se
 * pinta cada columna. La página de reportes y la exportación a CSV son
 * las mismas para todos: agregar un reporte nuevo es agregar una entrada
 * a esta lista y una función en SQL, sin escribir una página.
 *
 * El permiso se comprueba en el servidor antes de consultar. Los de caja,
 * margen, descuentos y compras piden `reportes.financieros`, que el
 * veterinario no tiene: quién despacha no ve la plata (§4).
 */

export type TipoColumna = 'texto' | 'numero' | 'dinero' | 'fecha' | 'fecha_hora' | 'pct';

export interface Columna {
  clave: string;
  titulo: string;
  tipo?: TipoColumna;
}

export interface Reporte {
  clave: string;
  titulo: string;
  descripcion: string;
  permiso: 'reportes.operativos' | 'reportes.financieros';
  grupo: 'Operación' | 'Dinero' | 'Inventario' | 'Clínica';
  /** `$1` = desde, `$2` = hasta. Los que no filtran por fecha no los usan. */
  sql: string;
  conRango: boolean;
  columnas: Columna[];
}

export const REPORTES: Reporte[] = [
  {
    clave: 'stock',
    titulo: 'Stock actual',
    descripcion:
      'Existencia por medicamento con lo que está bajo el mínimo, por vencer y agotado.',
    permiso: 'reportes.operativos',
    grupo: 'Inventario',
    sql: 'SELECT * FROM reporte_stock()',
    conRango: false,
    columnas: [
      { clave: 'medicamento', titulo: 'Medicamento' },
      { clave: 'categoria', titulo: 'Categoría' },
      { clave: 'estado', titulo: 'Estado' },
      { clave: 'disponible', titulo: 'Disponible', tipo: 'numero' },
      { clave: 'unidad', titulo: 'Unidad' },
      { clave: 'stock_minimo', titulo: 'Mínimo', tipo: 'numero' },
      { clave: 'lotes', titulo: 'Lotes', tipo: 'numero' },
      { clave: 'proximo_vencimiento', titulo: 'Vence', tipo: 'fecha' },
      { clave: 'precio_venta', titulo: 'Precio', tipo: 'dinero' },
      { clave: 'costo_promedio', titulo: 'Costo medio', tipo: 'dinero' },
      { clave: 'valor_inventario', titulo: 'Valor', tipo: 'dinero' },
    ],
  },
  {
    clave: 'consumo',
    titulo: 'Consumo de medicamentos',
    descripcion: 'Qué salió, cuánto valió y a cuántos pacientes, en el período.',
    permiso: 'reportes.operativos',
    grupo: 'Inventario',
    sql: 'SELECT * FROM reporte_consumo($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'medicamento', titulo: 'Medicamento' },
      { clave: 'salidas', titulo: 'Salidas', tipo: 'numero' },
      { clave: 'unidades', titulo: 'Unidades', tipo: 'numero' },
      { clave: 'unidad', titulo: 'Unidad' },
      { clave: 'valor_venta', titulo: 'Venta', tipo: 'dinero' },
      { clave: 'costo', titulo: 'Costo', tipo: 'dinero' },
      { clave: 'margen', titulo: 'Margen', tipo: 'dinero' },
      { clave: 'pacientes', titulo: 'Pacientes', tipo: 'numero' },
    ],
  },
  {
    clave: 'turnos',
    titulo: 'Turnos por día',
    descripcion:
      'Atendidos, ausentes, espera y atención promedio, y la hora pico. Dice cuánto personal hace falta y cuándo.',
    permiso: 'reportes.operativos',
    grupo: 'Operación',
    sql: 'SELECT * FROM reporte_turnos($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'fecha', titulo: 'Fecha', tipo: 'fecha' },
      { clave: 'emitidos', titulo: 'Emitidos', tipo: 'numero' },
      { clave: 'atendidos', titulo: 'Atendidos', tipo: 'numero' },
      { clave: 'ausentes', titulo: 'Ausentes', tipo: 'numero' },
      { clave: 'cancelados', titulo: 'Cancelados', tipo: 'numero' },
      { clave: 'espera_promedio_min', titulo: 'Espera (min)', tipo: 'numero' },
      { clave: 'atencion_promedio_min', titulo: 'Atención (min)', tipo: 'numero' },
      { clave: 'hora_pico', titulo: 'Hora pico' },
      { clave: 'por_qr', titulo: 'Por QR', tipo: 'numero' },
    ],
  },
  {
    clave: 'turnos-hora',
    titulo: 'Turnos por hora',
    descripcion: 'A qué hora llega la gente y cuánto espera. Es el reporte del segundo consultorio.',
    permiso: 'reportes.operativos',
    grupo: 'Operación',
    sql: 'SELECT * FROM reporte_turnos_hora($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'hora', titulo: 'Hora' },
      { clave: 'emitidos', titulo: 'Emitidos', tipo: 'numero' },
      { clave: 'atendidos', titulo: 'Atendidos', tipo: 'numero' },
      { clave: 'espera_promedio_min', titulo: 'Espera (min)', tipo: 'numero' },
    ],
  },
  {
    clave: 'ocupacion',
    titulo: 'Ocupación por consultorio',
    descripcion: 'Cuánto atendió cada veterinario en cada consultorio y cuántas horas estuvo abierto.',
    permiso: 'reportes.operativos',
    grupo: 'Operación',
    sql: 'SELECT * FROM reporte_ocupacion_consultorio($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'consultorio', titulo: 'Consultorio' },
      { clave: 'veterinario', titulo: 'Veterinario' },
      { clave: 'atendidos', titulo: 'Atendidos', tipo: 'numero' },
      { clave: 'atencion_promedio_min', titulo: 'Atención (min)', tipo: 'numero' },
      { clave: 'horas_abierto', titulo: 'Horas abierto', tipo: 'numero' },
    ],
  },
  {
    clave: 'caja',
    titulo: 'Caja por día',
    descripcion: 'Ingresos por medio de pago, ticket promedio y diferencias de cuadre.',
    permiso: 'reportes.financieros',
    grupo: 'Dinero',
    sql: 'SELECT * FROM reporte_caja($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'fecha', titulo: 'Fecha', tipo: 'fecha' },
      { clave: 'cuentas', titulo: 'Cuentas', tipo: 'numero' },
      { clave: 'efectivo', titulo: 'Efectivo', tipo: 'dinero' },
      { clave: 'transferencia', titulo: 'Transferencia', tipo: 'dinero' },
      { clave: 'datafono', titulo: 'Datáfono', tipo: 'dinero' },
      { clave: 'total', titulo: 'Total', tipo: 'dinero' },
      { clave: 'descuentos', titulo: 'Descuentos', tipo: 'dinero' },
      { clave: 'ticket_promedio', titulo: 'Ticket promedio', tipo: 'dinero' },
      { clave: 'diferencia', titulo: 'Diferencia', tipo: 'dinero' },
    ],
  },
  {
    clave: 'descuentos',
    titulo: 'Descuentos aplicados',
    descripcion: 'Cada rebaja con su motivo y quién la autorizó (§7.3).',
    permiso: 'reportes.financieros',
    grupo: 'Dinero',
    sql: 'SELECT * FROM reporte_descuentos($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'fecha', titulo: 'Fecha', tipo: 'fecha' },
      { clave: 'hora', titulo: 'Hora' },
      { clave: 'paciente', titulo: 'Paciente' },
      { clave: 'valor', titulo: 'Valor', tipo: 'dinero' },
      { clave: 'motivo', titulo: 'Motivo' },
      { clave: 'autorizo', titulo: 'Autorizó' },
    ],
  },
  {
    clave: 'margen',
    titulo: 'Margen de medicamentos',
    descripcion:
      'Ingreso contra el costo del lote que efectivamente salió, no contra un costo promedio inventado.',
    permiso: 'reportes.financieros',
    grupo: 'Dinero',
    sql: 'SELECT * FROM reporte_margen($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'medicamento', titulo: 'Medicamento' },
      { clave: 'unidades', titulo: 'Unidades', tipo: 'numero' },
      { clave: 'unidad', titulo: 'Unidad' },
      { clave: 'ingreso', titulo: 'Ingreso', tipo: 'dinero' },
      { clave: 'costo', titulo: 'Costo', tipo: 'dinero' },
      { clave: 'margen', titulo: 'Margen', tipo: 'dinero' },
      { clave: 'margen_pct', titulo: 'Margen %', tipo: 'pct' },
    ],
  },
  {
    clave: 'compras',
    titulo: 'Compras por proveedor',
    descripcion: 'Cada renglón de cada factura confirmada en el período.',
    permiso: 'reportes.financieros',
    grupo: 'Dinero',
    sql: 'SELECT * FROM reporte_compras_detalle($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'fecha', titulo: 'Fecha', tipo: 'fecha' },
      { clave: 'proveedor', titulo: 'Proveedor' },
      { clave: 'documento', titulo: 'Factura' },
      { clave: 'medicamento', titulo: 'Medicamento' },
      { clave: 'lote', titulo: 'Lote' },
      { clave: 'vence', titulo: 'Vence', tipo: 'fecha' },
      { clave: 'cantidad', titulo: 'Cantidad', tipo: 'numero' },
      { clave: 'costo_unitario', titulo: 'Costo unit.', tipo: 'dinero' },
      { clave: 'valor_total', titulo: 'Valor', tipo: 'dinero' },
    ],
  },
  {
    clave: 'consultas',
    titulo: 'Consultas por veterinario',
    descripcion: 'Firmadas, borradores sin cerrar, remisiones y controles pendientes.',
    permiso: 'reportes.operativos',
    grupo: 'Clínica',
    sql: 'SELECT * FROM reporte_consultas($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'veterinario', titulo: 'Veterinario' },
      { clave: 'firmadas', titulo: 'Firmadas', tipo: 'numero' },
      { clave: 'borradores', titulo: 'Sin firmar', tipo: 'numero' },
      { clave: 'anuladas', titulo: 'Anuladas', tipo: 'numero' },
      { clave: 'con_remision', titulo: 'Remisiones', tipo: 'numero' },
      { clave: 'con_revision', titulo: 'Con control', tipo: 'numero' },
      { clave: 'pacientes', titulo: 'Pacientes', tipo: 'numero' },
    ],
  },
  {
    clave: 'diagnosticos',
    titulo: 'Diagnósticos más frecuentes',
    descripcion: 'Sobre consultas firmadas, agrupando lo que se escribió a mano.',
    permiso: 'reportes.operativos',
    grupo: 'Clínica',
    sql: 'SELECT * FROM reporte_diagnosticos($1, $2, 50)',
    conRango: true,
    columnas: [
      { clave: 'diagnostico', titulo: 'Diagnóstico' },
      { clave: 'veces', titulo: 'Veces', tipo: 'numero' },
      { clave: 'pacientes', titulo: 'Pacientes', tipo: 'numero' },
    ],
  },
  {
    clave: 'pacientes',
    titulo: 'Pacientes por especie',
    descripcion: 'Nuevos contra recurrentes, remisiones emitidas y cuántas volvieron.',
    permiso: 'reportes.operativos',
    grupo: 'Clínica',
    sql: 'SELECT * FROM reporte_pacientes($1, $2)',
    conRango: true,
    columnas: [
      { clave: 'especie', titulo: 'Especie' },
      { clave: 'pacientes', titulo: 'Pacientes', tipo: 'numero' },
      { clave: 'nuevos', titulo: 'Nuevos', tipo: 'numero' },
      { clave: 'recurrentes', titulo: 'Recurrentes', tipo: 'numero' },
      { clave: 'consultas', titulo: 'Consultas', tipo: 'numero' },
      { clave: 'remisiones', titulo: 'Remisiones', tipo: 'numero' },
      { clave: 'retornaron', titulo: 'Retornaron', tipo: 'numero' },
    ],
  },
];

export function reportePorClave(clave: string): Reporte | undefined {
  return REPORTES.find((r) => r.clave === clave);
}

export type FilaReporte = Record<string, unknown>;

/**
 * Ejecuta el reporte. El `sql` no viene nunca del usuario: sale de la
 * lista de arriba, indexada por una clave que se valida antes. El rango
 * sí viene del formulario y va como parámetro, jamás concatenado.
 */
export async function ejecutarReporte(
  reporte: Reporte,
  desde: string | null,
  hasta: string | null,
): Promise<FilaReporte[]> {
  const valores = reporte.conRango ? [desde || null, hasta || null] : [];
  return consultar<FilaReporte>(reporte.sql, valores);
}

/**
 * Un CSV que Excel en español abre sin pelear: separador `;` y BOM.
 *
 * Las fechas van en dd/mm/aaaa —el `driver` de Postgres las entrega como
 * `Date` y un ISO con hora Z en una columna de fechas confunde a quien
 * abre el archivo—. Los números van crudos, sin separador de miles:
 * formatearlos los convertiría en texto y no se podrían sumar.
 */
export function aCsv(reporte: Reporte, filas: FilaReporte[]): string {
  const escapar = (texto: string): string =>
    /[";\n]/.test(texto) ? `"${texto.replace(/"/g, '""')}"` : texto;

  const valor = (v: unknown, columna: Columna): string => {
    if (v === null || v === undefined) return '';
    if (columna.tipo === 'fecha') return fecha(v);
    if (columna.tipo === 'fecha_hora') return fechaHora(v);
    return v instanceof Date ? fechaHora(v) : String(v);
  };

  const lineas = [
    reporte.columnas.map((c) => escapar(c.titulo)).join(';'),
    ...filas.map((f) => reporte.columnas.map((c) => escapar(valor(f[c.clave], c))).join(';')),
  ];

  return `﻿${lineas.join('\r\n')}\r\n`;
}
