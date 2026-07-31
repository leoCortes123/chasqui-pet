# Prompt para Claude Code — Chasqui Pet (MVP Clínica Veterinaria)

> Bloques marcados `[CONFIRMAR]` requieren una decisión pendiente. Todo lo demás está cerrado.

---

## 1. Contexto

**Chasqui Pet** es un sistema nuevo e independiente (no comparte código ni base de datos con Chasqui). Sirve a una **clínica veterinaria en Bogotá, Colombia**.

Filosofía de interfaz, heredada de Chasqui:

- **Telegram es la interfaz primaria de operación.** Todo registro y manipulación del día a día se hace por chat, con botones explícitos y entradas de texto cortas.
- **El portal web es secundario**: visualización, dashboards, reportes, y las operaciones que son incómodas en un chat (catálogos, textos largos, correcciones, auditoría, configuración).
- **La autenticación al portal web es exclusivamente vía Telegram.** No existe login con usuario/contraseña.

Operación real de la clínica:

- Los dueños llegan **sin cita previa**, por orden de llegada.
- Se atiende por turnos en **dos consultorios**, se diagnostica y se trata en sitio.
- Cuando se requieren exámenes que la clínica no hace, se **remite** al dueño a un laboratorio externo; el paciente regresa con resultados y se continúa el tratamiento.
- **Se cobra** por consulta y procedimientos. El grueso del ingreso está en la **venta de medicamentos**.
- Volumen: hasta **100 pacientes en un día pico**.

Los dos dolores más graves hoy son **inventario de medicamentos** y **control de turnos**. El MVP resuelve eso, más el cobro, que es indispensable si hay dinero de por medio.

Estado actual: **es un demo para presentar al cliente**. Debe ser funcional de punta a punta, corriendo local, no una maqueta.

---

## 2. Stack y principios de ingeniería

### 2.1 Stack

| Componente | Elección | Razón |
|---|---|---|
| Base de datos | **PostgreSQL 16** | Fuente única de verdad. Toda la lógica de negocio vive aquí como datos. |
| Orquestación | **n8n** (self-hosted) | Requerido. Capa delgada: recibe webhooks, llama funciones SQL, despacha jobs. |
| Portal web + pantalla | **Next.js (App Router) + TypeScript** | Server-rendered, sin SPA compleja. Read-mostly. |
| Empaquetado | **Docker Compose** | Un solo `docker compose up`. |
| Exposición | Local, red LAN | `[CONFIRMAR]` hosting posterior. |

Sin servicios de IA, sin transcripción, sin dependencias externas de pago. Todo el sistema es Postgres + n8n + Next.js.

### 2.2 "A prueba de fallas" — requisitos concretos

Esto no es una aspiración, es una lista de verificación:

1. **n8n no guarda estado.** Todo el estado conversacional vive en la tabla `conversacion_estado` de Postgres. Si n8n se reinicia a mitad de un flujo, el usuario continúa donde iba.
2. **Idempotencia del webhook de Telegram.** Tabla `telegram_update` con `update_id` como PK. Si llega un update repetido, se descarta antes de procesar. Telegram reintenta; sin esto se duplican turnos y movimientos de inventario.
3. **El webhook responde en < 1 segundo.** Todo trabajo diferido (generación de recibos, notificaciones masivas, reportes) se encola en `tarea_async` y lo procesa un worker.
4. **Cola de tareas con reintentos y dead letter.** `tarea_async(id, tipo, payload, estado, intentos, max_intentos, proxima_ejecucion, ultimo_error)`. Backoff exponencial. Al agotar intentos pasa a `fallida` y notifica al superadmin.
5. **Concurrencia en la cola de turnos.** Con dos consultorios, dos veterinarios pueden presionar "Llamar siguiente" en el mismo instante. La selección **debe** usar `SELECT … FOR UPDATE SKIP LOCKED` dentro de transacción. Nunca dos consultorios con el mismo turno.
6. **Numeración de turnos sin colisión.** Secuencia diaria generada con advisory lock de Postgres (`pg_advisory_xact_lock`), no con `MAX(numero)+1`.
7. **Movimientos de inventario en transacción.** Verificar existencia, insertar movimiento y actualizar caché del lote es atómico. Constraint `CHECK (cantidad_actual >= 0)` en `lote`.
8. **Movimientos y auditoría son append-only.** Revocar `UPDATE`/`DELETE` a nivel de rol de base de datos sobre `movimiento_inventario` y `evento_auditoria`. La corrección se hace con un movimiento inverso, no editando el original.
9. **Toda operación con dinero o con inventario exige confirmación explícita** antes de persistir.
10. **Backup automático**: `pg_dump` diario comprimido a disco local, con retención de 14 días. Es un demo, pero si se aprueba se vuelve producción sin avisar. Ocurre siempre.
11. **Health checks** en cada servicio del compose y un endpoint `/health` que verifica Postgres y n8n.

---

## 3. Alcance

### En el MVP

1. Turnos por orden de llegada, dos consultorios.
2. Inventario de medicamentos con lotes, vencimientos y trazabilidad.
3. Pacientes, dueños e historia clínica.
4. **Cobro**: cuenta por atención, medios de pago, descuentos, recibo, cierre de caja.
5. Proveedores y entradas de inventario por compra.
6. Reportes básicos.
7. Portal web administrativo con autenticación por Telegram.
8. Pantalla pública de turnos.

### Fuera del MVP — modelar el terreno, no implementar

- **Agendamiento de citas.** Crear las tablas `tipo_servicio`, `disponibilidad` y `cita` en el esquema, sin exponerlas en la UI. Un turno y una cita deben converger en la misma `consulta`, para que activar citas después no reescriba el módulo de turnos.
- **Facturación electrónica DIAN.** El MVP emite recibo interno consecutivo. Ver la advertencia en §7.4.
- Captura de historia clínica por audio.
- Kiosco en tablet (el modelo de datos ya soporta el canal `tablet_kiosco`).
- Hospitalización, laboratorio interno, app para el dueño, marketing.
- Órdenes de compra formales, cuentas por pagar.
- Migración de datos históricos.
- **Medicamentos de control especial.** No implementar ni modelar. `[CONFIRMAR]` pendiente con el cliente; si aplican, el Fondo Nacional de Estupefacientes exige un libro con formato propio y eso es un módulo aparte, no una columna booleana.

---

## 4. Roles y permisos

Los permisos se almacenan **como datos** en Postgres (`rol`, `permiso`, `rol_permiso`, `usuario_rol`). Nunca hardcodeados en código ni en workflows de n8n.

| Rol | Qué hace |
|---|---|
| `superadmin` | Leonardo. Acceso técnico total, configuración del sistema, gestión de la clínica, auditoría y tareas fallidas. Creado por seed. |
| `admin` | Administrador de la clínica. Gestiona usuarios y roles, catálogo de medicamentos y precios, proveedores, ajustes y bajas de inventario, tarifas, cierre de caja, todos los reportes, configuración operativa. |
| `veterinario` | Se asigna a un consultorio, llama y cierra turnos, crea y firma consultas, registra salidas de medicamento **vinculadas a una consulta**, consulta stock, registra remisiones externas. **No** hace entradas ni ajustes de inventario, **no** recibe pagos. |
| `auxiliar` | Crea turnos manuales, marca ausencias, registra dueños y mascotas, **recibe pagos y cierra caja**, registra entradas de inventario si el admin lo habilita. **No** crea ni firma diagnósticos. |
| `recepcion` | Solo lectura de la cola, creación de turnos manuales, registro básico de dueños y mascotas. |

Reglas transversales:

- Un usuario existe solo si un `superadmin` o `admin` lo aprovisionó asociando su `telegram_user_id`. **Nadie se autoregistra.**
- El `superadmin` inicial se crea por seed con el `telegram_user_id` en variable de entorno.
- **Separación de funciones**: quien da salida al medicamento (veterinario) no es quien recibe el dinero (auxiliar).
- Todo cambio en inventario, consultas y pagos escribe en `evento_auditoria`.

---

## 5. Módulo de Turnos

### 5.1 Modelo

```
consultorio
  id, sede_id, nombre ("Consultorio 1", "Consultorio 2"), activo

turno
  id, codigo ("A-042"), sede_id, fecha (date), numero_secuencial (int)
  tipo_servicio_id             -- consulta general, vacunación, control/curación, urgencia
  estado                       -- ver máquina de estados
  prioridad (int, default 0)   -- >0 adelanta en la cola
  canal_origen                 -- qr_telegram | recepcion_manual | tablet_kiosco (reservado)
  telegram_chat_id (nullable)
  dueno_id, paciente_id, consulta_id, cuenta_id (todos nullable)
  consultorio_id (nullable)    -- se asigna al llamar
  veterinario_id (nullable)
  veces_llamado (int default 0)
  created_at, llamado_at, en_atencion_at, finalizado_at
  notas

sesion_consultorio             -- qué vet está en qué consultorio hoy
  id, consultorio_id, usuario_id, abierta_at, cerrada_at
```

### 5.2 Máquina de estados

```
en_espera ──llamar──> llamado ──se presenta──> en_atencion ──cerrar──> finalizado
                         │
                         ├──no se presenta──> ausente ──reencolar (máx 1)──> en_espera
                         └──cancelar──> cancelado
```

- `llamado` guarda `llamado_at` y `consultorio_id`. Si tras `timeout_llamado_seg` (config, default 180) nadie se presenta, el veterinario presiona **"No se presentó"** → `ausente`, y el sistema ofrece llamar al siguiente.
- Un `ausente` se reencola **una sola vez** (`max_reencolados`, config), al final de la cola, conservando su código.
- Orden de la cola: `prioridad DESC, numero_secuencial ASC`.
- Numeración reinicia **diariamente a las 00:00 America/Bogotá**. Prefijos: `A-` general, `V-` vacunación, `C-` control, `U-` urgencia.
- **Cola única compartida por los dos consultorios.** El siguiente turno va al consultorio que se desocupe primero.

### 5.3 Emisión del turno — sin autenticación ni registro

**Canal A — QR + Telegram** (principal)

1. Afiche en la entrada con QR estático a `https://t.me/<bot>?start=turno-<sede_id>`.
2. El dueño escanea, abre Telegram, presiona *Iniciar*. El bot responde de inmediato con el código de turno, la posición en cola y el estimado de espera. **No pide nombre, documento ni nada.**
3. Al tener `telegram_chat_id`, el bot avisa **"faltan 2 turnos"** y **"es tu turno, pasa al Consultorio 2"**. Con 100 pacientes en un día pico y una sala de espera llena de animales, esto es la funcionalidad que más se va a notar.

Controles anti-abuso, sin autenticación:
- Máximo **1 turno activo por `telegram_chat_id`** por día. Si ya tiene uno, el bot le muestra el existente.
- Rate limit: 1 solicitud por chat cada 60 s.
- El QR **no** permite marcar urgencia. La prioridad solo la asigna el personal.

**Canal B — Recepción manual**

Para quien no tiene Telegram o no quiere usarlo. Desde el bot, rol `recepcion` o superior: botón "Crear turno manual", con opción de marcar urgencia y de asociar dueño/paciente ya conocido. Este es el fallback obligatorio: **nadie puede quedarse sin turno por no tener celular.**

### 5.4 Operación desde el bot

Al iniciar jornada, el veterinario elige consultorio → crea `sesion_consultorio`. Menú con botones:

- **Llamar siguiente** → toma el primero de la cola con `FOR UPDATE SKIP LOCKED`, lo pasa a `llamado`, le asigna su `consultorio_id`, notifica al chat del dueño si existe, actualiza la pantalla pública.
- **Ver cola** → turnos en espera con tiempo de espera acumulado.
- **Se presentó / Iniciar atención** → `en_atencion`.
- **No se presentó** → `ausente` + ofrece llamar siguiente.
- **Reencolar** → devuelve un ausente al final.
- **Finalizar** → `finalizado`. Si hay consulta abierta, propone cerrarla. Si hay cuenta abierta, la deja lista para cobro.
- **Marcar urgencia** → sube prioridad de un turno existente.
- **Cerrar consultorio** → cierra `sesion_consultorio`.

### 5.5 Pantalla pública

Vista web sin autenticación en `GET /pantalla/<sede_id>`, para un monitor o laptop en sala de espera:

- Turno actual por consultorio en grande (`A-042 → Consultorio 1`), tres siguientes en pequeño.
- Actualización por SSE, con fallback a polling cada 5 s.
- Sin datos personales: solo códigos de turno y consultorio.
- Debe verse bien en pantalla completa a 3 metros de distancia.

---

## 6. Módulo de Inventario

### 6.1 Modelo

```
medicamento
  id, nombre_generico, nombre_comercial, principio_activo
  presentacion, concentracion, unidad_base (ml|mg|tableta|unidad|dosis)
  categoria, requiere_receta (bool)
  precio_venta (numeric)
  stock_minimo, activo, notas

lote
  id, medicamento_id, numero_lote, fecha_vencimiento
  cantidad_inicial, cantidad_actual   -- CHECK (cantidad_actual >= 0)
  costo_unitario, entrada_id, fecha_ingreso, bloqueado (bool)

movimiento_inventario           -- append-only
  id, lote_id, tipo (entrada|salida|ajuste_positivo|ajuste_negativo
                     |baja_vencimiento|baja_dano|devolucion)
  cantidad, motivo
  consulta_id, paciente_id, cuenta_linea_id (nullable)
  usuario_id, canal (telegram|web), created_at
```

- `precio_venta` vive en `medicamento`; `costo_unitario` vive en `lote`. Son independientes: el mismo medicamento puede haber entrado a distinto costo en distintas compras y se vende siempre al mismo precio. El margen se calcula por movimiento contra el costo del lote específico que salió.
- El stock es **derivado** de `movimiento_inventario`. `lote.cantidad_actual` se mantiene por trigger como caché consultable, pero la fuente de verdad son los movimientos.
- **FEFO obligatorio**: al despachar se sugiere el lote de vencimiento más próximo. Se puede cambiar, pero exige justificación que queda en `motivo`.
- **Lotes vencidos se bloquean** automáticamente por job diario; solo admiten `baja_vencimiento`.

### 6.2 Alertas automáticas por Telegram

Job diario que notifica al `admin`:
- Medicamentos bajo `stock_minimo`.
- Lotes que vencen en ≤ 30 días y en ≤ 7 días.
- Lotes vencidos con existencia pendiente de baja.

### 6.3 Flujo de salida por chat — el más usado, debe ser el más rápido

```
[Salida de medicamento]
  → "¿Cuál medicamento?"   búsqueda por texto tolerante a errores de tipeo
                            (pg_trgm), top 5 como botones
  → lotes disponibles ordenados FEFO, con vencimiento y existencia
  → "¿Cantidad?"            botones con cantidades frecuentes + entrada libre
  → si el veterinario tiene consulta activa, la propone para vincular
  → agrega automáticamente la línea a la cuenta del paciente al precio_venta
  → tarjeta de confirmación con todo
  → [Confirmar] [Corregir] [Cancelar]
```

**Requisito de diseño:** la ruta feliz se completa en **≤ 4 toques**. El veterinario está con un animal en la mesa.

---

## 7. Módulo de Cobro

### 7.1 Modelo

```
tarifa
  id, tipo_servicio_id, nombre, valor_sugerido
  permite_valor_libre (bool), activa

cuenta
  id, turno_id, consulta_id, paciente_id, dueno_id
  estado (abierta|cerrada|anulada), subtotal, descuento, total
  fecha_apertura, fecha_cierre
  recibo_numero (nullable, consecutivo al cerrar)

cuenta_linea
  id, cuenta_id, tipo (servicio|medicamento)
  referencia_id, descripcion, cantidad, valor_unitario, valor_total
  usuario_id, created_at

descuento
  id, cuenta_id, valor, motivo (texto obligatorio)
  autorizado_por (usuario_id), created_at

pago
  id, cuenta_id, medio (efectivo|transferencia|datafono)
  valor, referencia, usuario_id, created_at

cierre_caja
  id, fecha, usuario_id, apertura_at, cierre_at
  base_inicial, total_efectivo_esperado, total_efectivo_contado
  total_transferencia, total_datafono, total_descuento
  diferencia, notas, estado (abierto|cerrado)
```

### 7.2 Flujo

1. La cuenta se abre automáticamente al pasar el turno a `en_atencion`.
2. El veterinario agrega la tarifa del servicio y, al dar salida a medicamentos, cada salida agrega su línea automáticamente al `precio_venta`.
3. El auxiliar en recepción abre la cuenta desde el bot, ve el detalle, registra el pago y cierra.
4. Al cerrar se asigna `recibo_numero` consecutivo y se envía el recibo al Telegram del dueño si está vinculado.

### 7.3 Descuentos

- Botón **"Aplicar descuento"** con motivo obligatorio de texto libre.
- Solo `admin`, o `auxiliar` con permiso explícito.
- Queda registrado en `descuento` y en auditoría, y sale en su propio reporte. **El descuento nunca se aplica borrando o editando líneas**: el subtotal se conserva y el descuento se registra aparte.

### 7.4 Advertencia legal — leer antes de pasar a producción

El MVP emite un **recibo interno consecutivo**, que **no es un documento tributario válido**. En Colombia la facturación electrónica DIAN es obligatoria para prácticamente todos los prestadores de servicios veterinarios. Antes de que este demo se convierta en operación real hay que integrarla (fase 2).

Diseñar el modelo de `cuenta` y `pago` de forma que agregar el documento electrónico después sea añadir una tabla `documento_electronico` referenciando `cuenta`, sin tocar lo existente.

---

## 8. Pacientes, dueños e historia clínica

### 8.1 Modelo

```
dueno
  id, nombre_completo (obligatorio), telefono
  tipo_documento, numero_documento          -- opcionales
  telegram_chat_id (nullable), direccion, barrio, notas
  consentimiento_datos (bool), consentimiento_fecha

paciente
  id, dueno_id (nullable), nombre, especie, raza, sexo, esterilizado
  fecha_nacimiento_aprox, color_senas, peso_ultimo_kg, foto_url
  alergias, estado (activo|fallecido), notas

consulta
  id, turno_id, cita_id (nullable), paciente_id, veterinario_id, consultorio_id, fecha
  motivo_consulta, anamnesis
  examen_fisico jsonb   -- peso, temperatura, FC, FR, mucosas, TLLC, hidratación, CC
  diagnostico_presuntivo, diagnostico_definitivo
  plan_tratamiento, recomendaciones
  remision_externa      -- qué examen se solicitó y a dónde
  proxima_revision (date, nullable)
  estado (borrador|firmada)
  created_at, firmada_at
```

- En `dueno`, **solo el nombre es obligatorio**. Exigir documento frena la atención.
- Deduplicación antes de crear: búsqueda por teléfono, y por nombre de mascota + nombre de dueño.

### 8.2 Captura de consulta por chat

1. **Botones para todo lo enumerable** (especie, sexo, mucosas, hidratación, condición corporal). Texto libre solo donde es inevitable.
2. **Campos narrativos opcionales y saltables.** Consulta mínima viable: motivo + diagnóstico + tratamiento.
3. **Guardado incremental como `borrador` en cada paso.**
4. **La consulta se firma explícitamente.** El borrador no es registro clínico válido hasta firmarse.
5. **El portal web ofrece el mismo formulario completo** como alternativa.

---

## 9. Proveedores y compras

```
proveedor
  id, nombre, tipo_documento, numero_documento
  telefono, email, contacto, direccion, notas, activo

entrada_inventario                -- cabecera
  id, proveedor_id (nullable), tipo (compra|ajuste_inicial)
  fecha, documento_soporte, valor_total, adjunto_url
  usuario_id, canal, observaciones, estado (borrador|confirmada)

entrada_linea
  id, entrada_id, medicamento_id, numero_lote, fecha_vencimiento
  cantidad, costo_unitario
```

- Una entrada se registra en `borrador` y solo genera lotes y movimientos al **confirmarse**.
- Permite adjuntar foto de la factura desde el chat.
- Sin órdenes de compra, sin recepciones parciales, sin cuentas por pagar. Eso es fase 2.

---

## 10. Reportes

En el portal con filtro de fechas y exportación CSV/PDF. Los cuatro primeros, además, resumibles por el bot bajo demanda.

1. **Stock actual** por medicamento, con alertas: bajo mínimo, por vencer (≤30 y ≤7 días), vencidos.
2. **Consumo de medicamentos** por período, en unidades y en valor, desglosable por veterinario y por paciente.
3. **Turnos**: atendidos, ausentes y cancelados por día; distribución por hora; tiempo promedio de espera y de atención; hora pico; ocupación por consultorio. Este reporte dice cuánto personal se necesita y a qué hora.
4. **Caja**: ingresos por día y por medio de pago, ticket promedio, cierres con diferencia, descuentos aplicados.
5. **Margen**: ingreso por venta de medicamentos contra el costo del lote efectivamente despachado, por período y por medicamento.
6. **Consultas**: número por veterinario, por tipo de servicio, diagnósticos más frecuentes.
7. **Pacientes**: nuevos vs. recurrentes, distribución por especie, remisiones externas emitidas y cuántas retornaron.
8. **Compras** por proveedor y período.
9. **Trazabilidad de lote**: qué pacientes recibieron un lote específico. Crítico si hay retiro de producto del mercado.

---

## 11. Portal web

### 11.1 Autenticación vía Telegram

1. El usuario abre `/login`. El backend genera `auth_challenge` (uuid) + código de 6 dígitos, TTL 5 minutos, y muestra el código junto a un botón *"Abrir Telegram"* (deep link `t.me/<bot>?start=web-<challenge>`).
2. En el bot, el usuario presiona **"Iniciar sesión web"** o llega por el deep link. El bot muestra el intento de acceso (navegador, IP, hora) y pide confirmar el código, o presionar `[Sí, soy yo]` / `[No fui yo]`.
3. Al aprobar, el backend emite sesión. La web, en polling o SSE, recibe el token y entra.
4. La sesión se ata al `usuario_id` correspondiente al `telegram_user_id`. Si ese Telegram no tiene usuario aprovisionado, **se deniega sin revelar si el código era válido**.

Controles:
- Código de un solo uso, 3 intentos máximo, invalidación inmediata al presionar `[No fui yo]`.
- Rate limit por IP y por `telegram_user_id`.
- Tabla `sesion` con `device_name`, `ip`, `user_agent`, `created_at`, `last_seen_at`, `expires_at`, `revocada`.
- Comando `/sesiones` en el bot y vista en la web para listar y **revocar**.
- Notificación por Telegram ante cada inicio de sesión nuevo.

### 11.2 Alcance funcional

Solo lo incómodo en un chat:

- Dashboard: cola en vivo por consultorio, stock crítico, caja del día.
- Catálogo de medicamentos y precios: alta y edición masiva.
- Proveedores y entradas de inventario con adjuntos.
- Historia clínica completa del paciente en línea de tiempo, con formulario completo de consulta.
- Todos los reportes con filtros y exportación.
- Gestión de usuarios, roles y permisos.
- Auditoría, libro de movimientos y bandeja de tareas fallidas.
- Configuración: consultorios, tipos de servicio, tarifas, `timeout_llamado_seg`, `max_reencolados`, umbrales de alerta.

---

## 12. Requisitos no funcionales

- Idioma: **español (Colombia)** en interfaz, mensajes del bot y errores.
- Zona horaria `America/Bogota`. Almacenar en UTC, presentar en local.
- **Ley 1581 de 2012 (habeas data)**: consentimiento explícito al vincular el Telegram del dueño, política de tratamiento accesible, y mecanismo de supresión. Los turnos por QR no capturan dato personal más allá del `chat_id`, y ese vínculo debe poder borrarse.
- Mensajes del bot legibles en celular de gama baja: textos cortos, botones grandes, máximo 3 botones por fila, sin tablas ASCII.
- Manejo de dinero con `numeric`, **nunca** `float`.
- Montos en pesos colombianos, con separador de miles y sin decimales.

---

## 13. Entregables

1. Migraciones SQL con el esquema completo: índices, constraints, triggers de stock, permisos a nivel de rol de base de datos, y seeds de roles, permisos, tipos de servicio, tarifas y consultorios.
2. Diagrama entidad-relación en Mermaid.
3. Workflows de n8n exportados como JSON, versionados en el repositorio.
4. Servicio worker de tareas asíncronas.
5. Portal web con autenticación por Telegram y las vistas de §11.2.
6. Pantalla pública de turnos.
7. Jobs programados: alertas de inventario, bloqueo de lotes vencidos, reinicio diario de numeración, backup.
8. `docker-compose.yml` que levanta todo con un comando, con `.env.example` documentado.
9. Datos de demo cargables con un comando: medicamentos, lotes, pacientes y un día de turnos simulado. **Indispensable para presentar.**
10. README de despliegue y guía de operación en español, dirigida al personal de la clínica, no a desarrolladores.

---

## 14. Orden de implementación

```
1. Esquema base + identidad + roles/permisos + auditoría + telegram_update + tarea_async
2. Turnos: QR, recepción manual, operación por bot con 2 consultorios, pantalla pública
3. Inventario: catálogo, lotes, movimientos, salida por chat, alertas
4. Pacientes, dueños y consulta por chat + formulario web
5. Cobro: cuenta, líneas, pagos, descuentos, recibo, cierre de caja
6. Proveedores y entradas por compra
7. Portal web: auth por Telegram, dashboard, reportes
8. Jobs, backup, datos de demo y documentación
```

**Detente y consulta conmigo al terminar los pasos 2, 3 y 5.** No avances al siguiente sin confirmación.
