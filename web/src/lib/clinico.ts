import { consultar, consultarUna } from './db';

/**
 * Lectura del módulo clínico para el portal.
 *
 * Igual que en `pantalla.ts`: lo que devuelven las funciones SQL se muestra tal
 * cual. La web no reordena ni recalcula nada del contenido clínico — si algo
 * hay que cambiar, se cambia en la función SQL y el bot cambia con ella.
 */

const RE_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function esUuid(valor: string): boolean {
  return RE_UUID.test(valor);
}

export interface Paciente {
  paciente_id: string;
  nombre: string;
  especie: string;
  especie_nombre: string;
  emoji: string;
  raza: string | null;
  sexo: string;
  esterilizado: boolean | null;
  edad: string | null;
  fecha_nacimiento_aprox: string | null;
  color_senas: string | null;
  peso_kg: string | null;
  alergias: string | null;
  estado: string;
  notas: string | null;
  dueno_id: string | null;
  dueno: string | null;
  telefono: string | null;
  consultas: number;
  ultima_consulta: string | null;
}

export interface Consulta {
  consulta_id: string;
  estado: 'borrador' | 'firmada' | 'anulada';
  fecha: string;
  turno: string | null;
  paciente_id: string;
  paciente: Paciente;
  veterinario: string | null;
  consultorio: string | null;
  motivo_consulta: string | null;
  anamnesis: string | null;
  examen_fisico: Record<string, string | number>;
  examen_texto: string | null;
  diagnostico_presuntivo: string | null;
  diagnostico_definitivo: string | null;
  plan_tratamiento: string | null;
  recomendaciones: string | null;
  remision_externa: string | null;
  proxima_revision: string | null;
  firmada_at: string | null;
  motivo_anulacion: string | null;
  medicamentos: { nombre: string; cantidad: string; unidad: string }[];
  adendas: { texto: string; autor: string; created_at: string }[];
}

export interface Opcion {
  v: string;
  t: string;
}

export async function obtenerConsulta(id: string): Promise<Consulta | null> {
  if (!esUuid(id)) return null;
  const fila = await consultarUna<{ c: Consulta | null }>(
    'SELECT consulta_json($1) AS c',
    [id],
  );
  return fila?.c ?? null;
}

export async function obtenerPaciente(id: string): Promise<Paciente | null> {
  if (!esUuid(id)) return null;
  const fila = await consultarUna<{ p: Paciente | null }>(
    'SELECT paciente_json($1) AS p',
    [id],
  );
  return fila?.p ?? null;
}

export interface LineaHistoria {
  consulta_id: string;
  fecha: string;
  veterinario: string | null;
  motivo: string | null;
  diagnostico: string | null;
  plan: string | null;
  examen: string | null;
  medicamentos: string | null;
}

export async function obtenerHistoria(pacienteId: string): Promise<LineaHistoria[]> {
  if (!esUuid(pacienteId)) return [];
  return consultar<LineaHistoria>(
    `SELECT consulta_id::text, fecha::text, veterinario, motivo,
            diagnostico, plan, examen, medicamentos
       FROM historia_paciente($1, 50)`,
    [pacienteId],
  );
}

export interface ResultadoPaciente {
  paciente_id: string;
  nombre: string;
  especie: string;
  dueno: string | null;
  telefono: string | null;
  ultima_consulta: string | null;
}

export async function buscarPacientes(texto: string): Promise<ResultadoPaciente[]> {
  if (!texto.trim()) return [];
  return consultar<ResultadoPaciente>(
    `SELECT paciente_id::text, nombre, especie, dueno, telefono,
            ultima_consulta::text
       FROM buscar_paciente($1, 20)`,
    [texto],
  );
}

/** Catálogo de lo enumerable: el mismo que pinta los botones del bot. */
export async function opciones(campo: string): Promise<Opcion[]> {
  const fila = await consultarUna<{ o: Opcion[] }>(
    'SELECT opciones_examen($1) AS o',
    [campo],
  );
  return fila?.o ?? [];
}

export interface ConsultaLista {
  consulta_id: string;
  estado: string;
  fecha: string;
  paciente: string;
  emoji: string;
  dueno: string | null;
  veterinario: string | null;
  turno: string | null;
  actualizada: string;
}

/**
 * Bandeja del portal: primero los borradores propios —lo que hay que
 * terminar— y después lo firmado hoy.
 */
export async function consultasRecientes(usuarioId: string): Promise<ConsultaLista[]> {
  return consultar<ConsultaLista>(
    `SELECT c.id::text AS consulta_id, c.estado, c.fecha::text,
            p.nombre AS paciente, emoji_especie(p.especie) AS emoji,
            d.nombre_completo AS dueno, u.nombre_completo AS veterinario,
            t.codigo AS turno,
            to_char(c.updated_at AT TIME ZONE 'America/Bogota', 'DD/MM HH24:MI') AS actualizada
       FROM consulta c
       JOIN paciente p ON p.id = c.paciente_id
       LEFT JOIN dueno d   ON d.id = c.dueno_id
       LEFT JOIN usuario u ON u.id = c.veterinario_id
       LEFT JOIN turno t   ON t.id = c.turno_id
      WHERE (c.estado = 'borrador' AND c.veterinario_id = $1)
         OR c.fecha = hoy_bogota()
      ORDER BY (c.estado = 'borrador' AND c.veterinario_id = $1) DESC,
               c.updated_at DESC
      LIMIT 50`,
    [usuarioId],
  );
}
