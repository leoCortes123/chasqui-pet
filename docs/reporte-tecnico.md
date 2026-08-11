# REPORTE TÉCNICO — CHASQUI PET

Nota de lectura: el análisis se hizo leyendo el código fuente completo (migraciones SQL, worker, web, workflows n8n, scripts, documentación). No inventa datos; donde algo no existe se indica **NO ENCONTRADO**. Se usa el nivel de detalle pedido para planificar **Fase 1 (Facturación DIAN + Presupuestos)** y **Fase 2 (Reserva online + Carnet digital + Canal del cliente)**, con un modelo de IA de nivel medio (tipo GPT-3.5 / Claude 3 Haiku / Llama 3 8B) que necesita datos concretos y explícitos.

---
=== 1. RESUMEN EJECUTIVO ===

**Qué es**: ERP para clínica veterinaria en Bogotá, operado principalmente desde Telegram. Sistema nuevo e independiente (no comparte código ni BD con el "Chasqui" original). Estado declarado en README: **terminado (paso 8 de 8)**.

**Arquitectura central (decisiones rectoras):**
- **PostgreSQL es la fuente de verdad y el lugar donde vive la lógica de negocio** (funciones plpgsql, triggers, permisos, cola de tareas, estado conversacional, rate limiting, auditoría). n8n es solo un traductor de formato (5 nodos, "ninguna decisión de negocio").
- **n8n**: recibe el webhook de Telegram, llama UNA función SQL que resuelve el update y devuelve acciones, y las envía a la Bot API. No guarda estado.
- **Worker Node.js**: procesa `tarea_async` (cola de avisos, recibos, resúmenes, IA), polling cada 2 s, SKIP LOCKED.
- **Web (Next.js 16, App Router, TypeScript)**: portal administrativo + pantalla pública; login sin contraseñas (solo Telegram), datos en server components.
- **Proxy**: Caddy detrás del túnel cloudflared que absorbe la dirección dinámica.

**Entorno.** Colombia, zona `America/Bogota`; se almacena UTC y se presenta en hora de Bogotá. Puertos corridos para convivir con el Chasqui original (DB 5433, n8n 5679, web 3100, proxy 8081). Todo en docker-compose.

**Rol del bot vs portal.** Telegram es el canal primario (el día a día del personal); el portal web es administrativo (reportes + configuración). Los dueños de mascotas NO usan el portal: reciben por Telegram (`/start turno-<sede>`, avisos de turno, recibo, resumen de consulta).

**Estado de funcionalidades (resumen):**
- COMPLETO: turnos/cola única/QR/avisos, inventario (FEFO, stock derivado, lotes), clínico (dueños/pacientes/historia/firma/adenda), cobro (cuenta/descuentos/pagos/recibo/cierre de caja), compras/proveedores/entradas con soporte, portal web + reportes, permisos/roles, auditoría, jobs, respaldos.
- NO IMPLEMENTADO (declarado): **facturación electrónica DIAN** (emite recibo interno que "no es documento tributario válido" — aviso legal explícito en el README y en §7.4), **citas/disponibilidad** (tablas existen, sin lógica ni UI), **presupuestos/cotizaciones** (NO ENCONTRADO), **carnet digital** (NO ENCONTRADO), **canal del cliente online** (NO ENCONTRADO más allá del QR).

**Para Fase 1/2 hay que construir mucho antes.** El sistema está diseñado para que `cuenta`/`pago` se extiendan con una tabla `documento_electronico` sin tocar lo existente (§7.4 / Fase original), pero no existen: flujos en borrador, horarios, cotizaciones, presupuestos ni método de reserva con pago. Son adiciones nuevas.

**Riesgos principales detectados:**
1. **Activar la facturación DIAN** antes de la operación real es obligatorio (legal).
2. **El modelo de datos no tiene migraciones incrementales**: solo initial en el primer arranque (`/docker-entrypoint-initdb.d`). Cambiar el esquema en producción requiere script manual/restauración.
3. La dirección pública del túnel **cambia en cada arranque** (dominio efímero) → el webhook y el portal cambian de URL; el registrador lo absorbe, pero para producción conviene `WEBHOOK_URL_FIJA`.
4. **Presupuestos/cotizaciones exigen diseñar "estados de aprobación"** y posible integración con la cola de tareas y con `cuenta` — no existen hoy.
5. IA: DeepSeek con `deepseek-v3-pro`; **`deepseek-v3-flash`** existe como opción barata (más cerca del perfil "nivel medio" que pides para las fases).

---
=== 2. ESTRUCTURA DE BASE DE DATOS ===

BD de negocio: `chasquipet` (Postgres 16, UTF8). Extensiones: `pgcrypto`, `pg_trgm`, `unaccent`. Base separada `n8n` aislada (el rol `n8n` no toca la BD de negocio). Roles de app: `chasquipet_app` (lectura/escritura salvo append-only) y `chasquipet_lectura` (solo lectura, opcional). No existige `BI` ni replicación.

### 2.1 Tablas (38) — los módulos

Componentes por migración. Resumen de cada tabla con columnas clave.

#### 010_base — núcleo común
| Tabla | Columnas (PK/restricciones resaltadas) |
|---|---|
| `config` | `clave` PK, `valor` NO NULL, `tipo` CHECK('texto','entero','decimal','booleano','json'), `descripcion`, `editable_ui`, `updated_at` |
| `sede` | `id` uuid PK, `nombre`, `direccion`, `telefono`, `ciudad` (default Bogotá), `activa` |
| `consultorio` | `id` PK, `sede_id` FK, `nombre`, `orden`, `activo`, UNIQUE(sede_id, nombre) |
| `evento_auditoria` | `id` bigserial PK, `entidad`, `entidad_id`, `accion`, `usuario_id` (FK lógica, sin REFERENCES), `canal` CHECK(telegram,web,sistema,y job), `datos_antes`, `datos_despues`, `detalle`, `ip`, `created_at`. Append-only (090 grants) |
| `telegram_update` | `update_id` PK, `telegram_user_id`, `chat_id`, `tipo`, `payload` jsonb, `procesado` bool, `error`, `recibido_at`, `procesado_at` |
| `tarea_async` | `id` bigserial PK, `tipo`, `payload` jsonb, `estado` CHECK(pendiente,procesando,completada,fallida), `prioridad`, `intentos`, `max_intentos`, `proxima_ejecucion`, `ultimo_error`, `clave_unicidad` (UNIQUE parcial pendiente/procesando), `resultado`, timestamps. Cola de tareas |
| `rate_limit` | `clave` PK, `ventana_at`, `conteo` — ventana móvil sencilla |

Funciones base: `hoy_bogota()`, `ahora_bogota()`, `normalizar()`, `touch_updated_at()`, `config_int/txt/bool`, `auditar()`, `registrar_update_telegram` (dedup), `marcar_update_procesado`, `encolar_tarea` (idempotente por clave), `reclamar_tareas` (FOR UPDATE SKIP LOCKED), `completar_tarea`, `fallar_tarea` (backoff exponencial 30s→1h, dead-letter a superadmin), `rescatar_tareas_colgadas`, `consumir_rate_limit`.

#### 020_identidad — identidad, RBAC, sesiones, estado conversacional
| Tabla | Columnas |
|---|---|
| `usuario` | `id` PK, `telegram_user_id` bigint UNIQUE, `telegram_chat_id` bigint, `nombre_completo` NOT NULL, `telefono`, `email`, `sede_id` FK, `activo`, `creado_por` FK, `notas`, `ultimo_acceso_at`, timestamps. **No hay autorregistro: se crean por la recepción/admin a mano.** |
| `rol` | `codigo` PK, `nombre`, `descripcion`, `nivel`, `sistema` |
| `permiso` | `codigo` PK (`turnos.ver`…), `modulo`, `descripcion` |
| `rol_permiso` | PK(rol_codigo, permiso_codigo) |
| `usuario_rol` | PK(usuario_id, rol_codigo) |
| `usuario_permiso` | PK(usuario_id, permiso), `otorgado` bool (false=revocación), `motivo`, `asignado_por` |
| `v_usuario_permiso` (vista) | unión de roles − revocaciones + otorgamientos |
| `conversacion_estado` | `chat_id` bigint PK, `usuario_id` FK SET NULL, `flujo`, `paso`, `datos` jsonb, `mensaje_id`, `expira_at` (default +2h), timestamps |
| `auth_challenge` | `id` PK, `codigo` char(6), `estado` CHECK('pendiente','aprobado','rechazado','expirado','consumido'), `intentos`, `usuario_id` FK, `ip` inet, `user_agent`, `device_name`, `sesion_id`, `created_at`, `expira_at` (+5 min), `resuelto_at` |
| `sesion` | `id` PK, `usuario_id` FK CASCADE, **`token_hash` text UNIQUE (solo sha256)**, `device_name`, `ip`, `user_agent`, `created_at`, `last_seen_at`, `expires_at` (+30 días), `revocada`, `revocada_por` |

Funciones clave: `tiene_permiso`, `exigir_permiso`, `usuario_por_telegram`, `perfil_telegram` (jsonb con roles+permisos), `vincular_chat_usuario`, `estado_guardar/leer/limpiar`, `crear_usuario`, `desactivar_usuario`.

#### 030_turnos + 035_aviso — cola única y avisos
- `tipo_servicio` (id, `codigo` UNIQUE, `nombre`, `prefijo` char1 A/V/C/U, `prioridad_base`, `duracion_estimada_min`, `visible_qr`, `orden`, `activo`)
- `sesion_consultorio` (id, consultorio_id FK, usuario_id FK, `abierta_at`, `cerrada_at`; dos UNIQUE parcial: un consultorio abierto y un veterinario a la vez)
- `turno` (id, `codigo` 'A-042', `sede_id` FK, `fecha`, `numero_secuencial`, `tipo_servicio_id` FK, `estado` CHECK(en_espera,llamado,en_atencion,finalizado,ausente,cancelado), `prioridad` base 0, `canal_origen` CHECK(qr_telegram,recepcion_manual,tablet_kiosco), `telegram_chat_id`, `dueno_id/paciente_id/consulta_id/cuenta_id` FK, `consultorio_id` FK, `veterinario_id/creado_por` FK, `veces_llamado`, `veces_reencolado`, `notas`, timestamps de estados. **UNIQUE parcial `(telegram_chat_id, fecha) WHERE estado IN('en_espera','llamado','en_atencion')` = máx 1 turno activo por chat/día**
- `aviso_turno_enviado` (PK compuesta `(turno_id, tipo)`, `enviado_at`). Dedupe atómica entre workers con INSERT ON CONFLICT DO NOTHING

Funciones de turno: `siguiente_numero_turno` (advisory `pg_advisory_xact_lock('turno:..')`), `posicion_en_cola`, `espera_estimada_min`, `turno_json`, `crear_turno_qr`, `crear_turno_manual`, `llamar_siguiente` (**SELECT..FOR UPDATE SKIP LOCKED**, encola 2 tareas), `iniciar_atencion` (con `abrir_cuenta`), `marcar_ausente`, `reencolar_turno` (límite `max_reencolados`), `finalizar_turno`, `cancelar_turno`, `marcar_urgencia`, `turnos_llamado_vencido`, `abrir/cerrar_consultorio`, `pantalla_publica` (+`notificar_pantalla` con `pg_notify`), `turnos_por_avisar`. Vista `v_cola_actual`.

#### 045_inventario — medicamento, lote, movimientos
- `medicamento` (id, nombre_generico NO NULL, nombre_comercial, principio_activo, presentacion, concentracion, unidad_base CHECK(ml,mg,tableta,unidad,dosis), categoria, requiere_receta, precio_venta, stock_minimo, activo, notas, **`busqueda` GENERATED STORED** (normalizar). Índice GIN trigramas, UNIQUE parcial activo, único `(normalizar(generico), coalesce(nombre_comercial,''))`)
- `lote` (id, medicamento_id FK, numero_lote, fecha_vencimiento NOT NULL, cantidad_inicial, **`cantidad_actual` (caché)** CHECK>=0, costo_unitario, entrada_id FK (consultado en 070), fecha_ingreso, bloqueado, motivo_bloqueo; UNIQUE(medicamento_id, numero_lote, fecha_venc). Índice FEFO `(medicamento_id, fecha_vencimiento) WHERE NOT bloqueado AND cantidad_actual>0`)
- `movimiento_inventario` (id bigserial PK, lote_id FK, medicamento_id FK(denorm), tipo CHECK(entrada,salida,ajuste_positivo,ajuste_negativo,baja_vencimiento,baja_dano,devolucion), cantidad>0) (siempre positiva, el signo lo da el tipo), motivo, turno_id/consulta_id/paciente_id/cuenta_linea_id FK, usuario_id, canal, created_at. **Append-only: 090 grants REVOHN UPDATE/DELETE al rol de la app + trigger de bloqueo.** 3 triggers: validar/aplicar/inmutable
- Vistas: `v_lote_disponible` (FEFO), `v_stock_medicamento` (disponible vs total, por_vencer, bajo_mínimo, próximo_vencimiento)

Funciones: `signo_movimiento`, `fmt_cant`, `movimiento_validar` (FOR UPDATE), `movimiento_inmutable`, `buscar_medicamento` (trigram + prefijo con puntaje), `lotes_fefo`, `lote_fefo`, `medicamentos_frecuentes`, `medicamento_json`, `movimiento_json`, `crear_medicamento`, `cambiar_precio_medicamento`, `registrar_movimiento` (núcleo sin permiso), `salida_medif**ant**` (**FEFO obligatorio, si no `fefo_sin_justificacion`; encola `agregar_linea_cuenta`**), `ajustar_lote`, `ingresar_lote` (genera lote de / diente `S/L-YYYYMMDD-NNN`, re-itemiza), `bloquear_lote_venciidos` (job), `alertas_inventario`, `hay_alertas_inventario`.

#### 050_pacientes — dueño, paciente, historia clínica
- `dueno` (id, `nombre_completo` NOT NULL, telefono, tipo_documento CHECK(cc,ce,ti,nit,pasaporte), numero_documento, telegram_chat_id bigint, direccion, barrio, notas, **`consentimiento_datos` bool NOT NULL + `consentimiento_fecha` (Ley 1581)**, activo, creado_por. UNIQUE parcial (tipo_documento, nº) WHERE NO NULL; `telefono_digitos`/`busqueda` generados)
- `paciente` (dueno_id nullable (callejeros ok), nombre NO NULL, especie CHECK(perro,gato,ave,conejo,roedor,reptil,equino,otro), race, sexo CHECK(macho,hembra,desconocido), esterilizado, fecha_nacimiento_aprox, color_señas, peso_ultimo_kg CHECK>0, peso_ultimo_at, foto_url, alergias, estado CHECK(activo,supo_oculto),... busqueda generada)
- `consulta` (turno_id nullable UNIQUE parcial + cita_id UNIQUE parcial — una consulta nace de 1 o el otro; paciente_id NOT NULL, dueno_id, veterinario_id, consultorio_id, sede_id, fecha, motivo_consulta, anamenesis, `examen_fisico` jsonb (peso, T°, FC, FR, mucosas, TLLC, hidratación, CC), diagnostico_presuntivo/definitivo, plan_tratamiento, recomendaciones, remision_externa, proxima_revision, estado CHECK(borrador,firmada,anulada), canal_origen, motivo_anulacion, firmada_at/por, anulada_at/por. Índice de borrador por veterinario)
- `consulta_adenda` (consultada_id, texto NOT NULL, usuario_id, canal, created_at)
- `disponibilidad` y `cita` (**FUERA DEL MVP**: solo esquema para la FASE 2 reserva online; `cita` apunta a `turno` para convergencia)

Funciones: `edad_texto`, `nombre/emoji_especie`, `opciones_examen` (un solo catálogo), `nombre`/`etiqueta_opcion`, `buscar_dueno/buscar_paciente`, `posibles_duplicados` (dedup antes de crear), `crear/actualizar_dueno`, `registrar_consentimiento` (retira→desvincula el chat, Ley 1581), `suprimir_datos_dueno` (anonimiza, NO borra la historia), `crear/actualizar_paciente`, `vincular_turno_paciente` (solo vincula si consentió), `abrir_consulta` (retoma el borrador del mismo turno+paciente; 2ª mascota sin turno), `guardar_consulta` (borrador campo a campo), `guardar_examen`, `guardar_consulta_completa`, `firmar_consulta` (exige motivo+dx+tx, idempotente, propaga el peso a `paciente.peso_ultimo_kg`, encola `enviar_resumen_consulta`), `agregar_adenda`, `anular_consulta`, `consulta_en_curso`, `historia_paciente` (solo firmadas). Trigger `consulta_inmutable` (firmada solo→anulada sin cambio de contenido).

#### 060/066 cobro + caja
- `tarifa` (id, tipo_servicio_id nullable, `codigo` UNIQUE, nombre, valor_sugerido, permite_valor_libre, activa, orden)
- `cierre_caja` (id, sede_id, fecha, usuario_id, cerrada_por, apertura/cierre_adj, base_inicial, efectivo_esperado/contado, transferencia, datafono, descuento, cuentas_cerradas, diferencia, notas, estado CHECK(abierto,cerrado). **UNIQUE parcial `(sede_id) WHERE estado='abierto'`** = una sola caja abierta por sede)
- `cuenta` (id, sede_id, fecha, turno_id UNIQUE parcial, consulta_id, paciente_id, dueno_id, estado CHECK(abierta,cerrada,anulada), **caché `subtotal/descuento/total/pagado`**, `recibo_numero` int UNIQUE (consecutivo interno, solo si cerrar), cierre_caja_id, abierta_por/cerrada_por, motivo_anulacion, canal_origen, timestamps)
- `cuenta_linea` (id, cuenta_id, tipo CHECK(servicio,medicamento), referencia_id (tarifa/med), **`movimiento_id` UNIQUE FK→movimiento_inventario**, descripcion, cantidad>0, valor_unitario>=0, **`valor_total` GENERATED**, usuario_id, canal)
- `descuento` (cuenta_id, tipo CHECK(descuento,reverso), valor>0, motivo NOT NULL, autorizado_por, revierte_id FK, canal)
- `pago` (cuenta_id, cierre_de_caja_id FK, tipo CHECK(pago/reverso), medio CHECK(efectivo,transferencia,datafono), valor>0, referencia, motivo, revierte_id FK, usuario_id, canal). **Pagos y descuentos append-only** (090 grants + trigger; un error se corrige con un reverso)

Funciones: `signo_dinero`, `pesos` (formato fijo), `parse_pesos`, `siguiente_numero_recibo` (advisory lock), `cuenta_recalcular` (caché, no va bajo cero), `cuenta_json`, `recibo_texto`, `abrir_cuenta_para_turno` (idempotente, worker), `cuenta_de_turno`, `agregar_linea_servicio`, `agregar_linea_medicamento (movimiento_id)`, `quitar_linea`, `aplicar/revtir_descuento`, `abrir_caja/cerrar_caja` (cierre exige `efectivo_contado` y rechaza si quedan cuentas abiertas; déficit → notifica superadmin), `caja_json`, `registrar_pago` (valor NULL = lo que falte; efectivo acepta de más y devuelve vuelto), `cerrar_cuenta` (exige pagado≥total; asigna recibo_numero; encola `enviar_recibo`), `anular_cuenta` (revierte los pagos, cuadra caja), `resumen_caja_dia`.

#### 070/076 — compras (proveedores y entradas)
- `proveedor` (id, nombre UNIQUE(normalizado), tipo_documento, numero_documento, telefono, email, contacto, direccion, notas, actividad, busqueda generada)
- `entrada_inventario` (id, sede_id FK, proveedor_id FK nullable, tipo CHECK(compra,ajuste inicial), fecha, documento_soporte, `valor_total` caché, adjunto_file_id (foto Telegram), adjunto_url (portal), usuario_id, canal, observaciones, estado CHECK(borrador,confirmada,descartada), confirmada_at/por, timestamps)
- `entrada_linea` (id, entrada_id FK CASCADE, medicamento_id FK, numero_lote, fecha_vencimiento, cantidad>0, costo_unitario>=0, `valor_total` GENERATED, lote_id FK). Trigger: solo escritura en borrador, recalcula valor_total

funciones: `crear/editar_proveedor`, `buscar_proveedor/proveedores_frecuentes`, `crear_entrada`, `agregar/quitar_linea_entrada`, `adjuntar_soporte`, `anotar_entrada`, **`confirmar_entrada` (todo o nada: marca confirmada ANTES y llama `ingresar_lote` por línea; revierte toda la entrada si una falla)**, `descartar_entrada`, `trazabilidad_lote`, `reporte_compras`.

#### 077 portal_enlace: `crear_enlace_portal` (nuevo challenge ya aprobado → `/entrar/enlace/<uuid>`, TTL 5 min, rate 5/h, anula enlaces anteriores, audita). Menú bot con `por:*`.

#### 078 chasqui_ia (IA): tablas `ia_mensaje`, `ia_accion_pendiente`, `ia_herramienta` (catálogo de herramientas). Ver §5.5.

### 2.2 Convenciones transversales
- **Append-only**: `evento_auditoria`, `movimiento_inventario`, `pago`, `descuento` — nadie hace UPDATE/DELETE (revoke al rol + trigger). Corrección = movimiento inverso / reverso.
- **Tiempo**: `hoy_bogota()`, `ahora_bogota()`; timestamptz en UTC.
- **Idempotencia**: `encolar_tarea` con `clave_unicidad`, dedupe de updates por PK, `INSERT ON CONFLICT`.
- **Auditoría** en casi cada escritura (`auditar(...)`).
- **Permisos como datos** (rol/permiso/vistas) + `exigir_permiso` dentro de cada función de escritura.
- Seed de roles (100) y de config/tarías/superadmin (110) automáticos.

---
=== 3. API/BACKEND ===

**Concepto**: no hay una API REST clásica. El "backend" es realmente (a) funciones SQL en PostgreSQL, (b) un pipeline n8n que las traduce a Bot API, y (c) route handlers de Next.js para el portal. Los tres comparten el contrato: **"respuestas jsonb"**.

### 3.1 Contrato general del bot (jsonb de acciones)
```json
{"acciones":[{"tipo":"enviar","chat_id":123,"texto":"...","botones":[[{"t":"Ver cuenta","d":"cob:cta:uuid"}]]}]}
```
Tipos: `enviar` (sendMessage), `editar` (editMessageText), `responder_callback` (answerCallbackQuery). n8n lo traduce. Un `update` entra por `registrar_update_telegram` → `bot_manejar_update` → devuelve el jsonb.

### 3.2 Contratos jsonb típicos
- Error de negocio: `{"ok":false,"motivo":"...","mensaje":"..."}` (algunas funciones también devuelven `alerta`, `ya_existia`, `pendiente`, `vuelto`, ...).
- Fichas: `turno_json`, `cuenta_json`, `consulta_json`, `paciente_json`, `dueno_json`, `caja_json`, `entrada_json`, `medicamento_json`, `movimiento_json`.
- `perfil_telegram`: `{usuario_id, nombre, sede_id, es_personal, roles[], permisos[]}`.

### 3.3 Endpoints de red (Next.js route handlers)
| Ruta | Método | Params/query | Qué hace | Función PG |
|---|---|---|---|---|
| `/api/entrar` | POST | IP+UA resueltos por server/headers | crea un challenge/login y devuelve `{ok, challenge_id, codigo, expira_at, enlace}` deep-link `web-<id>` | `crear_challenge_web` |
| `/api/entrar/[id]` | POST | `:id` uuid | sondeo (2 s): canjea el token de 1 uso, escribe HttpOnly cookie `sesion` | `emitir_sesion_web` |
| `/entrar/enlace/[id]` | GET | id uuid | canje directo (el challenge ya viene aprobado desde el bot) → 303 con cookie | `emitir_sesion_web` |
| `/salir` | POST | — | revoca la sesión (marca `revocada` en BD) y borra cookie → 303 | `cerrar_sesion_web` |
| `/health` | GET | — | 200/503 | `SELECT 1` |
| `/api/pantalla/[sede]` | GET | sede uuid | estado de pantalla (JSON) | `pantalla_publica` |
| `/api/pantalla/[sede]/stream` | GET | sede | SSE: `event:estado`, `NOTIFY pantalla_turnos`, heartbeat, retry | `pantalla_publica` + LISTEN |
| `/api/reportes/[clave]` | GET | `?desde&hasta` | CSV (separación `;` y BOM), 401/403/404 | SQL declarativa del reporte |

### 3.4 Worker (Node.js – cola asíncrona)
- `worker/src/index.js`: Pool pg (`DATABASE_URL`), poll cada `WORKER_INTERVALO_MS` (2000 ms) llamando `reclamar_tareas(WORKER_LOTE)`, procesa en paralelo con `Promise.allSettled`, cada tarea termina con `completar_tarea`/`fallar_tarea`. Rescue propio cada 5 min + cron de seguridad. Apagado limpio con SIGTERM.
- 11 tipos de tarea registrados en `worker/src/tareas/index.js`:
  - `notificar_turno_llamado` (`turno_json` → "Es tu turno…" → marca aviso `llamado`)
  - `notificar_turnos_proximos` (`turnos_por_avisar` → "Faltan N…" → reserva aviso `proximo` ANTES de enviar, ON CONFLICT)
  - `recordar_llamado_vencido` (`turnos_llamado_vencido` → aviso al veterinario con botones)
  - `notificar_superadmin` (deadletter y alarmas)
  - `abrir_cuenta_turno` (idempotente, `abrir_cuenta_para_turno`, encadenado en `iniciar_atencion`)
  - `agregar_linea_cuenta` (desde `salida_medicamento`; idempotente por `movimiento_id`; completa sin retry en `sin_turno`/`cuenta_cerrada`/`no_es_salida`)
  - `alertas_inventario` (diaria, `hay_alertas` + `bot_texto_alertas_inventario`; destinatarios = permiso `inventario.ajuste`)
  - `enviar_resumen_consulta` (al dueño, solo si ha consentido)
  - `enviar_recibo` (al dueño, solo si ha consentido)
  - `notificar_inicio_sesion` (avisa al dueño "Entraste al portal" con IP y dispositivo)
  - `chasqui_responder` (llama a DeepSeek vía `openai` SDK; bucle ≤8 vueltas con herramientas; ver §5.5)
- `src/telegram.js`: cliente mínimo con `fetch`, métodos `sendMessage`/`editMessageText`, `parse_mode: HTML`, timeout 15 s, retry 1→429 (respeta `retry_after`), 403→bloqueado, 400→chat_invalido, `esc()` HTML, `teclado()` inline.

### 3.5 Dependencias de paquetes
- worker: `pg ^8.13.1`, `openai ^7.4.0`. Node 22 ESM.
- web: `next 16.2.12`, `react/react-dom 19.2.8`, `pg 8.16.3`. TypeScript strict.

---
=== 4. FLUJOS DE N8N ===

n8n v2.31.5, única credencial Postgres `Chasqui Pet Postgres` (host `db:5432`, user `chasquipet_app`). Los 4 flows viven en `n8n/workflows/*.json`. **n8n NO guarda estado**; todo está en Postgres.

### 4.1 `01-telegram-webhook.json` (id `chasquipetTelegram`) — todos los mensajes al bot
| # | Nodo | Tipo | Configuración |
|---|---|---|---|
| 1 | Webhook Telegram | **webhook** | `POST /chasquipet-telegram`, `responseMode: onReceived` (responder 200 al instante, <1 h), `responseData: noData` |
| 2 | _Registrar y resolver_ | **postgres** `executeQuery` | `SELECT CASE WHEN registrar_update_telegram($1::jsonb) THEN bot_manejar_update($1::jsonb) ELSE jsonb_build_object('acciones','[]'::jsonb,'duplicado',true) END AS respuesta;` con `$1 = JSON.stringify($json.body)` |
| 3 | _Acciones → Bot API_ | **code** | traduce `acciones` → `{metodo, cuerpo}` (`responder_callback`→answerCallbackQuery, `enviar`→sendMessage, `editar`→editMessageText), botones→inline_keyboard |
| 4 | _Enviar a Telegram_ | **HTTP** | `POST https://api.telegram.org/bot{{ $env.TELEGRAM_BOT_TOKEN }}/{{metodo}}`, body JSON, timeout 10 s, `neverError` + `onError: continueRegularOutput` (absorbe el 400 "message is not modified" de dobles clicks) |
| 5 | _Marcar procesado_ | **Postgres** | `SELECT marcar_update_procesado($1::bigint);` |

### 4.2 `02-job-turnos.json` (id `chasquipetTurnos`) — cada minuto
- **Schedule** (1 min) → dos ramas paralelas:
  1. Postgres: `SELECT encolar_tarea('recordar_llamado_vencido', jsonb_build_object('sede_id',s.id),5, 'llamado_vencido_'||s.id||'_'||to_char(now(),'YYYYMMDDHH24MI')) FROM sede s WHERE s.activa AND EXISTS (SELECT 1 FROM turnos_llamado_vencido(s.id));` (clave de unicidad evita apilar)
  2. Postgres: `SELECT rescatar_tareas_colgadas(15);` (red de la cola)
- Sin credencial de Telegram.

### 4.3 `03-job-inventario.json` — 7:30 diario
- Cron `0 30 7 * * *` → `SELECT bloquear_lotes_vencidos();` → `SELECT encolar_tarea('alertas_inventario','{}'::jsonb,3,'alertas_inv_'||hoy_bogota()::text);`

### 4.4 `04-job-mantenimiento.json` — 3:15 diario (`active: true`)
- Cron `0 15 3 * * *` → `SELECT mantenimiento_diario();` → `ANALYZE movimiento_inventario, turno, cuenta, evento_auditoria; SELECT 1;`

Nota: los 4 contienen `saveDataErrorExecution/success: "all"`, zona horaria del workflow `America/Bogota`.

---
=== 5. BOT DE TELEGRAM ===

Bot `@chasqui_alunabot`. La lógica vive **todo en PostgreSQL**; n8n traduce el JSONB a llamadas a la Bot API.

### 5.1 Librería y transporte
- No usa librería JS de bot: HTTP `fetch` directo a la Bot API. `esc()` para escape HTML, `parse_mode=HTML`.
- Webhook registrado con `setWebhook` (via túnel) + `setMyCommands` (11 comandos) + `setMyDescription` limpio (el bot no se autopresenta a desconocidos).

### 5.2 Comandos / mensajes
| Comando | Para quién | Efecto |
|---|---|---|
| `/start` (sin argumentos) | público | si tiene turno activo hoy le muestra su tarjeta; si no → "escanea el QR de la entrada" |
| `/start turno-<sede-uuid>` | público | `crear_turno_qr(chat, sede)` → mensaje del dueño (QR de la entrada) |
| `/start web-<uuid>` | personal | `bot_auth_texto` → tarjeta de ingreso al portal |
| `/menu` (o `menu`) | personal | menú según permisos |
| `/cola` | personal | texto de cola (`v_cola_actual`) |
| `/ayuda` | personal | `bot_texto_ayuda` |
| `/stock` | personal | existencias + alertas de inventario |
| `/entrada` | personal con `inventario.entrada` | flujo para registrar mercancía |
| `/proveedores` | personal | lista de proveedores |
| `/cobrar` | personal con `cobro.ver` | cuentas abiertas |
| `/caja` | personal | estado de la caja del día |
| `/sesiones` | personal | sesiones abiertas + revocar |
| `/portal` | personal | enlace de 1 uso al portal (5 min) |
| `/chasqui` | personal (si IA activa) | "Habla con Chasqui" (IA) |
| `/cancelar` | personal | vuelve al menú y resetea el estado |

### 5.3 Arquitectura de estado (FSM)
Todo flujo multipaso vive en `conversacion_estado` (`chat_id → flujo+paso+datos`, TTL 2h). n8n no guarda nada; si se reinicia, el usuario continúa.

Prefijos de callback (cadenas `modulo:accion:...`): **`turno:`, `inv:`, `cli:`, `cob:`, `com:`, `auth:` (alias `aut`), `por:`, `ia:`, `menu`**. El router `bot_manejar_update` delega a `bot_modulo_callback`/`bot_modulo_texto`/`bot_modulo_media` (concatenación COALESCE de los módulos; la IA es el último).

FSM por módulo:
- **Inventario (`salida`)**: `medicamento → cantidad → confirmar` (+2 desvíos: `cantidad_libre`, `motivo`, `lotes`). Búsqueda de toque.
- **Inventario (`stock`)**: `buscar`.
- **Clínico (`consulta)**: `paciente → motivo → anamenesis → examen → diagnostico → tratamiento → recomendaciones → [remision/proxima] → resumen`. Guardado en tablas `consulta` (no en estado).
- **Paciente nuevo**: `dueno_nombre → dueno_telefono → mascota_nombre → especie → sexo → confirmar` (con dedupe previo).
- **Cobro (`cobro)**: `elegir → cuenta → [valor_libre | descuento_valor → descuento_motivo | medio] → cerrar`.
- **Caja**: `caja_base → caja_contado`.
- **Compras (`entrada)**: `proveedor → [buscar_med → cantidad → costo → vencimiento → lote]* → (documento/foto) → confirmar`.
- **IA (`ia`)**: `conversando` (chat libre).

### 5.4 Autenticación web (flujo inverso a la web)
1. La web pide challenge: `crear_challenge` (rate 10/h por IP) → código de 6 dígitos + enlace `/start web-<id>`.
2. El usuario toca la tarjeta en el bot (`aut:si` / `aut:no`).
3. La web sonde el `[id]` (o el bot devuelve el enlace directo): `emitir_sesion_web` genera un token único y guarda `sha256` en `sesion`. Cookie HttpOnly 30 días. El servidor nunca vuelve a ver el token una vez emitido.
- `/portal` genera en la BD un `auth_challenge` ya aprobado (rate 5/h), anulando los anteriores; enlazado a `/entrar/enlace/<uuid>`.

### 5.5 IA — "Habla con Chasqui" (worker + `iota/chasqui_ia.sql`)
- **Modelo**: DeepSeek (base_url configurable, key por env). Config: `ia_modelo` (`deepseek-v-pro`/`deepseek-v3-flash`), `ia_temperatura 0.3`, `ia_turnos_memoria 20`, `ia_limite_hora 60/h`.
- **El modelo NO accede a la BD**: catálogo cerrado de herramientas (`ia_herramienta` filtrada por permiso del usuario).
- **Lectura (14 tools, sin confirmación)**: `ver_cola`, `resumen_dia`, `informacion_clinica`, `buscar_medicamento`, `alertas_inventario`, `ver_caja`, `cuentas_por_cobrar`, `ver_tarifas`, `buscar_pacientes`, `historia_paciente`, `buscar_dueno`, `buscar_proveedor`, `enlace_portal`. Devuelven IDs (turno_id, lote_id, cuenta_id) para que el modelo no invente UUIDs.
- **Escritura (7 tools)**: `llamar_siguiente`, `crear_turno`, `cambiar_estado_turno` (`presento/ausente/finalizar/reencolar`), `registrar_salida_medicamento`, `agregar_servicio_a_cuenta`, `cobrar_cuenta`. Las críticas (`critica=true`) siempre muestran tarjeta de confirmación con datos frescos.
- **Flujo**: worker → `ia_llamar` (hasta 8); si `requiere_confirmacion` → tarjeta `ia:ok:<uuid>` / `ia:no:<uuid>`; `ia_confirmar` (FOR UPDATE, 10 min de vida, auditado) ejecuta la escritura real y el resultado vuelve al historial. Rate `ia:<user>`.

### 5.6 Reglas de oro del bot
- Webhook `responseMode onReceived` → `Telegram` nunca reintenta- Ret Time, todo pesado a la cola.
- Dedupe por `telegram_update.update_id`.
- Avisos al dueño SOLO si `consentimiento_datos` (Ley 1581/12).
- Máx 1 turno activo por chat/día.

---
=== 6. PORTAL WEB ADMINISTRATIVO ===

Next.js 16 (App Router, TypeScript strict, Node 22). `next.config.ts`: `output:'standalone'`, `reactStrictMode`, `serverExternalPackages:['pg']`. Sin librerías UI → CSS Modules + tema oscuro. Todas las páginas `runtime='nodejs'` y `force-dynamic`.

### 6.1 Rutas (grupo `(portal)`, protege el layout; menú según permisos reales)
| Rota | Contenido | Fuente de datos |
|---|---|---|
| `/` | Panel (que en vivo, caja del día, inventario crítico, pendientes) | `dashboard(sede)` |
| `/consultas` | bandeja de borradores propios + firmadas el día de hoy | SQL directa `consultasRecientes` |
| `/pacientes` | buscador GET `?q=` | `buscar_paciente` |
| `/pacientes/[id]` | ficha + historia en línea de tiempo | `paciente_json`, `historia_paciente` + serveraction `abrirConsulta` |
| `/consulta/[id]` | formulario (borrador) / lectura firmada + adenda | `consulta_json` |
| `/inventario` | catálogo de precios `gestion` | `catalogo_medicamentos` |
| `/inventario/movimientos` | libro de movimientos (solo lectura) | `libro_movimientos` |
| `/compras` | entradas + proveedores | `entradas_recientes`, `proveedores_frecuentes` |
| `/reportes` | índice de reportes filtrados por permisos | tabla `lib/reportes.ts` |
| `/reportes/[clave]` | exportación CSV + fechas | `ejecutarReporte` |
| `/reportes/trazabilidad` | trazabilidad por lote | `buscarLote`, `reporte_trazabilidad` |
| `/admin` | salud del sistema | `salud_sistema` |
| `/admin/usuarios` | altas, roles, permisos individuales | `usuarios_listado`, `roles_disponibles`, `permisos_disponibles` |
| `/admin/config` | parámetros, tarifas, consultorios | `config_listado`, `tarifas_listado` |
| `/admin/auditoria` | auditoría de solo lectura | `auditoria_listado` |
| `/admin/tareas` | bandeja tareas fallidas (retry/descartar) | `tareas_listado`, `resumen_tareas` |
| `/entrar` + `ingreso.tsx` | login por código de 6 (sondeo a `/api/entrar/[id]`) |
| `/entrar/enlace/[id]` | canje GET de enlace de 1 uso → 303 |
| `/pantalla/[sede]` | pantalla de sala de espera (SSE + fallback polling) |
| `/sin-permiso` | 403 |

### 6.2 Reportes (declarados en `web/src/lib/reportes.ts` — NO comprimas "nueve")
| Clave | Título | Grupo (permiso) | Función | Con rango |
|---|---|---|---|---|
| `stock` | Stock actual | Inventario (operativos) | `reporte_stock` | no |
| `consumo` | Consumo de medicamentos | Inventario | `reporte_consumo` | sí |
| `turnos` | Turnos por día | Operación | `reporte_turnos` | sí |
| `turnos-hora` | Turnos por hora | Operación | `reporte_turnos_hora` | sí |
| `ocupacion` | Ocupación por consultorio | Operación | `reporte_ocupacion_consultorio` | sí |
| `caja` | Caja por día | Dinero (**financieros**) | `reporte_caja` | sí |
| `descuentos` | Descuentos aplicados | Dinero (**financieros**) | `reporte_descuentos` | sí |
| `margen` | Margen de medicamentos | Dinero (**financieros**) | `reporte_margen` | sí |
| `compras` | Compras por proveedor | Dinero (**financieros**) | `reporte_compras_detalle` | sí |
| `consultas` | Consultas por veterinario | Clínica | `reporte_consultas` | sí |
| `diagnosticos` | Diag. más frecuentes | Clínica | `reporte_diagnosticos` | sí |
| `pacientes` | Pacientes por especie | Clínica | `reporte_pacientes` | sí |

(El README dice "nueve reportes" y el encargado decía 9; el código declara **12** entradas. Documenta la realidad: 12 + `trazabilidad` especial sin rango.)

- Formato es-CO ($ COP, miles con punto, fechas dd/mm/aaaa, zona de Bogotá). CSV = la misma consulta con separador `;` + BOM, fechas numéricas crudas.

### 6.3 Autenticación web
- Cookie `chasquipet_sesion` (HttpOnly, sameSite=lax, 30 días, `secure` si `WEB_PUBLIC_URL` empieza por https://).
- `lib/sesion.ts`: `sesionActual()` → `SELECT sesion_por_token($1)`, `exigirSesion`, `exigirPermiso`; la base devuelve `{sesion_id, usuario_id, nombre, sede_id, permisos[]}`.

---
=== 7. CONFIGURACIÓN Y VARIABLES ===

`.env` (versionado) y `.env.example` (sin secretos). `.env` real incluye secciones integradas, `DEEPSEEK_API_KEY` poblado y `READONLY_DB_PASSWORD` vacío.

### 7.1 Variables de entorno
| Clave | Grupo | Propósito / valor actual |
|---|---|---|
| `TZ` | Zona | `America/Bogota` (no editable) |
| `PUERTO_DB` | Puertos | `5433` (la BD solo local) |
| `PUERTO_N8N_CON` | Puertos | `5679` (solo local) |
| `PUERTO_WEB` | Puertos | `3100` (LAN: portal + pantalla) |
| `PUERTO_PROXY` | Puertos | `8081` (solo local) |
| `COMPOSE_PROFILES` | Perfiles | `local` activa cloudflared + registrador |
| `POSTGRES_USER/PASSWORD/DB` | BD | `chasquipet` / password [MASKED] |
| `APP_DB_PASSWORD` | BD | rol aplicación (`chasquipet_app`) [MASKED] |
| `READONLY_DB_PASSWORD` | BD | rol lectura — vacío (= no se usa) |
| `DATABASE_URL` | BD | URI de la app |
| `ADMIN_DATABASE_URL` | BD | URI del administrador |
| `N8N_DB_NAME/USER/PASSWORD` | n8n | base `n8n` separada |
| `WEBHOOK_URL` | n8n | URL activa del túnel (este cambia cada reinicio) |
| `WEBHOOK_URL_FIJA` | n8n | dominio propio (opcional) |
| `N8N_BASIC_AUTH_USER/PASSWORD` | n8n | panel admin de n8n |
| `N8N_ENCRYPTION_KEY` | n8n | cifrado de credenciales n8n |
| `TELEGRAM_BOT_TOKEN` | Telegram | [MASKED] |
| `TELEGRAM_BOT_USERNAME` | Telegram | `chasqui_alunabot` |
| `SUPERADMIN_TELEGRAM_USER_ID` | Sistema | `7815282144` (real) |
| `SUPERADMIN_NOMBRE` | Sistema | Leonardo |
| `WEB_PUBLIC_URL` | Portal | `http://localhost:3100` |
| `SESSION_SECRET` | Portal | firma cookies [MASKED] |
| `WORKER_INTERVALO_MS` / `WORKER_LOTE` | Worker | 2000 / 10 |
| `DEEPSEEK_API_KEY` | IA | [MASKED] (real) |
| `BACKUP_RETENCION_DIAS` | Backup | 14 |
| `BACKUP_HORA` | Backup | 02:30 |

### 7.2 docker-compose.yml
| Servicio | Imagen | Puertos | Restart |
|---|---|---|---|
| `db` | postgres:16-alpine | 127.0.0.1:5433→5432 | unless-stopped |
| `n8n` | n8nio/n8n:2.31.5 | 127.0.0.1:5679→5678 | unless-stopped |
| `worker` | build | — | always |
| `web` | build | 0.0.0.0:3100→3000 | unless-stopped |
| `backup` | postgres:16-alpine | — | unless-stopped |
| `proxy` | caddy:2-alpine | 127.0.0.1:8081→80 | unless-stopped |
| `cloudflared` | cloudflare/cloudflared | — | unless-stopped |
| `registrador` | alpine:3.20 | — | unless-stopped |

Volúmenes: `db/migrations`→initdb, `n8n/workflows`→`/workflows`, `scripts`→`/scripts`, `backups`→`/backups`, `proxy/Caddyfile`→Caddy. Init DB: `000_n8n_db.sh` (base `n8n` aislada), `010..110` SQL y `900_superadmin.sh`.

### 7.3 Caddyfile
- `:80` HTTP plano; TLS termina en cloudflared. `/webhook/*` y `/webhook-test/*` → n8n:5678; any el resto → web:3000. El editor de n8n no se publica.

### 7.4 Scripts
- `backup.sh`: contenedor `backup` con bucle a `BACKUP_HORA`, `pg_dump -Fc -Z6`, retención 14 días, respaldo inmediato si el día no tiene.
- `cargar-demo.sh`: carga día simulado idempotente, imprime URL pantalla + QR.
- `configurar-bot.sh`: registra el webhook (lee de la DB `portal_url`), `setMyCommands` (11 comandos), QR.
- `crear-superadmin.sh`: genera el superadmin inicial.
- `importar-n8n.sh`: crea la credencial `chasquipet-postgres`, importa los workflows versionados, publica y reinicia n8n.
- `registrar-publico.sh` (servicio): cada 60 hora descubre el túnel, re-registra el webhook y la config `portal_url`.
- `restaurar.sh`: respaldo previo, terminación de conexiones, `pg_restore --clean --if-exists --no-owner --no-privileges --exit-on-error`.

---
=== 8. ESTADO ACTUAL DE FUNCIONALIDADES ===

| Funcionalidad | Estado | Detalle |
|---|---|---|
| Turnos + cola única + 2 consultorios + QR | COMPLETO | numeración con advisory lock, `llamar_siguiente` skips a subset en SKIP LOCKED, urgencia/cancelar/reencolar |
| Avisos a dueños del turno | COMPLETO | trabajos idempotentes |
| Pantalla sala de espera | COMPLETO | SSE+PROM polling, sin credencial |
| Persona manual | COMPLETO | bot `turno:manual` |
| Inventario (stock derivado, lotes, FEFO) | COMPLETO | movimientos inmutables, alerta diaria, bloqueo de vencidos |
| Salida de medicamentos (4 toques) | COMPLETO | FEFO + justificación, autoliga a la cuenta |
| Clínico (dueños/pacientes/historia/firma) | COMPLETO | borrador→firmada + adenda; consentimiento Ley 1581 |
| Consulta física por portal (form) | COMPLETO | `guardar_consulta_completa` |
| Pacientes (búsqueda, dedupección) | COMPLETO | trigramas + normalizar, posibles duplicados |
| Cobro (cuenta/descuentos/pago/recibo) | COMPLETO | append-only, caja a cero |
| Recibo (interno) | COMPLETO | consecutivo; texto "No es factura" |
| **Facturación electrónica DIAN** | **NO IMPLEMENTADO** | documentado como plan (`documento_electronico`), aviso legal en README |
| Caja (apertura/cierre/contado/diferencia) | COMPLETO | diferencia notifica a superadmin |
| Compras / proveedores | COMPLETO | en borrador, confirmación en todo o nada, soporte por foto |
| Reportes (12+traza) | COMPLETO | CSV, permisos |
| Trazabilidad de lote | COMPLETO | retiro → contacto de dueños |
| Admin (usuarios/roles/permisos/config/auditoría/cola) | COMPLETO | excepciones por permiso individual |
| IA "Habla con clavo" | COMPLETO (opcional) | DeepSeek + tools + confirmación |
| Jobs turnos / inventario / matenc. | COMPLETO | 1 min, 7:30, 3:15 |
| Backups | COMPLETO | diario 14 días |
| Datos demo | COMPLETO | idempotente |
| **Facturación DIAN (otra vez)** | **NO IMPLEMENTADO** | sin presencia legal ni técnica |
| **Presupuestos / cotizaciones** | **NO ENCONTRADO** | Plan F1 |
| **Horarios / disponibilidad (reserva)** | **PARCIAL** | sin lógica, tablas para F2 |
| **Carnet digital** | **NO ENCONTRADO** | Plan F2 |
| **Canal del cliente (reserva/pago online)** | **NO ENCONTRADO** | Plan F2 |
| Órdenes de compra / afiliaciones por pago | NO ENCONTRADO | declarado fase 2 |

---
=== 9. DEBILIDADES TÉCNICAS ===

1. **Sin migraciones incrementales post-deploy**. El esquema se aplica una sola vez (initdb). Cambios de esquema (F1/F2) no son versionados; realizar a mano el SQL y, con datos, con cuidado. **Impacto alto.**
2. **Facturación DIAN ausente (riesgo legal)**. El recibo se declara "no factura". Necesitas habilitación DIAN, software de facturación WRAPPOINT, y la tabla `documento_electronico` (CUFE/RAN, habilitación, etc.).
3. **Túnel efímero → URLs fugitivas**. cloudflared sin dominio fijo ⇢ el portal y el webhook cambian en cada reinicio. Usar `WEBHOOK_URL_FIJA`/dominio propio.
4. **IA "nivel medio"**: DeepSeek `deepseek-v4-pro` puede superar el nivel objetivo; para el presupuesto/reserva usa confirmación obligatoria y esquemas de herramientas estricticos (ya el patrón en 078). No generar HTML nunca.
5. **Sin API pública** para canal de cliente (F2): hoy no existe REST; el bot está limitado a Telegram.
6. **Sin observabilidad/alertas proactivas** más allá de la cola de tareas.
7. **Backup local único** en el mismo host: sin copia off-site, sin PITR/WAL archiving.
8. **Cierre de caja manual**: diferencia avisada, pero sin flujo de conciliación.
9. **Sin cabeceras de seguridad web** (sin CSP), cookie HttpOnly sí, pero irá mínimum.
10. **Sin pruebas automatizadas** (sin tests, sin CI) evitar regresión en ~200 datos en procedimientos.
11. **n8n panel accesible desde LAN**, con credenciales; riesgo concreto si la LAN no se fía.
12. **Worker único**: sin HA; el rescate existe pero la cola acumula si cae.
13. **Multi-sede virtual, no multi-sede UI** (solo 1 sede activa por la UI).
14. **`config` valida el tipo** sólo via CHECK; si se cambia un tipo de clave después, al jalarse de nuevo en jobs necesita cuidado.

---
=== 10. MAPA DE DEPENDENCIAS ===

### 10.1 Contrato entre componente (todas dependen de la BD)
```
        ┌──────────────────────────  Telegram Bot API ──────────────────────────┐
        │                                                                       │
 webhook ▼ /webhook/chasquipa → Caddy 8081 → n8n (01) → PG funciones →         │
 (registrador) ◄──setWebhook                                          enviar/editar
        │                                                                       │
        ▼                                                                       │
   ┌──  PostgreSQL chasquipet ────────────────────────────────────────────┐      │
   │   tarea_async  ──► worker (Node) ──► Bot API (sendMessage/editar)    │◄─────┘
   │        ▲ reclamar_tareas / arribar                                      │
   │        └ colq de avisos, recibos y resúmenes                                 │
   │   pantalla_turnos (NOTIFY) ◄── web (SSE /stream)                        │
   │   config.portal_url ◄── registrador.sh (webhook según túnel)            │
   └──── funciones de negocio (permiso in-function, auditoría) ──▲            │
          ▲                                                      │            │
   portal (SSR) ── pg directo ─────────────────────────────────┘            │
          │                                                            │
        web/auth: challenge ↔ bot (aut:si/no) → sha256 en sesion       │
   IA: worker → DeepSeek (OpenAI-API) ◄── ia_herramientas (no SQL directo) │
```

### 10.2 Dependencias de datos
- `turno.consulta_id`→`consulta` (FK en 050); `turno.cuenta_id`→`cuenta` (060).
- `lote.entrada_id`→`entrada_inventario` (070); `cuenta_linea.movimiento_id`→`movimiento_inventario` (060) — eventual ivy.
- `aviso_turno_enviado`→`turno` (CASCADAR).
- `consulta_adenda`→`consulta`.
- IA: `ia_accion_pendiente`→`usuario`, `ia_herramienta`→`permiso`.

### 10.3 Dependencias de proceso (no hay cron del sistema; todo dentro de docker)
- n8n `02` cada 1m → recordar vencidos + rescatas colgadas.
- n8n `03` 7:30 → bloquear vencidos + alerta inventario.
- n8n `04` 3:15 → mantenimiento diario.
- worker 2s → todas las tareas de la cola.
- `backup` contenedor a 02:30.
- `registrador` 24x7 resincroniza webhook + `portal_url`.

### 10.4 Carencias para FASE 1/2
- **Factura DIAN**: `documento_electronico(cuenta_id)` → CUFE/RADIAN → emisión vía job o portal.
- **Presupuesto/cotización**: hoja de datos en borrador (paralela a `cuenta` y `tarifa`), es necesario en el flujo al cierre.
- **Reserva online + Canal cliente**: las tablas `cita`/`disponibilidad` existen; habilitar canal público (web única o bot) reutilizando la semántica de `crear_turno_qr` + pago por adelantado opcional.
- **Carnet digital**: lado del `paciente` + historia; generar **PDF/QR** vía job o portal (hoy NO existe pdf/gen en el repo).
- **Permisos**: todo se basea en `usuario_permiso` / roles; añadir solo nuevas filas.