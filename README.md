# Chasqui Pet

Sistema de gestión para clínica veterinaria, operado principalmente desde
Telegram. Sistema nuevo e independiente: no comparte código ni base de datos con
Chasqui.

> **Estado: paso 3 de 8.** Están terminados el esquema base con identidad, roles
> y permisos, el módulo completo de turnos y el de inventario. Historia clínica,
> cobro, proveedores y portal administrativo son los pasos siguientes. La guía
> de operación para el personal de la clínica se escribe en el paso 8.

## Qué hay funcionando

- Turnos por orden de llegada con dos consultorios y cola única compartida.
- Emisión de turno escaneando un QR, sin registro ni datos personales.
- Emisión manual desde el bot, para quien no tiene celular.
- Operación completa desde Telegram: llamar siguiente, ver cola, marcar
  presentado o ausente, reencolar, finalizar, marcar urgencia, abrir y cerrar
  consultorio.
- Avisos automáticos al dueño: «faltan 2 turnos» y «es tu turno, pasa al
  Consultorio 2».
- Pantalla pública de sala de espera, sin autenticación, con actualización en
  vivo y respaldo por sondeo.
- Catálogo de medicamentos con precio de venta, y existencias por lote con
  vencimiento y costo de compra.
- Salida de medicamento desde el chat en cuatro toques: buscar, elegir,
  cantidad, confirmar. El lote lo propone el sistema (el que vence primero).
- Stock derivado de los movimientos, que son inmutables: un error se corrige
  con un movimiento inverso, nunca editando el original.
- Bloqueo automático de lotes vencidos y alerta diaria por Telegram de lo que
  está bajo el mínimo, lo que vence pronto y lo vencido sin dar de baja.
- Cola de tareas con reintentos, espera creciente y bandeja de fallidas.
- Copia de seguridad diaria automática con 14 días de retención.

## Puesta en marcha

Requiere Docker y Docker Compose.

```bash
cp .env.example .env
```

Complete `.env`. Los tres valores que no puede inventar:

| Variable | De dónde sale |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Hable con **@BotFather** en Telegram, envíe `/newbot`. |
| `TELEGRAM_BOT_USERNAME` | El nombre de usuario que eligió para el bot, sin arroba. |
| `SUPERADMIN_TELEGRAM_USER_ID` | Escríbale a **@userinfobot**; responde con su número. |

Las contraseñas genérelas con `openssl rand -base64 24`. Después:

```bash
docker compose up -d          # levanta todo
bash scripts/importar-n8n.sh  # carga los workflows del bot en n8n
bash scripts/configurar-bot.sh
bash scripts/cargar-demo.sh   # opcional: un día simulado para presentar
```

`configurar-bot.sh` imprime al final el enlace del QR de la entrada y la
dirección de la pantalla de sala de espera.

### Telegram necesita HTTPS

Telegram sólo entrega webhooks a direcciones HTTPS, así que en una máquina local
hace falta un túnel:

```bash
cloudflared tunnel --url http://localhost:5679
```

Ponga la URL `https://…` que imprime en `WEBHOOK_URL` dentro de `.env`, levante
de nuevo con `docker compose up -d` y vuelva a correr `configurar-bot.sh`.

### Puertos

Chasqui Pet convive con el Chasqui original en la misma máquina, así que sus
puertos están corridos. Se cambian en `.env`.

| Servicio | Puerto | Alcance |
|---|---|---|
| Pantalla y portal | 3100 | Toda la red local |
| n8n | 5679 | Sólo esta máquina |
| PostgreSQL | 5433 | Sólo esta máquina |

## Estructura

```
db/migrations/   Esquema, funciones y seeds. Se aplican solos al crear la base.
db/demo/         Datos de demostración.
n8n/workflows/   Workflows del bot y de los jobs, versionados.
worker/          Servicio que procesa la cola de tareas asíncronas.
web/             Next.js: pantalla pública y (más adelante) portal.
scripts/         Puesta en marcha, respaldos y utilidades.
docs/            Modelo de datos y documentación técnica.
```

## Operaciones frecuentes

```bash
docker compose logs -f worker        # ver la cola de tareas trabajando
docker compose ps                    # estado de los servicios
bash scripts/crear-superadmin.sh     # dar acceso al primer usuario
bash scripts/restaurar.sh <archivo>  # restaurar un respaldo
```

Los respaldos quedan en `backups/`, uno diario, con 14 días de retención.

## Dónde vive la lógica

En PostgreSQL. n8n recibe el webhook de Telegram, llama a una función SQL y
envía lo que esa función le indique: son cinco nodos y ninguna decisión de
negocio. Esto es deliberado — así el comportamiento del bot se puede probar con
`psql`, un reinicio de n8n no pierde ninguna conversación a medias, y cambiar un
menú no exige desplegar nada.

Los detalles del modelo y las decisiones de diseño están en
[`docs/modelo-datos.md`](docs/modelo-datos.md). La especificación completa del
producto está en [`chasquipet.md`](chasquipet.md).

## Advertencia legal

El sistema emite un **recibo interno consecutivo**, que no es un documento
tributario válido. En Colombia la facturación electrónica DIAN es obligatoria
para los prestadores de servicios veterinarios. Hay que integrarla antes de que
esto opere de verdad.
