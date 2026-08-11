# Chasqui Pet

Sistema de gestión para clínica veterinaria, operado principalmente desde
Telegram. Sistema nuevo e independiente: no comparte código ni base de datos con
Chasqui.

> **Estado: terminado (paso 8 de 8).** Están terminados el esquema base con identidad, roles
> y permisos, el módulo de turnos, el de inventario, el clínico —dueños,
> pacientes e historia clínica, por chat y por formulario web—, el de cobro
> —cuenta, descuentos, pagos, recibo y cierre de caja—, el de compras
> —proveedores y entradas de mercancía con soporte— y el portal administrativo
> con los nueve reportes. Los jobs, los respaldos, los datos de demostración y la
> guía de operación para el personal están al día.

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
- Dueños y pacientes: alta desde el chat en seis toques, búsqueda tolerante a
  errores de tipeo —por mascota, por dueño o por teléfono— y aviso de posible
  duplicado antes de crear.
- Consulta clínica desde Telegram: botones para todo lo enumerable, guardado
  como borrador en cada paso y firma explícita. Sin motivo, diagnóstico y
  tratamiento no se puede firmar; una vez firmada no se edita, se le agrega una
  adenda.
- El mismo formulario completo en el portal web, con la historia clínica del
  paciente en línea de tiempo.
- Ingreso al portal con el Telegram del personal: código de seis dígitos,
  confirmación en el bot y aviso al usuario cada vez que se abre una sesión.
- Ingreso también al revés, desde el chat: el botón «Entrar al portal» del menú
  devuelve un enlace de un solo uso, válido cinco minutos, que abre el portal ya
  autenticado sin teclear el código.
- Resumen de la consulta al dueño por Telegram al firmarla, sólo si dio su
  consentimiento (Ley 1581 de 2012), con mecanismo de supresión de sus datos.
- La cuenta se abre sola cuando el turno entra en atención, y cada medicamento
  despachado cae en ella al precio del catálogo sin que nadie lo teclee.
- Cobro desde el chat en tres toques: elegir la cuenta, el medio de pago y
  cerrar. El valor no se pregunta: por defecto es lo que falta, y en efectivo se
  acepta de más y se informa el cambio.
- Descuento con motivo escrito y responsable, sólo para quien tiene el permiso.
  Nunca borra ni edita líneas: el subtotal se conserva y la rebaja va aparte.
- Pagos y descuentos de sólo agregar: un error se corrige con un reverso, que
  también queda. Anular una cuenta cerrada revierte sus pagos y la caja sigue
  cuadrando.
- Recibo consecutivo al cerrar, enviado al Telegram del dueño si dio su
  consentimiento. Es un documento interno y lo dice: no es factura electrónica.
- Caja del día con base, esperado y contado; el cierre no deja cuadrar si quedan
  cuentas con saldo, y avisa al administrador si hay diferencia.
- Registro de la compra que llegó, desde el chat: proveedor, renglones con lote
  y vencimiento, y la foto de la factura mandada al chat como un mensaje más.
- Nada entra al inventario hasta confirmar: la factura se digita en borrador, se
  corrige a gusto, y al confirmar entra completa o no entra nada.
- Cada lote sabe de qué compra y de qué proveedor vino, así que se puede
  responder quién recibió un lote concreto el día que haya un retiro de producto.
- Portal web con panel del día —cola por consultorio, caja y stock crítico—,
  catálogo de precios editable en la misma tabla y libro de movimientos.
- Los nueve reportes: stock, consumo, turnos por día y por hora, ocupación,
  caja, descuentos, margen contra el costo del lote que salió, compras,
  consultas, diagnósticos y pacientes. Todos con filtro de fechas y CSV.
- Trazabilidad de lote en el portal: se escribe el número impreso en la caja y
  sale la lista de dueños a los que hay que llamar, con su teléfono.
- Administración: personal y permisos, configuración operativa y tarifas en
  caliente, auditoría de sólo lectura y bandeja de tareas fallidas.
- Cola de tareas con reintentos, espera creciente y bandeja de fallidas.
- Copia de seguridad diaria automática con 14 días de retención.
- Limpieza diaria de lo que crece sin aportar —updates de Telegram,
  conversaciones vencidas, tareas ya completadas—. La auditoría y los
  movimientos de inventario no se purgan nunca.

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

El portal está en `http://<esta-máquina>:3100/entrar`. No pide contraseña:
muestra un código, se confirma desde el bot con el Telegram del propio usuario y
la sesión queda abierta 30 días. Quien no esté aprovisionado como usuario no
entra, y el bot no le dice si el código era válido.

### Salir a internet

Telegram sólo entrega webhooks a direcciones HTTPS, y el portal tiene que poder
abrirse desde afuera de la clínica —el enlace de ingreso que manda el bot no
sirve de nada si sólo funciona dentro de la LAN—. Ambas cosas salen por la misma
puerta:

```bash
docker compose --profile local up -d
```

Eso levanta tres piezas más:

- **proxy** (Caddy): `/webhook/*` va a n8n y todo lo demás al portal, bajo un
  mismo hostname. El editor de n8n no se enruta: la URL pública no llega a él.
- **cloudflared**: el túnel HTTPS hacia el proxy.
- **registrador**: descubre la dirección del túnel, re-registra el webhook de
  Telegram y la escribe en `config.portal_url`, que es de donde el bot saca el
  enlace del portal. Un túnel rápido cambia de dirección en cada arranque y esto
  lo absorbe solo; ya no hay que editar `.env` ni volver a correr nada.

Con dominio propio se llena `WEBHOOK_URL_FIJA` en `.env` y el registrador usa esa
dirección tal cual, sin adivinar.

Para ver la dirección pública del momento:

```bash
docker compose logs registrador --tail 5
```

### Puertos

Chasqui Pet convive con el Chasqui original en la misma máquina, así que sus
puertos están corridos. Se cambian en `.env`.

| Servicio | Puerto | Alcance |
|---|---|---|
| Pantalla y portal | 3100 | Toda la red local |
| Proxy público | 8081 | Sólo esta máquina (afuera se sale por el túnel) |
| n8n | 5679 | Sólo esta máquina |
| PostgreSQL | 5433 | Sólo esta máquina |

## Estructura

```
db/migrations/   Esquema, funciones y seeds. Se aplican solos al crear la base.
db/demo/         Datos de demostración.
n8n/workflows/   Workflows del bot y de los jobs, versionados.
worker/          Servicio que procesa la cola de tareas asíncronas.
web/             Next.js: pantalla pública, ingreso y portal clínico.
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

## Para el personal de la clínica

[`docs/guia-operacion.md`](docs/guia-operacion.md) — cómo se usa el sistema día a
día, sin una sola palabra técnica: la cola, la consulta, la salida de
medicamentos, el cobro, el cierre de caja y qué hacer cuando algo sale mal.

## Comandos del bot

| Comando | Para qué |
|---|---|
| `/menu` | Menú principal, armado según los permisos de quien escribe. |
| `/cola` | Pacientes en espera. |
| `/stock` | Existencias y alertas de inventario. |
| `/entrada` | Registrar una compra que llegó. |
| `/proveedores` | Proveedores y su última compra. |
| `/cobrar` | Cuentas abiertas por cobrar. |
| `/caja` | Estado de la caja del día. |
| `/sesiones` | Sesiones abiertas en el portal, con opción de revocarlas. |
| `/ayuda` | La lista de arriba. |

## Advertencia legal

El sistema emite un **recibo interno consecutivo**, que no es un documento
tributario válido. En Colombia la facturación electrónica DIAN es obligatoria
para los prestadores de servicios veterinarios. Hay que integrarla antes de que
esto opere de verdad.
