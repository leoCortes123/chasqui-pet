# Reporte — Fase A4: Pruebas de los invariantes del núcleo

**Plan:** `docs/plan-consolidacion-chasqui-pet.md` → Bloque A, Fase A4
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-12
**Cómo se corre:** `bash scripts/pruebas.sh`

## 1. Resumen

El proyecto no tenía una sola prueba automatizada: todo se verificaba a mano con `psql`.
Las fases A5 y A6 refactorizan código que funciona —desmontar el `CASE` de `ia_llamar` y
subir al núcleo la orquestación del bot—, y eso sin red es la forma de trabajo con peor
historial que existe.

Ahora hay una batería de **96 pruebas** con pgTAP que corre desde cero en una base
construida a partir de `db/migrations/`. El alcance es deliberadamente mínimo: no se busca
cobertura, se blindan los invariantes que, si se rompen, rompen el producto o su
cumplimiento legal.

Efecto secundario buscado: cada corrida vuelve a validar la instalación limpia y, con ella,
el migrador de la Fase A1.

## 2. Archivos

| Archivo | Qué es |
|---|---|
| `db/pruebas/Dockerfile` | **Nuevo.** `postgres:16` + `postgresql-16-pgtap`. |
| `db/pruebas/000_arnes.sql` | **Nuevo.** Extensión pgTAP, esquema `prueba` y constructores de datos (`prueba.usuario`, `prueba.paciente`, `prueba.lote`…). |
| `db/pruebas/010_permisos.sql` | **Nuevo.** 28 pruebas: `exigir_permiso` en cada función de escritura. |
| `db/pruebas/020_append_only.sql` | **Nuevo.** 14 pruebas: dinero, movimientos y auditoría. |
| `db/pruebas/030_fefo.sql` | **Nuevo.** 9 pruebas: FEFO con justificación. |
| `db/pruebas/040_consulta_firmada.sql` | **Nuevo.** 10 pruebas: inmutabilidad de la historia clínica. |
| `db/pruebas/050_caja.sql` | **Nuevo.** 12 pruebas: el cuadre de caja. |
| `db/pruebas/060_consentimiento.sql` | **Nuevo.** 11 pruebas: Ley 1581. |
| `db/pruebas/070_ia_confirmacion.sql` | **Nuevo.** 12 pruebas: confirmación humana (C6.9). |
| `scripts/pruebas.sh` | **Nuevo.** Corredor: construye, levanta, carga el andamio, corre e informa. |
| `README.md` | Sección «Pruebas», estructura y operaciones frecuentes. |

Ni una línea de `db/migrations/`, `web/` o `worker/` cambió: la fase solo agrega
verificación.

## 3. Diseño del arnés

- **La base se construye desde las migraciones**, no desde un dump. Así la prueba mide el
  repositorio y no una foto vieja.
- **Cada archivo corre en una transacción que termina en `ROLLBACK`.** No hay limpieza que
  se pueda olvidar y las pruebas no se contaminan entre sí.
- **Los constructores llaman a las funciones de negocio reales** (`crear_dueno`,
  `ingresar_lote`, `crear_turno_manual`…) en vez de insertar filas a mano: si mañana una
  cambia de contrato, la batería se entera.
- **El actor de las pruebas de permisos es un rol vacío** (`prueba_sin_permisos`), no
  «recepción»: así la prueba no se vuelve falsa el día que alguien reparta los permisos de
  otra manera.
- **La prueba de C6.9 recorre el catálogo**, no una lista escrita a mano: cubre sola
  cualquier herramienta que se registre en el futuro.
- **El contenedor de pruebas es aparte**, sin puertos publicados, y se destruye al terminar
  (`--conservar` para inspeccionarlo).

## 4. Invariantes cubiertos

| Invariante | Archivo | Qué se demuestra |
|---|---|---|
| Autorización en SQL (C6.5) | `010` | 28 funciones de escritura de turnos, inventario, clínico, cobro y compras lanzan `42501` con un actor sin permisos, **antes** de mirar los datos (los argumentos son inválidos a propósito). |
| Append-only | `020` | Los triggers rechazan UPDATE/DELETE sobre `pago`, `descuento`, `movimiento_inventario` y `cuenta_linea` **incluso al dueño de la base**; y `chasquipet_app` no puede editar ni borrar `evento_auditoria` ni `telegram_update`. |
| FEFO | `030` | Sin motivo escrito, la salida del lote equivocado se rechaza con `fefo_sin_justificacion`, devuelve el lote correcto y **no descuenta nada**; con motivo, procede y el motivo queda en el movimiento. |
| Historia clínica inmutable | `040` | En borrador se escribe; firmada, ni el trigger ni la función admiten cambios y el texto original sobrevive; la corrección legítima —anular con motivo— sí procede. |
| La caja cuadra | `050` | No se cierra con cuentas con saldo abierto; el esperado sale de los pagos reales, separado por medio de pago; contando lo mismo que dicen los pagos, la diferencia es cero. |
| Consentimiento (Ley 1581) | `060` | Sin consentimiento o sin chat vinculado no se arma ni el borrador; el camino legítimo propone pero **no envía**; y al confirmar se revalida, así que un consentimiento retirado en el medio detiene el envío. Retirar el consentimiento desvincula el chat. |
| Confirmación humana (C6.9) | `070` | Ninguna de las herramientas con `escribe = true` devuelve una ejecución hecha; tras llamarlas todas, ni un turno, ni una consulta, ni un pago, ni un movimiento, ni una tarea encolada. Además: toda herramienta que escribe tiene permiso y tiene ejecutor en `ia_escribir`. |

## 5. Pruebas ejecutadas

Corrida completa desde cero:

```
  010_permisos.sql                 28 pruebas ✔
  020_append_only.sql              14 pruebas ✔
  030_fefo.sql                      9 pruebas ✔
  040_consulta_firmada.sql         10 pruebas ✔
  050_caja.sql                     12 pruebas ✔
  060_consentimiento.sql           11 pruebas ✔
  070_ia_confirmacion.sql          12 pruebas ✔

Todo en verde: 7 archivos de prueba.
```

Y las pruebas del propio corredor:

| # | Prueba | Esperado | Obtenido | Resultado |
|---|---|---|---|---|
| 1 | Corrida completa | 96 en verde, salida 0 | 96 en verde, `$? = 0` | PASS |
| 2 | Un archivo con una prueba que falla | Lo reporta y sale distinto de 0 | Muestra el `not ok` con el diagnóstico y `$? = 1` | PASS |
| 3 | Filtro por prefijo (`pruebas.sh 030`) | Corre solo ese archivo | Solo `030_fefo.sql` | PASS |
| 4 | Filtro que no existe (`pruebas.sh 555`) | Avisa y falla, no «todo en verde» | «No se encontró ningún archivo…», `$? = 1` | PASS |
| 5 | Instalación limpia rota | Se detiene con el error de initdb | Cubierto por la espera del corredor (busca `psql:…ERROR` en el log) | PASS |
| 6 | Limpieza | El contenedor no queda | `docker ps -a` sin rastro tras cada corrida | PASS |

Durante el desarrollo, la batería ya encontró cuatro suposiciones equivocadas **mías**
sobre el sistema, que es exactamente para lo que sirve: `ajustar_lote` recibe el tipo de
ajuste antes de la cantidad; los triggers de append-only lanzan `0A000` y el de la consulta
firmada `P0001`; y `registrar_pago` **no cierra la cuenta** —cerrarla es un acto aparte,
`cerrar_cuenta`, que es el que emite el recibo—. Ninguna era un defecto del sistema.

## 6. Decisiones tomadas

- **Imagen Debian para las pruebas, Alpine en producción.** pgTAP no está empaquetado para
  Alpine y sí en el repositorio PGDG que trae `postgres:16`. Compilarlo en Alpine habría
  costado un `build` largo y frágil para probar exactamente lo mismo: las reglas viven en
  plpgsql, no en la libc.
- **Locale `C.UTF-8` en las pruebas**, no `es_CO.UTF-8`: el contenedor Debian no lo trae
  generado. Lo único sensible a eso es el ordenamiento de texto, que ninguna de estas
  pruebas ejercita. Anotado en el `Dockerfile`.
- **Sin `pg_prove`.** Los archivos se corren con `psql` y el corredor cuenta los `not ok`.
  Evita depender de Perl y del CPAN para algo que son tres líneas de shell.
- **Se prueba el SQLSTATE, no el texto del mensaje.** Los mensajes son de presentación y
  van a cambiar; el código de error es el contrato.
- **No se probó la tercera capa de consentimiento** (`enviar_aviso_dueno.js`): es
  JavaScript y esta batería es SQL. Queda dicho en el archivo `060` y aquí.

## 7. Riesgos y problemas encontrados

- **Ningún defecto del sistema.** Los 96 invariantes se cumplen tal como están escritos en
  `chasquipet.md` y en el plan.
- **`registrar_movimiento` no exige permiso** y por eso no está en la batería de `010`. No
  es un agujero: es un ayudante interno, sin puerta desde el bot ni desde la web, al que
  solo llegan `salida_medicamento`, `ingresar_lote` y `ajustar_lote`, que sí exigen permiso
  —y las tres están probadas—. Queda anotado porque el día que alguien lo exponga a un
  canal, hay que ponerle su `exigir_permiso`.
- **La prueba «toda herramienta tiene ejecutor» mira `prosrc`.** Es caja blanca y se
  romperá cuando la Fase A5 desmonte el `CASE`; entonces la reemplaza
  `verificar_registro_operaciones()`, que es justamente lo que el plan pide para compensar
  la pérdida de verificación estática. Es un reemplazo previsto, no una deuda.
- **La batería tarda ~40 s** porque levanta la base entera. Es el precio de probar contra
  las migraciones reales y vale la pena; para iterar está el filtro por prefijo y
  `--conservar`.

## 8. Desviaciones respecto al plan

- El plan enumeraba siete invariantes; se cubren los siete. Se agregaron de propina los
  invariantes de catálogo del asistente (toda herramienta que escribe tiene permiso y
  tiene ejecutor), que salían casi gratis en el mismo archivo.
- El plan decía «arnés con pgTAP en un contenedor efímero»; se añadieron el filtro por
  prefijo y `--conservar` porque sin ellos iterar sobre una prueba cuesta 40 segundos.

## 9. Trabajo pendiente

- Nada de A4 queda abierto.
- Sigue pendiente de A2: el salto de línea de la tarjeta de borrador (`079:249-251`).
- La siguiente del plan es **A5** (registro declarativo de operaciones). Cuando desmonte el
  `CASE`, hay que sustituir la prueba de `prosrc` de `070` por
  `verificar_registro_operaciones()`.
