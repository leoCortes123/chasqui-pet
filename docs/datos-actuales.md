# Chasqui Pet — datos actuales de la base

Fotografía tomada el **1 de agosto de 2026** sobre la base `chasquipet`
(contenedor `chasquipet-db`). Casi todo proviene de `scripts/cargar-demo.sh`;
lo real es el superadmin con Telegram `7815282144`.

## Resumen por tabla

| Tabla | Filas | | Tabla | Filas |
|---|---:|---|---|---:|
| evento_auditoria | 918 | | tarifa | 8 |
| tarea_async | 484 | | usuario | 6 |
| cuenta_linea | 163 | | usuario_rol | 6 |
| movimiento_inventario | 118 | | entrada_inventario | 5 |
| rol_permiso | 89 | | rol | 5 |
| turno | 83 | | proveedor | 4 |
| cuenta | 66 | | tipo_servicio | 4 |
| pago | 62 | | auth_challenge | 2 |
| consulta | 49 | | consultorio | 2 |
| permiso | 29 | | sesion | 2 |
| entrada_linea | 21 | | sesion_consultorio | 2 |
| lote | 19 | | cierre_caja | 1 |
| config | 17 | | consulta_adenda | 1 |
| paciente | 15 | | sede | 1 |
| medicamento | 14 | | usuario_permiso | 1 |
| dueno | 12 | | cita, disponibilidad, conversacion_estado, aviso_turno_enviado, rate_limit | 0 |
| telegram_update | 11 | | | |
| descuento | 9 | | | |

## Sede y consultorios

Una sola sede activa: **Sede principal**
(`7093478f-81a3-450d-b218-de3d03a143d1`).

| Consultorio | Orden | Activo |
|---|---:|---|
| Consultorio 1 | 1 | sí |
| Consultorio 2 | 2 | sí |

## Usuarios del personal

| Nombre | Telegram ID | Teléfono | Rol | Activo |
|---|---:|---|---|---|
| Leonardo | 987654321 | — | superadmin | sí |
| Leonardo | 7815282144 | — | superadmin | sí |
| Camilo Andrés Reyes Mahecha | 900000001 | 300 412 8890 | veterinario | sí |
| Diana Marcela Ospina Cárdenas | 900000002 | 311 765 4402 | veterinario | sí |
| Yuly Paola Beltrán Rincón | 900000003 | 320 338 1176 | auxiliar | sí |
| Jefferson Cifuentes Molina | 900000004 | 316 209 5541 | recepcion | sí |

Hay dos superadmins llamados «Leonardo»: el `987654321` es el de la demo y el
`7815282144` es el Telegram real.

### Roles y permisos

| Código | Nombre | Nivel | Permisos |
|---|---|---:|---:|
| superadmin | Superadministrador | 100 | 29 |
| admin | Administrador | 80 | 28 |
| veterinario | Veterinario | 60 | 14 |
| auxiliar | Auxiliar | 40 | 13 |
| recepcion | Recepción | 20 | 5 |

De 29 permisos definidos, uno está además asignado directamente a un usuario
(`usuario_permiso`).

## Dueños

12 dueños, todos activos; 8 dieron consentimiento de datos y 4 tienen chat de
Telegram vinculado.

| Nombre | Teléfono | Barrio | Consiente | Telegram |
|---|---|---|---|---|
| Andrés Felipe Cárdenas | 312 558 7734 | Teusaquillo | sí | sí |
| Camilo Alberto Duarte | 319 445 2201 | San Cristóbal | no | no |
| Claudia Patricia Rojas | 318 667 2290 | Usaquén | sí | no |
| Diana Carolina Peña | 320 776 1123 | Engativá | no | no |
| Jorge Enrique Salazar | 311 289 4410 | Suba | sí | sí |
| Julián Esteban Ramírez | 316 774 5520 | Barrios Unidos | sí | no |
| Luis Alberto Mendoza | 313 902 5567 | Bosa | sí | no |
| Martha Lucía Vargas | 304 331 9987 | Puente Aranda | no | no |
| María Fernanda Gómez Ruiz | 300 412 7788 | Kennedy | sí | sí |
| Nubia Esperanza Castro | 305 118 6674 | Ciudad Bolívar | sí | no |
| Sandra Milena Torres | 301 445 8899 | Fontibón | sí | sí |
| Óscar Iván Betancur | 315 220 3341 | Chapinero | no | no |

## Pacientes

15 pacientes: 9 perros, 4 gatos, 1 conejo y 1 ave. Uno fallecido (Toby) y uno
sin dueño asociado (Tommy).

| Nombre | Especie | Raza | Sexo | Peso (kg) | Estado | Dueño |
|---|---|---|---|---:|---|---|
| Bruno | perro | Golden Retriever | macho | 32.500 | activo | Sandra Milena Torres |
| Canela | perro | Criollo | hembra | 16.900 | activo | Jorge Enrique Salazar |
| Coco | ave | Periquito | macho | 0.060 | activo | Julián Esteban Ramírez |
| Duque | perro | Beagle | macho | 12.800 | activo | Camilo Alberto Duarte |
| Firulais | perro | Criollo | macho | 18.400 | activo | María Fernanda Gómez Ruiz |
| Kira | perro | Pastor alemán | hembra | 30.100 | activo | Andrés Felipe Cárdenas |
| Luna | perro | Labrador | hembra | 28.700 | activo | María Fernanda Gómez Ruiz |
| Maya | gato | Criollo | hembra | 5.200 | activo | Nubia Esperanza Castro |
| Michifú | gato | Criollo | macho | 4.600 | activo | Jorge Enrique Salazar |
| Nala | gato | Siamés | hembra | 3.800 | activo | Luis Alberto Mendoza |
| Pelusa | conejo | Angora | hembra | 2.100 | activo | Óscar Iván Betancur |
| Rocky | perro | Pitbull | macho | 26.200 | activo | Diana Carolina Peña |
| Simba | gato | Naranja atigrado | macho | 4.100 | activo | Martha Lucía Vargas |
| Toby | perro | Schnauzer | macho | 8.300 | fallecido | Claudia Patricia Rojas |
| Tommy | perro | Criollo | macho | — | activo | (sin dueño) |

## Catálogo de medicamentos e insumos

14 productos, todos activos. «Stock» es la suma de lotes no bloqueados.

| Genérico | Comercial | Presentación | Categoría | Precio venta | Stock | Mínimo | Receta |
|---|---|---|---|---:|---:|---:|---|
| Amoxicilina | Amoxifar | Frasco 100 ml | Antibiótico | 1 200 | 1 788 | 200 | sí |
| Dexametasona | — | Frasco 20 ml | Corticoide | 1 500 | 84 | 40 | sí |
| Dipirona | — | Frasco 30 ml | Analgésico | 900 | 510 | 100 | no |
| Enrofloxacina | Baytril | Frasco 50 ml | Antibiótico | 2 400 | 440 | 100 | sí |
| Gasa estéril | — | Sobre x 5 | Insumo | 1 500 | 118 | 50 | no |
| Ivermectina | Ivomec | Frasco 50 ml | Antiparasitario | 1 800 | 201 | 80 | sí |
| Jeringa 3 ml | — | Unidad | Insumo | 700 | 372 | 100 | no |
| Ketamina | — | Frasco 10 ml | Anestésico | 9 000 | 18 | 20 | sí |
| Meloxicam | Metacam | Frasco 20 ml | Antiinflamatorio | 3 500 | 140 | 60 | sí |
| Praziquantel | Drontal | Caja x 10 | Antiparasitario | 4 500 | 86 | 20 | no |
| Suero fisiológico | — | Bolsa 500 ml | Fluidoterapia | 45 | 9 937 | 2 000 | no |
| Vacuna antirrábica | — | Vial monodosis | Biológico | 25 000 | 34 | 15 | sí |
| Vacuna quíntuple canina | Vanguard | Vial monodosis | Biológico | 32 000 | 35 | 10 | sí |
| Vacuna triple felina | Felocell | Vial monodosis | Biológico | 38 000 | 20 | 10 | sí |

**Bajo mínimo:** Ketamina (18 de 20).

## Lotes

19 lotes; uno bloqueado por vencimiento.

| Medicamento | Lote | Vence | Inicial | Actual | Costo unit. | Estado |
|---|---|---|---:|---:|---:|---|
| Amoxicilina | DEMO-AMX-2312 | 2026-08-25 | 300 | 288 | 600 | vence pronto |
| Amoxicilina | DEMO-AMX-2401 | 2027-09-04 | 1 500 | 1 500 | 620 | |
| Dexametasona | DEMO-DEX-2402 | 2027-06-26 | 120 | 84 | 800 | |
| Dipirona | DEMO-DIP-2403 | 2028-01-22 | 600 | 510 | 420 | |
| Enrofloxacina | DEMO-ENR-2402 | 2027-05-27 | 500 | 440 | 1 300 | |
| Gasa estéril | DEMO-GAS-2404 | 2029-01-16 | 150 | 118 | 700 | |
| Ivermectina | DEMO-IVM-2401 | 2027-07-31 | 300 | 201 | 950 | |
| Jeringa 3 ml | DEMO-JER-2404 | 2029-01-16 | 400 | 372 | 260 | |
| Ketamina | DEMO-KET-2401 | 2027-09-04 | 30 | 18 | 5 200 | |
| Meloxicam | DEMO-MLX-2309 | 2026-08-05 | 40 | 20 | 1 850 | vence pronto |
| Meloxicam | DEMO-MLX-2401 | 2027-02-26 | 120 | 120 | 1 900 | |
| Praziquantel | DEMO-PZQ-2310 | 2026-09-09 | 6 | 6 | 2 050 | |
| Praziquantel | DEMO-PZQ-2402 | 2027-04-27 | 80 | 80 | 2 100 | |
| Suero fisiológico | DEMO-SUE-2405 | 2028-03-22 | 10 000 | 9 937 | 18 | |
| Vacuna antirrábica | DEMO-VAR-2311 | 2026-08-18 | 4 | 4 | 11 800 | vence pronto |
| Vacuna antirrábica | DEMO-VAR-2403 | 2027-03-28 | 30 | 30 | 12 000 | |
| Vacuna quíntuple canina | DEMO-VQC-2312 | 2026-07-11 | 6 | 6 | 17 500 | **bloqueado — vencido** |
| Vacuna quíntuple canina | DEMO-VQC-2404 | 2026-11-28 | 40 | 35 | 18 000 | |
| Vacuna triple felina | DEMO-VTF-2404 | 2026-12-28 | 24 | 20 | 21 000 | |

«Vence pronto» = dentro de los 30 días de `alerta_vencimiento_dias`.
El movimiento de inventario tiene 118 registros.

## Proveedores y compras

| Proveedor | NIT | Teléfono | Contacto | Entradas | Última |
|---|---|---|---|---:|---|
| Agrocampo Suministros | 811004392-6 | 3012209987 | Mónica Ruiz | 1 | 2026-07-31 |
| Distribuidora Veterinaria del Norte | 830045129-3 | 3104458821 | Claudia Pineda | 1 | 2026-07-31 |
| Droguería Animal Express | 901552310-8 | 3209914455 | Iván Ramírez | 1 | 2026-07-31 |
| Laboratorios Zoovet | 900218447-1 | 3157742019 | Andrés Salgado | 2 | 2026-07-31 |

Cinco entradas de inventario, todas del 31/07/2026, con 21 líneas en total:

| Proveedor | Estado | Líneas | Costo total |
|---|---|---:|---:|
| Distribuidora Veterinaria del Norte | confirmada | 6 | 2 086 000 |
| Droguería Animal Express | confirmada | 6 | 1 550 300 |
| Laboratorios Zoovet | confirmada | 4 | 1 200 000 |
| Agrocampo Suministros | confirmada | 3 | 320 200 |
| Laboratorios Zoovet | borrador | 2 | 42 800 |

## Servicios y tarifas

| Código | Tipo de servicio | Prefijo | Prioridad | Duración | Visible en QR |
|---|---|---|---:|---:|---|
| general | Consulta general | A | 0 | 15 min | sí |
| vacunacion | Vacunación | V | 0 | 10 min | sí |
| control | Control / curación | C | 0 | 10 min | sí |
| urgencia | Urgencia | U | 100 | 30 min | no |

| Código | Tarifa | Valor sugerido | Valor libre |
|---|---|---:|---|
| consulta_general | Consulta general | 60 000 | no |
| consulta_urgencia | Consulta de urgencia | 90 000 | no |
| control | Control / curación | 30 000 | no |
| vacuna | Aplicación de vacuna | 25 000 | no |
| desparasitacion | Desparasitación | libre | sí |
| procedimiento | Procedimiento menor | libre | sí |
| certificado | Certificado de salud | 40 000 | no |
| otro | Otro cobro | libre | sí |

## Operación registrada

83 turnos, todos del 31/07/2026:

| Estado | Turnos |
|---|---:|
| finalizado | 65 |
| en_espera | 8 |
| ausente | 6 |
| cancelado | 2 |
| en_atencion | 1 |
| llamado | 1 |

49 consultas clínicas: 47 firmadas (del 30/12/2025 al 31/07/2026) y 2 en
borrador, más 1 adenda.

## Cobro y caja

| Estado de cuenta | Cuentas | Subtotal | Descuentos | Total | Pagado |
|---|---:|---:|---:|---:|---:|
| cerrada | 60 | 4 171 405 | 70 700 | 4 100 705 | 4 100 705 |
| abierta | 6 | 258 130 | 0 | 258 130 | 52 000 |

62 pagos y 9 descuentos, sobre 163 líneas de cuenta.

| Medio de pago | Pagos | Valor |
|---|---:|---:|
| efectivo | 40 | 2 656 960 |
| datáfono | 14 | 972 545 |
| transferencia | 8 | 523 200 |

Caja: un único registro, del 31/07/2026, **abierto**, con base inicial 200 000 y
todos los totales aún en cero (no se ha hecho el cierre).

## Configuración (`config`)

| Clave | Valor |
|---|---|
| alerta_vencimiento_dias | 30 |
| alerta_vencimiento_dias_critico | 7 |
| aviso_faltan_turnos | 2 |
| cantidades_entrada | 10,20,50,100 |
| cantidades_frecuentes | 1,2,3,5,10 |
| duracion_atencion_min | 15 |
| max_reencolados | 1 |
| moneda_simbolo | $ |
| nombre_clinica | Chasqui Pet |
| politica_datos_url | *(vacío)* |
| prioridad_urgencia | 100 |
| rate_limit_turno_seg | 60 |
| recibo_leyenda | Documento interno de la clínica. No es factura electrónica. |
| retencion_tareas_dias | 30 |
| retencion_updates_dias | 7 |
| timeout_llamado_seg | 180 |
| zona_horaria | America/Bogota |

## Auditoría y cola de tareas

918 eventos de auditoría, principalmente `crear` (499) y `finalizar` (390);
además `cargar` (18), `bloquear_vencido` (3), `iniciar` (2), `seed_superadmin`
(2) y uno de cada uno de `agregar_linea_medicamento`, `iniciar_atencion`,
`salida` y `abrir`.

484 tareas en `tarea_async`, **todas completadas**:

| Tipo | Total |
|---|---:|
| recordar_llamado_vencido | 479 |
| notificar_inicio_sesion | 2 |
| alertas_inventario | 1 |
| agregar_linea_cuenta | 1 |
| abrir_cuenta_turno | 1 |

Vacías: `cita`, `disponibilidad`, `conversacion_estado`, `aviso_turno_enviado` y
`rate_limit`. Hay 11 updates de Telegram, 2 sesiones de portal, 2 desafíos de
autenticación y 2 sesiones de consultorio.
