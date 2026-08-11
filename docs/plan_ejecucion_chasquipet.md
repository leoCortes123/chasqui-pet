# PLAN DE EJECUCIÓN — CHASQUI PET
## Fase 1 (Presupuestos + Facturación DIAN vía Factus) + Fase 2 (Reserva + Carnet + Canal Cliente)
### Orden de ejecución por sesiones independientes — Sin fechas ni plazos
### Adaptado para modelo de IA nivel medio (GPT-3.5 / Claude Haiku / Llama 3 8B)

---

## 📋 ANTES DE EMPEZAR

### Sobre el portal administrativo
El portal web de Chasqui Pet **es exclusivamente administrativo**. No expone API pública. Los dueños de mascotas **no acceden al portal**. Toda la comunicación con el cliente final se hace por mensajería (Telegram hoy, WhatsApp en el futuro). El portal sirve para:
- Reportes y estadísticas
- Configuración (usuarios, permisos, tarifas, disponibilidad)
- Bandeja de consultas (borradores y firmadas)
- Inventario y compras
- Auditoría y tareas fallidas

**Regla de oro:** Todo lo que el dueño de la mascota necesita ver o hacer, va por Telegram (o WhatsApp futuro). Nada por el portal.

### Sobre Factus — ¿Cómo obtener las credenciales?

**NO se obtienen por API.** Debes registrarte manualmente en la plataforma de Factus (la credenciales se proporcionaran por el usuario, el agente debe seguir con el desarrollo y recordar que faltan las credenciales):

1. **Entra a** `https://www.factus.com.co` o `https://developers.factus.com.co`
2. **Crea una cuenta** como empresa veterinaria (o como desarrollador integrador)
3. **Solicita acceso a la API** — las credenciales (`client_id`, `client_secret`, `username`, `password`) las asigna el administrador del sistema de Factus, no se generan automáticamente cite🛠web_search:24#2:~:text=Credenciales: Se deben solicitar al administrador del sistema
4. **Configura tu empresa** en el panel de Factus: RUT, datos fiscales, responsabilidades, certificado digital
5. **Obtén rangos de numeración** autorizados por la DIAN (Factus puede ayudar con esto)
6. **Prueba en Sandbox** antes de producción

**Las credenciales van en `.env`**, NUNCA en el código ni en la base de datos.

```env
FACTUS_BASE_URL=https://api.factus.com.co
FACTUS_CLIENT_ID=[te lo da Factus]
FACTUS_CLIENT_SECRET=[te lo da Factus]
FACTUS_USERNAME=[tu usuario Factus]
FACTUS_PASSWORD=[tu contraseña Factus]
FACTUS_WEBHOOK_SECRET=[te lo da Factus para validar webhooks]
```

---

## 🏗️ ORDEN DE EJECUCIÓN POR SESIONES

Cada sesión es **independiente** y **no bloquea** a las siguientes. Puedes pausar entre sesiones sin riesgo. El orden está diseñado para que cada sesión construya sobre lo anterior sin crear dependencias circulares.

---

# ═══════════════════════════════════════════════════════════════
# FASE 1 — PRESUPUESTOS + FACTURACIÓN DIAN (FACTUS)
# ═══════════════════════════════════════════════════════════════

---

## SESIÓN 1: Esquema de Presupuestos (SQL puro)
**Qué hace:** Crea las tablas, triggers y funciones base para presupuestos.
**No toca:** Nada existente. Solo agrega tablas nuevas.
**Riesgo:** Cero. Es aditivo.

### Archivo a crear
`db/migrations/120_presupuestos.sql`

### Contenido mínimo
```sql
-- Tablas
CREATE TABLE presupuesto (...);
CREATE TABLE presupuesto_linea (...);
CREATE TABLE presupuesto_historial (...);

-- Trigger de recálculo
CREATE FUNCTION presupuesto_recalcular() ...;
CREATE TRIGGER tg_presupuesto_recalcular ...;

-- Funciones core
CREATE FUNCTION crear_presupuesto(...) ...;
CREATE FUNCTION agregar_linea_presupuesto(...) ...;
CREATE FUNCTION quitar_linea_presupuesto(...) ...;
CREATE FUNCTION enviar_presupuesto(...) ...;
CREATE FUNCTION aprobar_presupuesto(...) ...;
CREATE FUNCTION rechazar_presupuesto(...) ...;
CREATE FUNCTION convertir_presupuesto_cuenta(...) ...;
CREATE FUNCTION presupuesto_json(...) ...;
CREATE FUNCTION presupuestos_por_vencer(...) ...;
CREATE FUNCTION bot_presupuesto_texto(...) ...;
CREATE FUNCTION presupuesto_marcar_vencidos() ...;
```

### Seed de permisos (agregar a `100_seed_roles.sql` o ejecutar después)
```sql
INSERT INTO permiso (codigo, modulo, descripcion) VALUES
('presupuesto.crear', 'presupuesto', 'Crear presupuestos'),
('presupuesto.editar', 'presupuesto', 'Editar presupuestos'),
('presupuesto.enviar', 'presupuesto', 'Enviar presupuestos al dueño'),
('presupuesto.ver', 'presupuesto', 'Ver presupuestos'),
('presupuesto.aprobar', 'presupuesto', 'Aprobar presupuestos (rol dueño)');
```

### Test mínimo
```sql
SELECT crear_presupuesto('sede-uuid', 'dueno-uuid', 'paciente-uuid', 'vet-uuid', 'Cirugía de castración', 7, 'telegram');
```

**Cuando termines esta sesión:** Tienes presupuestos en la base de datos, operables solo por SQL. Nada de bot ni portal todavía.

---

## SESIÓN 2: Bot Telegram — Flujo de Presupuestos
**Qué hace:** El personal puede crear, enviar y gestionar presupuestos desde Telegram.
**Depende de:** Sesión 1 (tablas y funciones SQL listas).
**No toca:** Nada del portal web.

### Archivos a crear/modificar
- `db/migrations/020_identidad.sql` o nueva función: `bot_manejar_presupuesto` (agregar al router existente)
- Nuevas funciones SQL de bot: `bot_presupuesto_callback`, `bot_presupuesto_texto`

### Flujo a implementar (prefijo `pre:`)
1. `pre:nuevo` → inicia FSM (`conversacion_estado`: flujo='presupuesto', paso='dueno')
2. Paso "dueno": buscar dueño (reutilizar `buscar_dueno`)
3. Paso "paciente": buscar paciente (reutilizar `buscar_paciente`)
4. Paso "motivo": texto libre
5. Paso "agregar_linea": elegir servicio (tarifa) o medicamento → cantidad → confirmar
6. Paso "resumen": muestra `bot_presupuesto_texto` con botones "Enviar" / "Agregar otra línea" / "Cancelar"
7. `pre:env:<id>` → llama `enviar_presupuesto`, notifica al dueño
8. Dueño recibe mensaje con botones "Aprobar" (`pre:apr:<id>`) / "Rechazar" (`pre:rec:<id>`)
9. `pre:apr:<id>` → llama `aprobar_presupuesto` → encola `convertir_presupuesto_cuenta` → notifica al personal

### Worker — nueva tarea
- `enviar_presupuesto_telegram` (envía el presupuesto al dueño)
- `recordatorio_presupuesto_vencido` (job diario, marcar vencidos)

**Cuando termines esta sesión:** El personal opera presupuestos 100% por Telegram. El dueño aprueba/rechaza por Telegram.

---

## SESIÓN 3: Portal Web — Página de Presupuestos
**Qué hace:** Vista administrativa de presupuestos en el portal.
**Depende de:** Sesión 1 (datos existen).
**No toca:** El bot (ya funciona solo).

### Archivos a crear
- `web/src/app/presupuestos/page.tsx` — lista de presupuestos por estado
- `web/src/app/presupuestos/[id]/page.tsx` — detalle con acciones

### Funcionalidades
- Lista con filtros (estado, fecha, veterinario)
- Crear presupuesto (formulario: dueño, paciente, líneas)
- Ver detalle: líneas, totales, estado
- Acciones: enviar, aprobar, convertir a cuenta, anular
- Exportar a CSV (reutilizar patrón de reportes existentes)

**Cuando termines esta sesión:** El administrador puede ver y gestionar presupuestos desde el portal. El bot sigue funcionando independientemente.

---

## SESIÓN 4: Esquema DIAN + Factus (SQL puro)
**Qué hace:** Crea tablas para documentos electrónicos y configuración DIAN.
**No toca:** Nada existente. Solo agrega tablas.
**Riesgo:** Cero. Es aditivo.

### Archivo a crear
`db/migrations/130_dian_factus.sql`

### Contenido mínimo
```sql
-- Tabla de documentos electrónicos
CREATE TABLE documento_electronico (...);

-- Tabla de configuración DIAN por sede
CREATE TABLE config_dian (...);

-- Tabla de municipios DIAN (catálogo)
CREATE TABLE municipio_dian (...);
-- Seed: Bogotá (11001), Medellín (05001), Cali (76001), Barranquilla (08001), etc.

-- Funciones core
CREATE FUNCTION emitir_factura_factus(...) ...;
CREATE FUNCTION factus_mapear_cuenta(...) ...;
CREATE FUNCTION factus_mapear_customer(...) ...;
CREATE FUNCTION factus_mapear_items(...) ...;
CREATE FUNCTION dian_habilitada_para_sede(...) ...;
CREATE FUNCTION documento_electronico_json(...) ...;
```

### Seed de permisos
```sql
INSERT INTO permiso (codigo, modulo, descripcion) VALUES
('dian.emitir', 'dian', 'Emitir facturas DIAN'),
('dian.anular', 'dian', 'Anular facturas DIAN'),
('dian.configurar', 'dian', 'Configurar DIAN por sede'),
('dian.ver', 'dian', 'Ver documentos electrónicos');
```

**Cuando termines esta sesión:** Tienes el esquema listo para facturación, pero aún no emite nada. Necesitas la Sesión 5 para conectar con Factus.

---

## SESIÓN 5: Worker — Módulo Factus (Node.js)
**Qué hace:** Conecta Chasqui Pet con la API de Factus.
**Depende de:** Sesión 4 (tablas listas) + credenciales de Factus (obtenidas manualmente en su plataforma).
**No toca:** Ni bot ni portal. Es puramente backend.

### Archivos a crear
```
worker/src/factus/
├── auth.js          # OAuth2: obtenerToken(), refrescarToken(), cache en memoria
├── client.js        # POST /v2/bills, GET /v2/bills/{id}/pdf, GET /v2/bills/{id}/xml
├── mapper.js        # Mapear cuenta/customer/items de Chasqui Pet → JSON Factus
└── index.js         # Exporta todo
```

### Nueva tarea en worker
`worker/src/tareas/emitir_factus.js`

```javascript
// Pseudocódigo para el modelo
async function ejecutar(payload) {
  const { documento_id } = payload;

  // 1. Obtener token (cacheado en memoria, refrescar si 401)
  const token = await factusAuth.obtenerToken();

  // 2. Leer documento de BD
  const doc = await db.query('SELECT * FROM documento_electronico WHERE id = $1', [documento_id]);
  const cuenta = await db.query('SELECT factus_mapear_cuenta($1) as json', [doc.cuenta_id]);

  // 3. POST a Factus
  const resp = await fetch('https://api.factus.com.co/v2/bills', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(cuenta.json)
  });

  // 4. Manejar respuesta
  if (resp.status === 201 || resp.status === 200) {
    const data = await resp.json();
    // Guardar: factus_bill_id, cufe, qr_url, pdf_url, xml_url, factus_number
    await db.query('SELECT completar_documento_factus($1, $2)', [documento_id, JSON.stringify(data)]);
    // Encolar envío al dueño
    await db.query('SELECT encolar_tarea($1, $2, $3, $4)', ['enviar_factura_telegram', {documento_id}, 3, 'fact_tel_' + documento_id]);
  } else if (resp.status === 422) {
    const errors = await resp.json();
    await db.query('SELECT rechazar_documento_factus($1, $2)', [documento_id, JSON.stringify(errors)]);
    // Notificar superadmin
  } else if (resp.status === 429) {
    const retryAfter = resp.headers.get('Retry-After') || 60;
    throw new Error(`Rate limit. Reintentar en ${retryAfter}s`);
  } else {
    throw new Error(`HTTP ${resp.status}`);
  }
}
```

### Reglas del módulo Factus
- **Cachear token en memoria** (variable global del worker). No solicitar token nuevo en cada factura.
- **Rate limiting:** Máximo 80 req/min. Si 429, leer `Retry-After` y esperar.
- **Idempotencia:** Usar siempre `reference_code = 'doc_' || documento_electronico.id`.
- **Reintentos:** Backoff exponencial (30s, 2min, 5min, 15min, 30min). Máximo 5 intentos.
- **Errores 422:** No reintentar. Notificar superadmin con detalle.

**Cuando termines esta sesión:** El worker puede emitir facturas DIAN vía Factus, pero nadie lo está llamando todavía. Eso viene en la Sesión 6.

---

## SESIÓN 6: Bot Telegram — Emisión de Factura DIAN en el flujo de Cobro
**Qué hace:** Al cerrar una cuenta, el sistema pregunta si se emite factura DIAN.
**Depende de:** Sesión 4 (esquema) + Sesión 5 (worker conectado a Factus).
**No toca:** El portal (eso es la Sesión 7).

### Modificaciones
- Función `cerrar_cuenta` o flujo `cob:` en el bot:
  - Después de cerrar la cuenta, si `dian_habilitada_para_sede(sede_id)`:
    - Mostrar botón: "Emitir factura DIAN" (`fac:emi:<cuenta_id>`)
    - Botón alternativo: "Solo recibo interno" (comportamiento actual)
  - `fac:emi:<cuenta_id>` → llama `emitir_factura_factus(cuenta_id, ...)` → crea documento en 'pendiente' → encola `emitir_factus`

- Worker tarea `enviar_factura_telegram`:
  - Cuando el documento pasa a 'aceptado', enviar al dueño:
    - Texto: "Tu factura DIAN está lista. Número: FV-001-0000123. CUFE: A1B2..."
    - Botones: "Ver PDF" (link) / "Ver XML" (link)

**Cuando termines esta sesión:** El flujo de cobro completo funciona: cuenta → cierre → factura DIAN opcional → notificación al dueño.

---

## SESIÓN 7: Portal Web — Configuración DIAN + Bandeja de Documentos
**Qué hace:** El administrador configura DIAN por sede y ve el estado de las facturas.
**Depende de:** Sesión 4 (tablas).
**No toca:** Ni bot ni worker (ya funcionan solos).

### Archivos a crear
- `web/src/app/admin/dian/page.tsx` — configuración por sede
- `web/src/app/admin/dian/documentos/page.tsx` — lista de documentos electrónicos

### Funcionalidades
- **Configuración:** habilitar/deshabilitar DIAN por sede, prefijo, régimen, responsabilidad fiscal
- **Bandeja:** lista de documentos por estado (pendiente, enviado, aceptado, rechazado, anulado)
- **Acciones:** reenviar, anular, descargar PDF/XML
- **Detalle:** CUFE, QR, número de factura, respuesta de Factus

**Cuando termines esta sesión:** El administrador tiene control total sobre la facturación DIAN desde el portal.

---

## SESIÓN 8: Webhook de Factus (Opcional pero recomendado)
**Qué hace:** Factus notifica en tiempo real cuando DIAN valida o rechaza una factura.
**Depende de:** Sesión 5 (worker ya emite).
**No toca:** Nada anterior si no se implementa (es opcional).

### Archivo a crear
- `web/src/app/api/factus/webhook/route.ts`

### Funcionalidad
- Recibe POST de Factus con evento `bill.validated` o `bill.rejected`
- Valida firma HMAC con `FACTUS_WEBHOOK_SECRET`
- Actualiza `documento_electronico.estado` en BD
- Si rechazado: notifica superadmin

**Cuando termines esta sesión:** El sistema se actualiza automáticamente cuando DIAN responde, sin necesidad de sondear.

---

## SESIÓN 9: Reportes + Pulido Fase 1
**Qué hace:** Agrega reportes de presupuestos y DIAN, pulido general.
**Depende de:** Todo lo anterior (datos existen).
**No toca:** Lógica de negocio. Solo lectura.

### Reportes nuevos (agregar a `web/src/lib/reportes.ts`)
- `presupuestos`: por estado, veterinario, sede, tasa de conversión
- `dian`: facturas emitidas, rechazadas, por sede, totales

### Pulido
- Validaciones: no emitir DIAN sin NIT del dueño, no presupuesto sin líneas
- Mensajes de error claros en el bot
- Manejo de edge cases: Factus caído, dueño sin teléfono

**Cuando termines esta sesión:** Fase 1 está completa y pulida.

---

# ═══════════════════════════════════════════════════════════════
# FASE 2 — RESERVA ONLINE + CARNET DIGITAL + CANAL CLIENTE
# ═══════════════════════════════════════════════════════════════

---

## SESIÓN 10: Esquema de Citas y Disponibilidad (SQL puro)
**Qué hace:** Completa las tablas `cita` y `disponibilidad` que ya existen pero están vacías.
**No toca:** Nada existente. Es aditivo.

### Archivo a crear
`db/migrations/140_citas.sql`

### Contenido mínimo
```sql
-- Complementar tablas existentes
ALTER TABLE cita ADD COLUMN IF NOT EXISTS ...;
ALTER TABLE disponibilidad ADD COLUMN IF NOT EXISTS ...;

-- Índices
CREATE INDEX ...;

-- Vista de slots
CREATE VIEW v_slots_disponibles AS ...;

-- Funciones
CREATE FUNCTION crear_disponibilidad(...) ...;
CREATE FUNCTION eliminar_disponibilidad(...) ...;
CREATE FUNCTION slots_disponibles(...) ...;
CREATE FUNCTION crear_cita(...) ...;
CREATE FUNCTION confirmar_cita(...) ...;
CREATE FUNCTION cancelar_cita(...) ...;
CREATE FUNCTION reprogramar_cita(...) ...;
CREATE FUNCTION citas_por_fecha(...) ...;
CREATE FUNCTION bot_cita_texto(...) ...;
```

### Seed de permisos
```sql
INSERT INTO permiso (codigo, modulo, descripcion) VALUES
('cita.ver', 'cita', 'Ver citas'),
('cita.crear', 'cita', 'Crear citas'),
('cita.cancelar', 'cita', 'Cancelar citas'),
('cita.reprogramar', 'cita', 'Reprogramar citas'),
('disponibilidad.configurar', 'cita', 'Configurar disponibilidad');
```

**Cuando termines esta sesión:** Tienes el calendario de citas operable por SQL. Nada de bot ni web pública todavía.

---

## SESIÓN 11: Bot Telegram — Flujo de Reserva (para dueños)
**Qué hace:** El dueño puede reservar cita desde Telegram.
**Depende de:** Sesión 10 (tablas listas).
**No toca:** El portal web.

### Flujo a implementar (prefijo `cit:`)
1. Dueño escribe `/reservar` o toca botón en su menú
2. FSM (`conversacion_estado`: flujo='cita', paso='sede')
3. Paso "sede": seleccionar sede (si hay varias)
4. Paso "fecha": mostrar fechas disponibles (próximos 7 días)
5. Paso "slot": mostrar slots disponibles (usa `slots_disponibles`)
6. Paso "paciente": seleccionar mascota o crear nueva
7. Paso "motivo": texto libre
8. Paso "confirmar": resumen con botón "Confirmar" (`cit:conf:<codigo>`)
9. Al confirmar: crea cita en 'pendiente' → envía código de confirmación

### Worker — nueva tarea
- `enviar_confirmacion_cita`: envía código al dueño
- `recordatorio_cita_24h`: 24h antes
- `recordatorio_cita_2h`: 2h antes

**Cuando termines esta sesión:** Los dueños reservan citas por Telegram.

---

## SESIÓN 12: Portal Web — Configuración de Disponibilidad
**Qué hace:** El admin configura horarios de atención por consultorio/veterinario.
**Depende de:** Sesión 10 (tablas listas).
**No toca:** El bot (ya funciona solo).

### Archivo a crear
- `web/src/app/admin/disponibilidad/page.tsx`

### Funcionalidades
- Calendario semanal por consultorio
- Agregar/eliminar franjas horarias
- Definir duración de slot (15, 30, 45, 60 min)
- Asignar veterinario a franja
- Activar/desactivar franjas

**Cuando termines esta sesión:** El admin controla cuándo se pueden agendar citas.

---

## SESIÓN 13: Esquema de Carnet Digital (SQL puro)
**Qué hace:** Crea tablas para carnets digitales con QR.
**No toca:** Nada existente. Es aditivo.

### Archivo a crear
`db/migrations/150_carnet.sql`

### Contenido mínimo
```sql
CREATE TABLE carnet_digital (...);
CREATE TABLE carnet_registro (...);

CREATE FUNCTION generar_carnet(...) ...;
CREATE FUNCTION registrar_en_carnet(...) ...;
CREATE FUNCTION carnet_json(...) ...;
CREATE FUNCTION carnet_por_codigo(...) ...;
CREATE FUNCTION proximos_vencimientos_carnet(...) ...;
CREATE FUNCTION bot_carnet_texto(...) ...;
```

**Cuando termines esta sesión:** Tienes carnets operables por SQL.

---

## SESIÓN 14: Worker — Generación de PDF del Carnet
**Qué hace:** Genera PDF del carnet con QR.
**Depende de:** Sesión 13 (tablas listas).
**No toca:** Ni bot ni portal todavía.

### Archivos a crear
- `worker/src/tareas/generar_pdf_carnet.js`

### Implementación
- Instalar `pdf-lib` (más ligero que puppeteer) o `puppeteer` si necesitas HTML complejo
- Template HTML del carnet: logo, datos del paciente, tabla de registros
- Generar QR con código único (ej. `qrcode` npm)
- Guardar PDF en `/backups/carnets/` o volumen Docker
- Actualizar `carnet_digital.url_publica`

**Cuando termines esta sesión:** El worker puede generar carnets en PDF.

---

## SESIÓN 15: Bot Telegram — Carnet del Dueño
**Qué hace:** El dueño ve y comparte el carnet de su mascota por Telegram.
**Depende de:** Sesión 13 + 14.
**No toca:** El portal.

### Flujo
- Dueño toca "Mi carnet" en su menú
- Selecciona mascota
- Bot muestra resumen del carnet con botón "Ver carnet completo"
- Botón genera/actualiza PDF → envía archivo o enlace
- Botón "Compartir" → envía código QR y URL pública

### Trigger automático
- Al firmar consulta con vacuna: registrar automáticamente en `carnet_registro`
- Al crear entrada de vacuna en inventario: disponible para carnet

**Cuando termines esta sesión:** Los dueños tienen carnet digital accesible por Telegram.

---

## SESIÓN 16: Página Pública del Carnet (sin auth)
**Qué hace:** Cualquiera con el QR puede ver el carnet.
**Depende de:** Sesión 13 (tablas).
**No toca:** Nada autenticado.

### Archivo a crear
- `web/src/app/carnet/[codigo]/page.tsx`

### Funcionalidad
- Ruta pública, sin autenticación
- Lee `carnet_por_codigo(codigo_qr)`
- Muestra datos del paciente y registros
- Responsive, imprimible
- No expone datos sensibles del dueño (solo nombre y teléfono de contacto)

**Cuando termines esta sesión:** El carnet es verificable públicamente con el QR.

---

## SESIÓN 17: Canal del Cliente — Menú del Dueño en Telegram
**Qué hace:** El dueño tiene su propio menú completo en el bot.
**Depende de:** Sesiones 11 y 15 (reserva y carnet listos).
**No toca:** El portal.

### Detección de modo dueño
- Si `chat_id` está en `dueno.telegram_chat_id` y NO en `usuario.telegram_user_id` → modo dueño
- Menú: "Mis mascotas", "Mis citas", "Mi carnet", "Reservar", "Mis facturas"

### Flujos
- `dueno:mascotas` → lista de pacientes vinculados a su teléfono
- `dueno:citas` → próximas citas confirmadas
- `dueno:facturas` → documentos electrónicos de sus cuentas (links a PDF)
- `dueno:reservar` → reutiliza flujo `cit:`
- `dueno:carnet` → reutiliza flujo de carnet

**Cuando termines esta sesión:** El dueño tiene un canal completo de self-service por Telegram.

---

## SESIÓN 18: Marketing Automatizado (Jobs)
**Qué hace:** Campañas de retención automáticas.
**Depende de:** Sesiones 11, 13, 17 (datos de citas y carnets existen).
**No toca:** Nada anterior si no se activa.

### Jobs nuevos (n8n o worker)
- `cumpleanos_mascota`: diario. Busca `fecha_nacimiento = hoy` → envía felicitación + descuento
- `campana_vacunacion`: diario. Busca `carnet_registro.fecha_proxima < hoy + 7 días` → recordatorio
- `reactivacion_cliente`: semanal. Busca dueños sin visita en 6 meses → oferta de retorno

### Configuración en portal
- `web/src/app/admin/marketing/page.tsx`: activar/desactivar campañas, editar mensajes

**Cuando termines esta sesión:** El sistema fideliza clientes automáticamente.

---

## SESIÓN 19: Reportes Fase 2 + Pulido General
**Qué hace:** Agrega reportes de citas, carnets y canal cliente.
**Depende de:** Todo lo anterior.
**No toca:** Lógica de negocio.

### Reportes nuevos
- `citas`: por estado, sede, tasa de asistencia, cancelaciones
- `carnets`: generados, registros, vacunas vencidas
- `canal_cliente`: interacciones del bot del dueño

### Pulido
- Manejo de errores: slot ya tomado, cita duplicada
- Fallback del bot: si no entiende, ofrecer menú
- Rate limiting en endpoints públicos

**Cuando termines esta sesión:** Fase 2 está completa y pulida.

---

## SESIÓN 20: WhatsApp (Futuro — no bloqueante)
**Qué hace:** Prepara la arquitectura para soportar WhatsApp además de Telegram.
**Depende de:** Nada. Es aditivo.
**No toca:** Nada de Telegram.

### Consideraciones de diseño
- La tabla `dueno` ya tiene `telegram_chat_id`. Agregar `whatsapp_phone` opcional.
- La tabla `tarea_async` ya es agnóstica del canal. Las tareas `enviar_*` pueden elegir canal.
- n8n puede recibir webhooks de WhatsApp Business API (meta) o de proveedores como Twilio, Wavy, etc.
- El bot de Telegram sigue siendo el principal. WhatsApp es canal secundario.

**No implementar aún.** Solo documentar la extensión en el README.

---

# ═══════════════════════════════════════════════════════════════
# ANEXOS
# ═══════════════════════════════════════════════════════════════

---

## ANEXO A: Variables de entorno nuevas

Agregar al `.env` y `.env.example`:

```env
# === FACTUS (DIAN) ===
FACTUS_BASE_URL=https://api.factus.com.co
FACTUS_CLIENT_ID=[MASKED]
FACTUS_CLIENT_SECRET=[MASKED]
FACTUS_USERNAME=[MASKED]
FACTUS_PASSWORD=[MASKED]
FACTUS_WEBHOOK_SECRET=[MASKED]

# === PDF (Carnet) ===
# Si usas puppeteer:
# PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
```

---

## ANEXO B: Estructura de carpetas nueva

```
chasquipet/
├── db/
│   └── migrations/
│       ├── 120_presupuestos.sql          # Sesión 1
│       ├── 130_dian_factus.sql           # Sesión 4
│       ├── 140_citas.sql                 # Sesión 10
│       └── 150_carnet.sql                # Sesión 13
├── worker/
│   └── src/
│       ├── factus/                       # Sesión 5
│       │   ├── auth.js
│       │   ├── client.js
│       │   └── mapper.js
│       └── tareas/
│           ├── emitir_factus.js          # Sesión 5
│           ├── enviar_presupuesto.js     # Sesión 2
│           └── generar_pdf_carnet.js     # Sesión 14
├── web/
│   └── src/
│       └── app/
│           ├── presupuestos/             # Sesión 3
│           ├── admin/
│           │   └── dian/                 # Sesión 7
│           │       └── page.tsx
│           ├── admin/
│           │   └── disponibilidad/       # Sesión 12
│           │       └── page.tsx
│           ├── admin/
│           │   └── marketing/            # Sesión 18
│           │       └── page.tsx
│           ├── carnet/                   # Sesión 16
│           │   └── [codigo]/
│           │       └── page.tsx
│           └── api/
│               └── factus/
│                   └── webhook/
│                       └── route.ts      # Sesión 8
└── n8n/
    └── workflows/
        ├── 05-job-dian.json              # Sesión 6
        └── 06-job-citas.json             # Sesión 11
```

---

## ANEXO C: Prompts recomendados para OpenCode (modelo nivel medio)

### Para funciones SQL
```
Escribe una función PL/pgSQL llamada [nombre] que [descripción].
Reglas:
- Usa exigir_permiso('[modulo].[accion]') al inicio
- Usa auditar(...) en cada escritura
- Devuelve JSONB: {"ok": true, "datos": {...}} o {"ok": false, "motivo": "..."}
- Idempotente: ON CONFLICT o clave de unicidad
- Maneja errores: RAISE EXCEPTION USING errcode='P0001', hint='...'
- Comenta en español
- NO modifica tablas existentes. Solo usa tablas nuevas.
```

### Para flujos de bot
```
Escribe el flujo de conversación para el módulo [modulo] en Telegram.
Reglas:
- Usa conversacion_estado (flujo, paso, datos) con TTL 2h
- Callbacks con prefijo [prefijo]:
- JSONB de acciones: [{"tipo":"enviar","chat_id":...,"texto":"...","botones":[[...]]}]
- Usa esc() para escape HTML
- Confirmación obligatoria antes de escritura
- NO generar HTML complejo
```

### Para route handlers Next.js
```
Escribe un route handler en Next.js App Router para [ruta].
Reglas:
- runtime='nodejs', force-dynamic
- Valida inputs con Zod
- Llama función SQL de PostgreSQL
- Response.json()
- Rate limiting por IP si es público
```

### Para integración Factus
```
Escribe una función Node.js para [acción] con la API de Factus.
Reglas:
- Base URL: https://api.factus.com.co
- OAuth2 password grant
- Cachear token en memoria (variable global), refrescar solo si 401
- Headers: Authorization: Bearer <token>, Content-Type: application/json
- Rate limit (80 req/min): si 429, leer Retry-After, esperar, reintentar
- Errores 422: NO reintentar, devolver errores al caller
- Errores 500+: reintentar con backoff (30s, 2min, 5min, 15min, 30min), máx 5 intentos
- Usar reference_code único por documento
- NO hardcodear credenciales
```

---

## ANEXO D: Checklist de habilitación DIAN con Factus (pasos legales)

- [ ] Crear cuenta en `https://www.factus.com.co`
- [ ] Solicitar acceso a la API (credenciales las da el admin de Factus)
- [ ] Configurar empresa: RUT, datos fiscales, responsabilidades, certificado digital
- [ ] Obtener rangos de numeración autorizados por DIAN
- [ ] Realizar pruebas en Sandbox de Factus
- [ ] Obtener número de habilitación DIAN
- [ ] Configurar webhook apuntando a tu URL de producción
- [ ] Activar modo producción en Factus
- [ ] Capacitar al personal en el flujo de facturación

---

**Fin del plan de ejecución.**
