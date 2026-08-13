# Reporte — Fase B5: métricas del asistente

**Fecha:** 13 de agosto de 2026
**Tamaño:** S. No bloquea ni depende de nada del bloque B. **Cierra el
plan del asistente**: era su Fase 6, la única que quedaba sin empezar.

---

## 1. Cambios realizados

`analizar_ocupacion`, `analizar_rendimiento_medico` y
`analizar_rentabilidad_lotes` no existían: cero coincidencias fuera del
plan. Los números estaban —el portal los pinta y los exporta a CSV— pero
por chat no se podían pedir, que es donde está el personal.

Ahora las tres existen como herramientas de lectura del asistente:

1. **`analizar_ocupacion`** (`reportes.operativos`): turnos emitidos,
   atendidos y ausentes por día; distribución por hora; ocupación por
   consultorio y veterinario; espera y atención promedio. Responde «¿a qué
   hora se llena?», «¿cuánto están esperando?», «¿necesitamos otro
   consultorio?».
2. **`analizar_rendimiento_medico`** (`reportes.operativos`): por
   veterinario, consultas firmadas, **borradores sin firmar**, anuladas,
   pacientes distintos, turnos atendidos, duración media de la atención y
   horas de consultorio abierto.
3. **`analizar_rentabilidad_lotes`** (`reportes.financieros`): ingreso,
   costo y margen de lo despachado, **por medicamento y por lote**, con el
   total y el porcentaje de margen del período.

Las tres aceptan `desde`/`hasta` o el atajo `dias` («los últimos 30»), y
sin fechas usan el mes en curso, que es el defecto de los reportes de 080.
**Todas devuelven el rango junto con los datos**: una cifra sin período es
una cifra que se malinterpreta.

**No se escribió ni un reporte nuevo.** `080_reportes.sql` ya traía
`reporte_turnos`, `reporte_turnos_hora`, `reporte_ocupacion_consultorio`,
`reporte_consultas` y `reporte_margen`. Las tres operaciones los juntan y
los empaquetan; no recalculan nada. La única consulta nueva es el corte
**por lote** de la rentabilidad, que no existía en 080 y que el nombre de
la herramienta promete (ver decisión 3).

---

## 2. Archivos modificados

| Archivo | Qué |
|---|---|
| `db/migrations/210_ia_metricas.sql` | **Nuevo.** Toda la fase. Ámbito: VERTICAL. |
| `db/pruebas/095_metricas.sql` | **Nuevo.** 22 invariantes. |
| `docs/reporte-faseB5-metricas.md` | Este reporte. |

**No se tocó nada más.** Ni el worker (las herramientas salen del catálogo
en cada tarea, no hay que reconstruirlo), ni n8n, ni la web, ni ninguna
migración anterior.

---

## 3. Base de datos

### Funciones nuevas

| Función | Qué |
|---|---|
| `ia_metrica_desde(jsonb)`, `ia_metrica_hasta(jsonb)`, `ia_metrica_rango(jsonb)` | Resuelven el rango como lo dice una persona: `desde`/`hasta` explícitos, atajo `dias`, o el mes en curso. |
| `op_analizar_ocupacion(uuid, uuid, jsonb)` | Firma uniforme de la Fase A5. |
| `op_analizar_rendimiento_medico(uuid, uuid, jsonb)` | Íd. |
| `op_analizar_rentabilidad_lotes(uuid, uuid, jsonb)` | Íd. |

### Función reemplazada (de forma aditiva)

`bot_ia_bienvenida`: el cuerpo de 082 va entero y palabra por palabra —los
seis ejemplos condicionados por permiso— y se le suman dos, uno por cada
permiso de reportes. Verificado por diferencia contra `082:833`.

### Catálogo

Tres filas nuevas en `ia_herramienta` (órdenes 140–142), todas
`escribe = false`, `critica = false`, con `funcion` y `modulo = 'reportes'`
—un módulo nuevo en la columna de la Fase A5—.

### Permisos

**No se crea ninguno.** `reportes.operativos` y `reportes.financieros`
existen desde `075_prerrequisitos_ia.sql` y están repartidos en
`100_seed_roles.sql`. Verificado contra la base: recepción ve 0 métricas,
auxiliar y veterinario ven las 2 operativas, admin y superadmin las 3.
Quien ve los reportes en el portal es exactamente quien los puede
preguntar por chat.

### Migración

`210_ia_metricas.sql`, idempotente (`CREATE OR REPLACE`,
`INSERT … ON CONFLICT DO NOTHING`, `UPDATE` por nombre), con cabecera de
ámbito **VERTICAL**. Aplicada con `bash scripts/migrar.sh`.

---

## 4. Integraciones

| Integración | Estado |
|---|---|
| **Asistente / worker** | Las tres aparecen solas: `ia_herramientas()` arma el catálogo desde la tabla. El superadmin pasa de 31 a **34 herramientas**, 3 de ellas métricas. Sin cambios de código ni reconstrucción. |
| **Bot (Telegram)** | La bienvenida de «Habla con Chasqui» ofrece los dos ejemplos nuevos a quien tiene el permiso. |
| **n8n** | Sin cambios. |
| **Portal web** | Sin cambios: los mismos números ya se ven y se exportan por `web/src/app/api/reportes/`. |

---

## 5. Pruebas ejecutadas

**Batería completa:** `bash scripts/pruebas.sh` — **14 archivos, todo en
verde** (286 pruebas), sin regresiones.

`db/pruebas/095_metricas.sql` — 22 pruebas, todas PASS:

| # | Prueba | Esperado | Obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1 | Las tres están registradas y activas | 3 | 3 | PASS |
| 2 | **Ninguna métrica escribe** | 0 | 0 | PASS |
| 3 | Las tres declaran `funcion` y `modulo` | 0 sin declarar | 0 | PASS |
| 4 | `verificar_registro_operaciones()` con las métricas dentro | sin hallazgos | sin hallazgos | PASS |
| 5 | Permiso de la rentabilidad | `reportes.financieros` | igual | PASS |
| 6–8 | **Permisos insuficientes**: las tres con un actor sin permiso | `insufficient_privilege` | rechazan | PASS |
| 9 | `ia_llamar` con la métrica sin permiso | `ok:false`, no lanza | igual | PASS |
| 10 | Atajo «últimos 7 días» | `hoy - 7` | igual | PASS |
| 11 | Sin `hasta` | hoy | hoy | PASS |
| 12 | `desde` explícito manda sobre `dias` | 2026-01-15 | igual | PASS |
| 13 | Días del rango, con los dos extremos | 31 | 31 | PASS |
| 14 | **Lectura pura**: eventos de auditoría | sin cambio | sin cambio | PASS |
| 15 | **Lectura pura**: propuestas por confirmar | sin cambio | sin cambio | PASS |
| 16 | **Lectura pura**: tareas encoladas | sin cambio | sin cambio | PASS |
| 17 | **Ausencia de datos**: período vacío | `ok:true` en las tres | igual | PASS |
| 18 | El rango que vuelve es el que se pidió | `hoy - 30` | igual | PASS |
| 19 | Se despachan 10 unidades del lote de prueba | `ok:true` | `ok:true` | PASS |
| 20 | **Margen por lote** (100 u. a 400 de costo, venta 1000, salen 10) | 6 000 | 6 000 | PASS |
| 21 | Porcentaje de margen del lote | 60,0 % | 60,0 % | PASS |
| 22 | El total incluye ese margen | ≥ 6 000 | sí | PASS |

**Verificación manual sobre la base de desarrollo** (datos demo reales,
solo lectura):

| # | Escenario | Resultado |
|---|---|---|
| 23 | `analizar_ocupacion`, últimos 120 días | 136 emitidos, 65 atendidos, 6 ausentes, espera 24,4 min, atención 16,8 min; desglose correcto por consultorio y veterinario | PASS |
| 24 | `analizar_rendimiento_medico` | Tres médicos, con firmadas, borradores sin firmar, pacientes distintos y minutos por atención; el que no abrió consultorio sale con `null` en lo operativo y sus consultas igual | PASS |
| 25 | `analizar_rentabilidad_lotes` | Ingreso 1 134 535, costo 597 564, margen 536 971 (47,3 %); lista por lote con número de lote y vencimiento | PASS |
| 26 | Catálogo que ve el modelo | Superadmin: 34 herramientas, 3 métricas | PASS |
| 27 | Reparto por rol | recepción 0, auxiliar 2, veterinario 2, admin 3, superadmin 3 | PASS |

**Comandos:** `bash scripts/pruebas.sh` (verde), `bash scripts/migrar.sh`
(aplicada). No se corrió `npm run typecheck`/`build`: **no se tocó la web**.
No se corrió `npm run check`: **no se tocó el worker**.

---

## 6. Decisiones tomadas

1. **`exigir_permiso` DENTRO de las tres operaciones**, a diferencia de
   los otros trece `op_` de lectura. Los reportes de 080 deliberadamente
   no lo llaman —«el mismo dato se sirve por chat y por web y el control
   tiene que estar en un solo sitio»— y para el chat ese sitio es
   `ia_llamar` mirando `ia_herramienta.permiso`. Se agregó la segunda reja
   porque lo que exponen es el margen del negocio y el rendimiento de cada
   médico: es lo más sensible del catálogo de lectura y no debía depender
   de una sola fila de configuración. La prueba 6–8 lo sostiene.
2. **Ámbito VERTICAL.** Dos de las tres hablan el vocabulario del vertical
   (turnos, consultorios, consultas firmadas, veterinarios) y habría que
   rehacerlas para otro rubro; la de rentabilidad es de inventario y
   sobreviviría. La cabecera declara un ámbito y lo que hay que poder
   responder es «qué se rehace»: dos de tres.
3. **La rentabilidad se corta también por lote.** `reporte_margen` agrupa
   por medicamento, pero el nombre de la herramienta —el que fija el
   plan— promete lotes, y la diferencia es real: dos lotes del mismo
   medicamento comprados con seis meses de diferencia tienen costos
   distintos. El dato ya estaba (`movimiento_inventario.lote_id` +
   `lote.costo_unitario`, lo mismo que usa `reporte_margen`); solo faltaba
   agruparlo. Es la única consulta nueva de la fase.
4. **Promedios ponderados por turnos, no promedio de promedios.** Un
   martes de 40 turnos no pesa lo mismo que un domingo de 3. La
   aproximación que queda —la espera solo se mide sobre los turnos que
   llegaron a llamarse— va dicha en el propio jsonb (`nota_promedios`),
   para que el modelo no afirme más de lo que el número aguanta.
5. **Los borradores sin firmar salen en el rendimiento médico.** Es el
   número que dice si alguien está dejando historias a medias y es de lo
   poco que un administrador no puede ver de otra forma sin abrir consulta
   por consulta. La descripción de la herramienta le pide al modelo
   presentarlo sin juzgar a nadie.
6. **`modulo = 'reportes'`**, un valor nuevo en la columna de la Fase A5.
   Es exactamente para lo que esa columna existe: «qué sabe hacer esta
   instalación» sigue siendo una consulta.

---

## 7. Incertidumbres restantes

1. **`horas_abierto` cuenta las sesiones de consultorio abiertas hasta
   `now()`.** Viene de `reporte_ocupacion_consultorio` (080) y no se
   tocó, pero se nota al agregarlo: en la base de desarrollo da 313,2
   horas para ambos médicos porque hay sesiones que nadie cerró. El número
   es correcto según lo que registra el sistema; lo que está mal es la
   costumbre de no cerrar el consultorio. **No se corrigió aquí** porque
   sería cambiar un reporte existente que el portal ya pinta.
2. **Cómo redacta el modelo estas respuestas.** Las descripciones piden
   presentar el rendimiento sin juzgar y la nota de los promedios va en
   los datos, pero el tono final es del modelo. Solo se sabe leyendo
   conversaciones reales.
3. **No hay métrica de agenda ni de remisiones** (B1–B3 trajeron datos
   nuevos: citas, no-asistencias, resultados que no vuelven). El plan pedía
   tres métricas y son tres; ampliar el catálogo sin evidencia de uso
   habría sido adelantarse.

---

## 8. Riesgos y problemas encontrados

1. **Exponer plata y rendimiento por chat es lo más sensible que hace el
   asistente.** Mitigado con doble reja (catálogo + `exigir_permiso`),
   verificado en pruebas y contra el reparto real de roles: recepción no ve
   ninguna métrica.
2. **Un `op_` de lectura que escribiera pasaría inadvertido**: las pruebas
   de C6.9 (`070_ia_confirmacion`) solo recorren el catálogo de
   escrituras. Por eso 095 comprueba explícitamente que consultar métricas
   no deja auditoría, ni propuestas, ni tareas encoladas.
3. **`bot_ia_bienvenida` se reescribe entera** cada vez que una fase le
   agrega un ejemplo (078 → 082 → 210). Mismo problema que
   `bot_ia_callback` en B4 y la misma mitigación: copiar el cuerpo palabra
   por palabra y verificarlo por diferencia. Ya son dos funciones en esta
   situación.
4. **Ningún problema encontrado en los datos.** Las cifras de la
   verificación manual cuadran con los reportes del portal, que son las
   mismas funciones.

---

## 9. Desviaciones respecto al plan

| Plan | Implementado | Por qué |
|---|---|---|
| «tres wrappers de solo lectura» | Tres, más una consulta nueva por lote | El nombre `analizar_rentabilidad_lotes` promete lotes y `reporte_margen` agrupa por medicamento (decisión 3). |
| «tres `INSERT` en el registro» | Tres `INSERT` en `ia_herramienta` + `UPDATE` de `funcion`/`modulo` | Es el patrón de la Fase A5, el mismo de 170/180/190. |
| — | Se agregaron dos ejemplos a la bienvenida | Sin eso, nadie sabe que ahí se pueden pedir cifras. |
| — | Se agregó `exigir_permiso` dentro de las operaciones | Decisión 1. |

Nada del alcance quedó fuera. **Con esta fase, el plan del asistente
(fases 1 a 6) queda completo.**

---

## 10. Trabajo pendiente

- **Bloque B terminado**: B1 (agenda), B2 (controles), B3 (remisiones),
  B4 (plan multi-tarea) y B5 (métricas) están cerradas. Del plan de
  consolidación solo queda **A7b** (higiene de presentación: sacar
  `ia_resumen_accion` y `ia_texto_resultado` del núcleo), marcada como
  **opcional** y fuera de la secuencia.
- Cerrar las sesiones de consultorio al final del turno, o hacer que
  `reporte_ocupacion_consultorio` acote la sesión al día (incertidumbre 1).
  Es un cambio a un reporte existente y al portal: fase aparte.
- Métricas de agenda y remisiones, si el uso las pide (incertidumbre 3).
- Un despachador por dato para `bot_ia_callback` y `bot_ia_bienvenida`
  (riesgo 3), si aparece otra fase que les agregue ramas.
