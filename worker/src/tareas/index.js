// ---------------------------------------------------------------------------
// Registro de manejadores de tarea_async.
//
// Para agregar un tipo nuevo: cree src/tareas/<tipo>.js exportando
// `tipo` (string, igual al valor de tarea_async.tipo) y
// `manejar(tarea, ctx)`, e impórtelo aquí. Nada más.
//
//   tarea = { id, tipo, payload, intentos, max_intentos, ... }   (fila completa)
//   ctx   = { db, log, marcarAviso }
//   retorno = objeto JSON que se guarda en tarea_async.resultado
//   lanzar  = la tarea se marca con fallar_tarea (backoff y reintentos los
//             decide la base, el worker no reimplementa nada de eso).
// ---------------------------------------------------------------------------

import * as notificarTurnoLlamado from './notificar_turno_llamado.js';
import * as notificarTurnosProximos from './notificar_turnos_proximos.js';
import * as notificarSuperadmin from './notificar_superadmin.js';
import * as recordarLlamadoVencido from './recordar_llamado_vencido.js';
import * as abrirCuentaTurno from './abrir_cuenta_turno.js';
import * as alertasInventario from './alertas_inventario.js';
import * as agregarLineaCuenta from './agregar_linea_cuenta.js';
import * as enviarResumenConsulta from './enviar_resumen_consulta.js';
import * as enviarRecibo from './enviar_recibo.js';
import * as notificarInicioSesion from './notificar_inicio_sesion.js';
import * as chasquiResponder from './chasqui_responder.js';

const MODULOS = [
  notificarTurnoLlamado,
  notificarTurnosProximos,
  notificarSuperadmin,
  recordarLlamadoVencido,
  abrirCuentaTurno,
  alertasInventario,
  agregarLineaCuenta,
  enviarResumenConsulta,
  enviarRecibo,
  notificarInicioSesion,
  chasquiResponder,
];

export const manejadores = new Map(MODULOS.map((m) => [m.tipo, m.manejar]));

export const tiposConocidos = [...manejadores.keys()].sort();
