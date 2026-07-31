import { NextResponse } from 'next/server';
import { consultarUna } from '@/lib/db';
import { agenteCliente, ipCliente } from '@/lib/sesion';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

interface Challenge {
  ok: boolean;
  challenge_id?: string;
  codigo?: string;
  expira_at?: string;
  mensaje?: string;
}

/**
 * Paso 1 del ingreso (§11.1): la web pide un challenge y recibe el código de
 * seis dígitos que hay que confirmar en Telegram.
 *
 * El rate limit por IP lo aplica Postgres, no este handler: es el mismo
 * mecanismo que usa el bot y no hay estado que mantener en Node.
 */
export async function POST(): Promise<NextResponse> {
  const ip = await ipCliente();
  const agente = await agenteCliente();

  const fila = await consultarUna<{ r: Challenge }>(
    'SELECT crear_challenge_web($1, $2, $3) AS r',
    [ip, agente, dispositivo(agente)],
  );

  const r = fila?.r;
  if (!r?.ok) {
    return NextResponse.json(
      { ok: false, mensaje: r?.mensaje ?? 'No se pudo iniciar el ingreso.' },
      { status: 429 },
    );
  }

  const bot = process.env.TELEGRAM_BOT_USERNAME ?? '';

  return NextResponse.json(
    {
      ok: true,
      challenge_id: r.challenge_id,
      codigo: r.codigo,
      expira_at: r.expira_at,
      enlace: bot ? `https://t.me/${bot}?start=web-${r.challenge_id}` : null,
    },
    { headers: { 'Cache-Control': 'no-store' } },
  );
}

/** Nombre corto del dispositivo, para que el aviso en Telegram sea legible. */
function dispositivo(agente: string | null): string {
  if (!agente) return 'Navegador';
  const sistema = /Android/i.test(agente)
    ? 'Android'
    : /iPhone|iPad/i.test(agente)
      ? 'iPhone'
      : /Windows/i.test(agente)
        ? 'Windows'
        : /Mac OS/i.test(agente)
          ? 'Mac'
          : /Linux/i.test(agente)
            ? 'Linux'
            : 'Equipo';
  const navegador = /Edg\//i.test(agente)
    ? 'Edge'
    : /Chrome\//i.test(agente)
      ? 'Chrome'
      : /Firefox\//i.test(agente)
        ? 'Firefox'
        : /Safari\//i.test(agente)
          ? 'Safari'
          : 'navegador';
  return `${navegador} en ${sistema}`;
}
