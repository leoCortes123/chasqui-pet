# Chasqui Pet — Portal web y pantalla de turnos

Aplicación Next.js (App Router, TypeScript) de Chasqui Pet. Incluye el health
check, la **pantalla pública de turnos** de la sala de espera y el **portal
clínico**: ingreso por Telegram, buscador de pacientes, historia clínica y el
formulario completo de consulta (§8.2.5).

## Requisitos

- Node 22
- PostgreSQL con el esquema de Chasqui Pet ya cargado

## Configuración

Una sola variable es obligatoria:

```bash
DATABASE_URL=postgresql://chasquipet_app:CLAVE@localhost:5432/chasquipet
```

Opcionales:

| Variable | Para qué | Valor por defecto |
|---|---|---|
| `DATABASE_URL_DIRECTA` | Conexión **sin pgbouncer** para el `LISTEN` de la pantalla. Obligatoria si `DATABASE_URL` apunta a pgbouncer en modo *transaction*, porque ahí `LISTEN` no funciona. | el valor de `DATABASE_URL` |
| `NOMBRE_CLINICA` | Nombre que se muestra en la pantalla cuando no hay nadie en atención y en la cabecera del portal. | `Chasqui Pet` |
| `TELEGRAM_BOT_USERNAME` | Sin arroba. Arma el enlace «Abrir Telegram» de la pantalla de ingreso. Sin ella, el portal indica escribirle `/start` al bot a mano. | — |
| `WEB_PUBLIC_URL` | Si empieza por `https://`, la cookie de sesión se marca `secure`. En LAN por HTTP se deja como está. | — |
| `DB_POOL_MAX` | Conexiones máximas del pool de consultas. | `10` |
| `TZ` | Zona horaria del proceso. | `America/Bogota` |

## Correr en desarrollo

```bash
cd web
npm install
DATABASE_URL=postgresql://chasquipet_app:CLAVE@localhost:5432/chasquipet npm run dev
```

Queda en <http://localhost:3000>.

Verificaciones útiles:

```bash
npm run typecheck   # tsc --noEmit
npm run build       # build de producción (salida standalone)
npm start           # servir el build
```

## La pantalla de la sala de espera

**URL que se abre en el monitor:**

```
http://<servidor>:3000/pantalla/<id-de-la-sede>
```

El `<id-de-la-sede>` es el `uuid` de la tabla `sede`. Para obtenerlo:

```bash
psql -d chasquipet -tAc "SELECT id, nombre FROM sede WHERE activa"
```

La pantalla **no pide contraseña** y **no muestra ningún dato personal**: sólo
códigos de turno y consultorio. Si la sede no existe o está inactiva, responde
404 con un mensaje explicando qué revisar.

### Cómo ponerla en pantalla completa

1. Abra la URL en Chrome o Firefox.
2. Presione **F11** (en macOS, `Ctrl + Cmd + F`). Para salir, F11 de nuevo.
3. Recomendado en el navegador del monitor:
   - Desactive el protector de pantalla y la suspensión del equipo.
   - Configure la URL como página de inicio, para que al reiniciar el equipo
     vuelva sola.
   - En Chrome, arrancar con `chrome --kiosk --app=http://<servidor>:3000/pantalla/<id>`
     deja la pantalla sin barra de direcciones ni pestañas.

La pantalla se ajusta sola al tamaño del monitor (horizontal o vertical) y el
código de turno se dimensiona con `clamp()` en unidades de viewport, así que se
lee a 3 metros tanto en un monitor 1080p como en un televisor 4K.

### Cómo se mantiene actualizada

Se actualiza sola, sin recargar:

1. **SSE** (`/api/pantalla/<sede>/stream`): Postgres emite
   `NOTIFY pantalla_turnos` en cada cambio de la cola y la pantalla recibe el
   estado nuevo al instante. Hay un latido cada 20 s para que ningún proxy corte
   la conexión.
2. **Polling cada 5 s** (`/api/pantalla/<sede>`): si el SSE falla, se corta o
   deja de dar señales, la pantalla pasa a consultar cada 5 segundos y avisa
   discretamente en una esquina. **La pantalla nunca se queda congelada.**

Si hay un proxy inverso delante (Nginx), debe ir sin buffer para la ruta del
stream:

```nginx
location /api/pantalla/ {
    proxy_pass http://web:3000;
    proxy_buffering off;
    proxy_read_timeout 1h;
}
```

## Health check

```bash
curl http://localhost:3000/health
# {"ok":true,"db":"ok","hora":"2026-07-31T02:00:00.726Z"}
```

Responde **200** si PostgreSQL contesta y **503** si no. Nunca se cachea.

## Estructura

```
src/
  app/
    health/route.ts                       health check
    api/pantalla/[sede]/route.ts          JSON (respaldo por polling)
    api/pantalla/[sede]/stream/route.ts   SSE
    pantalla/[sede]/page.tsx              pantalla (render en servidor)
    pantalla/[sede]/vista-pantalla.tsx    componente cliente (SSE + polling)
    entrar/page.tsx                       ingreso: código de 6 dígitos
    entrar/ingreso.tsx                    componente cliente (sondeo del código)
    api/entrar/route.ts                   crea el challenge
    api/entrar/[id]/route.ts              lo canjea por sesión y pone la cookie
    salir/route.ts                        revoca la sesión (POST)
    (portal)/layout.tsx                   marco del portal; exige sesión
    (portal)/consultas/page.tsx           bandeja: borradores propios y lo de hoy
    (portal)/pacientes/page.tsx           buscador
    (portal)/pacientes/[id]/page.tsx      ficha e historia clínica
    (portal)/consulta/[id]/page.tsx       consulta: formulario o lectura
    (portal)/consulta/[id]/formulario.tsx formulario completo (§8.2.5)
    (portal)/consulta/[id]/acciones.ts    acciones de servidor: guardar y firmar
  lib/
    db.ts                                 pool de pg y cliente de LISTEN
    pantalla.ts                           contrato con pantalla_publica()
    notificaciones.ts                     multiplexor de NOTIFY
    sesion.ts                             cookie de sesión y permisos
    clinico.ts                            contrato con las funciones clínicas
```

## El portal

Todo lo que cuelga de `(portal)` exige sesión: la comprobación está en el layout
para que agregar una vista nueva no pueda olvidarse de pedirla. Los permisos
salen de `v_usuario_permiso` en Postgres (§4); la web sólo lee la lista.

Ninguna pantalla decide nada clínico. Guardar, firmar y agregar adendas llaman a
las mismas funciones SQL que usa el bot (`guardar_consulta_completa`,
`firmar_consulta`, `agregar_adenda`), así que los rangos del examen, los campos
obligatorios para firmar y la inmutabilidad de lo firmado se validan una sola
vez y en un solo sitio.
