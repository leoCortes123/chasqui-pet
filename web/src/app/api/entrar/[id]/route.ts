import { cookies } from 'next/headers';
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
  usuario?: { nombre?: string };
}

/**
 * Paso 3 del ingreso (§11.1): la web pregunta si ya lo aprobaron y, si sí,
 * canjea el challenge por la sesión.
 *
 * Es una sola llamada y no dos —consultar estado y luego canjear— porque el
 * canje es de un solo uso: preguntar y canjear por separado abre una ventana
 * en la que el estado dice «aprobado» y el token ya se lo llevó otro.
 *
 * El token no llega nunca al JavaScript de la página: se escribe aquí como
 * cookie HttpOnly y el navegador no puede leerlo.
 */
export async function POST(
  _peticion: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<NextResponse> {
  const { id } = await params;

  if (!esUuid(id)) {
    return NextResponse.json({ ok: false, estado: 'invalido' }, { status: 400 });
  }

  const fila = await consultarUna<{ r: Emision }>(
    'SELECT emitir_sesion_web($1, $2, $3) AS r',
    [id, await ipCliente(), await agenteCliente()],
  );

  const r = fila?.r;

  if (!r?.ok || !r.token) {
    // 200 a propósito: «todavía pendiente» es la respuesta normal del sondeo,
    // no un error del que haya que avisar en la consola del navegador.
    return NextResponse.json(
      { ok: false, estado: r?.estado ?? 'pendiente' },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  }

  (await cookies()).set(COOKIE_SESION, r.token, {
    httpOnly: true,
    sameSite: 'lax',
    // La clínica opera en LAN por HTTP; forzar `secure` dejaría el portal
    // inaccesible ahí. En cuanto haya HTTPS, esta variable lo activa.
    secure: (process.env.WEB_PUBLIC_URL ?? '').startsWith('https://'),
    path: '/',
    maxAge: DURACION_COOKIE_SEG,
  });

  return NextResponse.json(
    { ok: true, nombre: r.usuario?.nombre ?? null },
    { headers: { 'Cache-Control': 'no-store' } },
  );
}
