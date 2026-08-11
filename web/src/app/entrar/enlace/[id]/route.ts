import { NextResponse } from 'next/server';
import { consultarUna } from '@/lib/db';
import { esUuid } from '@/lib/clinico';
import {
  COOKIE_SESION,
  DURACION_COOKIE_SEG,
  agenteCliente,
  ipCliente,
} from '@/lib/sesion';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

interface Emision {
  ok: boolean;
  estado?: string;
  token?: string;
}

/**
 * Ingreso por enlace de un solo uso, pedido desde el bot (§11.1, `077_portal_enlace.sql`).
 *
 * El challenge ya viene aprobado desde Telegram, así que aquí sólo se canjea:
 * es el mismo `emitir_sesion_web` del ingreso por código, con la misma
 * expiración de 5 minutos, el mismo consumo de un solo uso y el mismo aviso
 * de sesión nueva al Telegram del dueño de la cuenta.
 *
 * Es un GET que crea sesión, que normalmente sería un pecado. Se acepta porque
 * el enlace ES la credencial y el portal vive en la LAN: nadie de afuera
 * —incluido el previsualizador de enlaces de Telegram— puede alcanzarlo para
 * gastarlo. Si algún día el portal sale a internet, esto tiene que pasar a ser
 * una página con confirmación explícita.
 */
export async function GET(
  _peticion: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<NextResponse> {
  const { id } = await params;

  if (!esUuid(id)) {
    return irA('/entrar?enlace=invalido');
  }

  const fila = await consultarUna<{ r: Emision }>(
    'SELECT emitir_sesion_web($1, $2, $3) AS r',
    [id, await ipCliente(), await agenteCliente()],
  );

  const r = fila?.r;

  if (!r?.ok || !r.token) {
    // Enlace vencido, ya usado o anulado por uno más nuevo: se manda al
    // ingreso normal, que siempre funciona.
    return irA('/entrar?enlace=vencido');
  }

  const respuesta = irA('/');

  respuesta.cookies.set(COOKIE_SESION, r.token, {
    httpOnly: true,
    sameSite: 'lax',
    // Igual que en el ingreso por código: la clínica opera en LAN por HTTP.
    secure: (process.env.WEB_PUBLIC_URL ?? '').startsWith('https://'),
    path: '/',
    maxAge: DURACION_COOKIE_SEG,
  });

  return respuesta;
}

/**
 * Redirección con destino relativo. `NextResponse.redirect` exige una URL
 * absoluta y dentro del contenedor eso resuelve a `http://0.0.0.0:3000`, que
 * en el navegador de la clínica no existe. El navegador resuelve el relativo
 * contra la dirección por la que entró, que es siempre la correcta.
 */
function irA(destino: string): NextResponse {
  return new NextResponse(null, { status: 303, headers: { Location: destino } });
}
