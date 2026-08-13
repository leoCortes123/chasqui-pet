# Reporte — Fase 2: Borrador de consulta clínica asistido

**Plan:** `docs/plan-consolidacion-chasqui-pet.md` → Bloque A, Fase A2
(cierre formal de la Fase 2 del asistente «Habla con Chasqui»)
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-12
**Banco de pruebas:** contenedor `postgres:16-alpine` efímero, construido **desde
`db/migrations/`** y cargado con `db/demo/`. No se tocó la base de la clínica.

## 1. Resumen

La Fase 2 estaba implementada en `db/migrations/079_chasqui_ia_consulta.sql` (661 líneas)
desde antes de este plan, pero sin reporte, sin marcar y sin versionar en git.
`docs/reporte-fase3-despacho-recetas.md:79` ya lo registraba como riesgo. Esta fase **no
implementa nada nuevo**: verifica lo que hay, lo documenta y lo cierra.

Lo que hace `079`:

- Herramienta `preparar_consulta_clinica` (`consulta.crear`, `escribe = true`,
  `critica = false`, orden 270) en `ia_herramienta`.
- `ia_validar_examen_jsonb`: adelanta el rechazo del examen físico con los mismos rangos y
  las mismas opciones que `guardar_examen` (`050:1086`), para que la tarjeta no proponga
  algo que el guardado real rechazaría.
- `ia_consulta_borrador`: exige `consulta.crear`, normaliza lo dictado (acepta el examen
  como objeto o como medidas sueltas), valida examen y fecha, exige que llegue **algo**,
  arma la tarjeta —con la lista de lo que falta para poder firmar— y deja la propuesta en
  `ia_accion_pendiente`. **No toca la tabla `consulta`.**
- `ia_consulta_ejecutar`: solo tras la confirmación humana. Reutiliza el borrador en curso
  del mismo veterinario para ese paciente (ventana de 12 horas), o abre uno con
  `abrir_consulta`, vinculándolo al turno **solo si el turno en atención es de ese mismo
  paciente**; aplica los campos con `guardar_consulta_completa` —la misma validación del
  portal— y audita `consulta/<id>/ia_borrador`.
- Enganches: `ia_llamar` (ruta a la preparación), `ia_escribir` (ruta a la ejecución),
  `ia_texto_resultado` (respuesta con el enlace al portal), `bot_ia_bienvenida` (ejemplo
  para quien captura consultas) y `bot_ia_callback` (botón «🩺 Seguir esta consulta»).

La regla clínica se mantiene intacta: **el asistente deja un borrador y nunca lo firma**.
Cerrar la consulta sigue siendo `firmar_consulta` (`050:1207`) y la inmutabilidad la
sostiene el trigger `consulta_no_editar_firmada` (`050:247`).

## 2. Archivos

| Archivo | Cambio |
|---|---|
| `db/migrations/079_chasqui_ia_consulta.sql` | **Sin cambios.** Se verifica y se versiona en git tal como está aplicado. |
| `docs/reporte-fase2-borrador-consulta.md` | **Nuevo.** Este reporte. |
| `docs/plan-consolidacion-chasqui-pet.md` | Fase 2 marcada como completada en el §Anexo A3. |

No se modificó una sola línea de código en esta fase. Era el punto: `079` ya estaba
aplicado en producción y editarlo habría violado la regla de no tocar migraciones
aplicadas.

## 3. Base de datos

- **Tablas:** ninguna nueva. Usa `ia_herramienta`, `ia_accion_pendiente`, `consulta`,
  `examen_fisico` (vía `guardar_examen`), `turno`, `evento_auditoria`.
- **Funciones propias de la fase:** `ia_validar_examen_jsonb(jsonb)`,
  `ia_consulta_borrador(uuid, bigint, uuid, jsonb)`, `ia_consulta_ejecutar(uuid, jsonb)`.
- **Funciones de enganche reemplazadas por `079`:** `ia_llamar`, `ia_escribir`,
  `ia_texto_resultado`, `bot_ia_bienvenida`, `bot_ia_callback`. Las cuatro primeras las
  vuelven a reemplazar `081`–`083`, que son las versiones vigentes.
- **Permiso:** `consulta.crear`, ya existente (`100_seed_roles.sql`). No se creó ninguno.
- **Autorización:** `exigir_permiso(p_usuario_id, 'consulta.crear')` es la primera línea de
  `ia_consulta_borrador` y de `ia_consulta_ejecutar`; `ia_llamar` la comprueba antes con
  `tiene_permiso`. Tres rejas, verificadas una por una (T7–T10).
- **Auditoría:** `consulta/<id>/ia_borrador` con el estado antes y después; la confirmación
  audita además `ia_accion_pendiente/<id>/confirmar` (078).

## 4. Verificación de correspondencia con producción

Antes de dar nada por bueno se comparó el cuerpo de las ocho funciones entre la base
construida desde el repositorio y la base viva de la clínica (`md5(prosrc)`):

`ia_consulta_borrador`, `ia_consulta_ejecutar`, `ia_validar_examen_jsonb`, `ia_llamar`,
`ia_escribir`, `ia_texto_resultado`, `bot_ia_bienvenida`, `bot_ia_callback` → **idénticas**.

Es decir: lo que se probó y lo que se versiona es exactamente lo que está corriendo.

## 5. Pruebas ejecutadas

| # | Prueba | Esperado | Obtenido | Resultado |
|---|---|---|---|---|
| 1 | Caso exitoso: dictado completo (motivo, anamnesis, examen, diagnóstico, plan, recomendaciones, próxima revisión) | Propuesta con tarjeta, sin escribir | `ok:true`, `requiere_confirmacion:true`, tarjeta con los 5 bloques; `consulta` sin filas nuevas | PASS |
| 2 | Confirmación humana (`ia_confirmar`) | Se escribe el borrador | Consulta en estado `borrador` con todos los campos y el examen aplicado; propuesta `confirmada` | PASS |
| 3 | Auditoría | Evento del acto | `consulta / ia_borrador / telegram`, con actor | PASS |
| 4 | Respuesta al usuario | Texto con aviso de borrador y enlace | «Quedó el borrador de **Bruno**… 🔗 …/consulta/`<id>`» (ruta `web/src/app/(portal)/consulta/[id]` existe) | PASS |
| 5 | Datos inválidos: examen | Rechazo antes de proponer | `temperatura_c fuera de rango (60)`; `«presion» no es un campo…`; `«verdes» no es una opción válida de mucosas`; `«cuatro» no es un número para peso_kg` | PASS |
| 6 | Datos inválidos: fecha | Rechazo | `«el martes que viene» no es una fecha válida para la próxima revisión.` | PASS |
| 7 | Ausencia de datos | Rechazo con guía al modelo | Sin `paciente_id` → «Búscalo antes con buscar_paciente»; paciente inexistente → «ya no existe o no está activo»; dictado vacío → «Pide al usuario que dicte al menos el motivo» | PASS |
| 8 | Ningún rechazo deja basura | 0 propuestas | `ia_accion_pendiente` sin filas para los 8 rechazos | PASS |
| 9 | Permisos: `ia_llamar` con recepción | Negado, sin propuesta | «El usuario no tiene permiso para esto…»; 0 filas | PASS |
| 10 | Permisos: llamada directa al borrador y al ejecutor con recepción | Excepción de `exigir_permiso` | `No tienes permiso para esta acción (consulta.crear)` en ambas | PASS |
| 11 | Confirmación ajena | Rechazada | `Esa confirmación no es tuya.`; la propuesta sigue `pendiente` | PASS |
| 12 | Idempotencia: dos dictados seguidos del mismo paciente | Un solo borrador | Mismo `consulta_id` en las dos llamadas; `consulta` no crece | PASS |
| 13 | Los dos dictados no se pisan | Se acumulan los campos | `Vómito desde ayer \| Gastroenteritis alimentaria \| Dieta blanda` | PASS |
| 14 | Consulta firmada | No se reabre ni se edita | Tras `firmar_consulta`, el siguiente dictado abre una consulta nueva; la firmada queda intacta | PASS |
| 15 | Rollback ante error del guardado | Ver §7 | Los campos válidos quedan aplicados y el borrador abierto permanece; la llamada devuelve `ok:false` con el detalle | PASS con reserva |
| 16 | Vínculo con el turno | Solo si el turno es de ese paciente | Dictado del paciente en atención → `turno_id` del turno; dictado de otro paciente → `turno_id` nulo | PASS |
| 17 | Expiración de la propuesta (10 min) | No ejecuta | «Pasaron más de 10 minutos…», estado `expirada`, 0 consultas creadas | PASS |
| 18 | Cancelar con el botón (`ia:no`) | No hace nada | «✖️ Listo, no hice nada.», estado `cancelada` | PASS |
| 19 | Confirmar con el botón (`ia:ok`) | Escribe y ofrece seguir | Texto «✅ Hecho…» + botón «🩺 Seguir esta consulta» (`cli:consulta`) | PASS |
| 20 | Tarjeta de confirmación | Muestra lo que falta para firmar | «⚠️ Para firmar falta el tratamiento.» + botones Sí/No | PASS |
| 21 | Catálogo | Registro correcto | `permiso=consulta.crear escribe=t critica=f activa=t orden=270` | PASS |
| 22 | Bienvenida por permiso | Solo a quien puede | El ejemplo del borrador aparece para el veterinario y no para recepción | PASS |
| 23 | Integración worker | Corta en la confirmación y manda la tarjeta de la base | `chasqui_responder.js:278-315`: guarda el `pendiente`, pide `bot_ia_tarjeta_confirmacion` y envía; `node --check` limpio en todo `worker/src` | PASS |
| 24 | Correspondencia con producción | Idéntico | Las 8 funciones con el mismo `md5(prosrc)` en la base viva | PASS |

## 6. Decisiones tomadas

- **Probar contra un contenedor efímero construido desde las migraciones** en vez de contra
  la base viva, que es lo que hicieron las fases 1 y 3–5. Ahora se puede (Fase A1 arregló la
  instalación limpia) y es estrictamente mejor: los datos de la clínica no corren riesgo,
  la corrida es repetible y de paso vuelve a validar el migrador. Se comparó el `prosrc`
  contra producción para que la evidencia siga siendo válida allí (§4).
- **No corregir nada de `079` en esta fase.** Está aplicado en producción y la regla del
  proyecto es no editar migraciones aplicadas. Los dos detalles encontrados (§7) se
  reportan; corregirlos es una migración nueva y una decisión aparte.

## 7. Riesgos, hallazgos y reservas

**a) `NON_BLOCKING` — falta un salto de línea en la tarjeta.** En `079:249-251` el bloque de
cabecera termina con el dueño y se concatena directamente con `concat_ws`, sin `E'\n'`
intermedio. En la tarjeta se lee `👤 Sandra Milena Torres📝 Vómito desde ayer`, pegado. Es
cosmético y visible en cada tarjeta de borrador. Se corrige con un `CREATE OR REPLACE` de
`ia_consulta_borrador` en una migración nueva; no se hizo aquí por alcance.

**b) `UNCERTAINTY` — «todo o nada» no aplica al guardado de la consulta.**
`guardar_consulta_completa` (`050`) guarda **campo por campo** y acumula los errores: si uno
se rechaza, los demás quedan escritos y la función devuelve `ok:false` con la lista. Es su
contrato existente, compartido con el formulario del portal, no algo que introduzca `079`.
Consecuencia concreta, forzada en la prueba 15: si el guardado falla, el borrador que abrió
`abrir_consulta` **permanece abierto y vacío**. En el camino real es difícil de alcanzar
—el borrador valida examen y fecha antes de proponer— y el objeto resultante es, por
definición, un documento a medias que solo la firma cierra. Se acepta y se deja anotado.

**c) Observación sobre `078`, no sobre esta fase.** `ia_confirmar` marca la propuesta como
`confirmada` incluso cuando la ejecución devuelve `ok:false`, guardando el resultado. El
botón no sirve para reintentar: hay que volver a dictar. Es deliberado (evita el doble
cobro por doble toque) y queda registrado aquí solo para que conste.

**d) Fuera de alcance, ya planificado.** El bucle de `chasqui_responder.js` no corta tras la
primera propuesta de escritura (`!pendiente` sin `break`), así que un turno con varias
escrituras deja propuestas huérfanas. Es exactamente la **Fase A3** del plan.

## 8. Desviaciones respecto al plan

- El plan pedía la batería «contra `079` con datos demo». Se ejecutó con `db/demo/`, pero en
  base efímera y no en la viva, por lo dicho en §6.
- Se añadieron a la batería tres pruebas que el §Anexo A2 no exige y que aquí sí importan:
  vínculo con el turno (16), expiración de la propuesta (17) y correspondencia con
  producción (24).

## 9. Trabajo pendiente

- Corregir el salto de línea de la tarjeta (§7a) en una migración nueva, si se decide.
- Fase A3 del plan: propuestas huérfanas y purga de `ia_accion_pendiente` (§7d).
