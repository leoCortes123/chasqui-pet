# Reporte — Fase A7: Higiene de fronteras

**Plan:** `docs/plan-consolidacion-chasqui-pet.md` → Bloque A, Fase A7
**Estado:** `COMPLETED` (parte a). Parte b **descartada** con razón, ver §5.
**Fecha de verificación:** 2026-08-12
**Banco de pruebas:** base de trabajo con `scripts/migrar.sh`, más una migración de prueba
temporal para comprobar que la reja muerde.

## 1. Resumen

La convención de cabecera deja de ser una buena intención y pasa a ser una reja del migrador.
Cada migración nueva declara en su comentario de cabecera si toca el **NÚCLEO** o un
**VERTICAL**, y `scripts/migrar.sh` **se niega a aplicar** una tanda que contenga una
pendiente sin esa línea.

Cuesta una línea por migración y es lo que evita tener que arqueologizar 25 archivos el día
que haya que separar el producto genérico del veterinario.

## 2. Archivos

| Archivo | Cambio |
|---|---|
| `scripts/migrar.sh` | `ambito_declarado()` y una pasada previa que aborta la tanda entera (código 3) si alguna pendiente no declara ámbito. `--estado` marca las que están sin él. |
| `CLAUDE.md` | La convención escrita donde se lee antes de trabajar: *Database → Convenciones observadas*. Además, la puesta al día que salió de la auditoría del bloque A (ver `docs/auditoria-bloque-a.md` §4). |

Ninguna migración existente se tocó.

## 3. Diseño

**Se exige, no se advierte.** Una convención que solo imprime un aviso se pierde el primer
día con prisa. El migrador es el único camino previsto para aplicar una migración a una base
ya inicializada, así que es el punto exacto donde la regla no se puede rodear sin querer.

**Solo mira las pendientes.** Las 26 migraciones anteriores a la convención no se reescriben
—una migración aplicada no se edita— y la reja nunca las examina: la regla vale hacia
adelante sin tocar nada del pasado. Hoy declaran ámbito `075`, `120`, `130`, `140` y `150`,
que son todas las posteriores a la convención.

**Aborta antes de aplicar nada.** La comprobación es una pasada previa sobre todas las
pendientes, no un control dentro del bucle: fallar a la mitad dejaría media tanda aplicada
por culpa de un comentario, que es peor que no empezar.

**El mensaje trae la solución.** Al abortar imprime las dos líneas exactas que hay que pegar,
con la lista de qué cuenta como núcleo y qué como vertical. Un error que obliga a ir a buscar
la convención a otro archivo es un error que se rodea.

## 4. Pruebas ejecutadas

| # | Prueba | Esperado | Obtenido | Resultado |
|---|---|---|---|---|
| 1 | `bash -n scripts/migrar.sh` | sintaxis válida | Igual | PASS |
| 2 | `--estado` con todo aplicado | 31 aplicadas, 0 pendientes, sin ruido | Igual | PASS |
| 3 | Migración pendiente **sin** ámbito, `--estado` | la marca `pendiente (SIN ÁMBITO EN LA CABECERA)` | Igual | PASS |
| 4 | Migración pendiente **sin** ámbito, aplicar | aborta con código 3, no aplica nada, imprime cómo arreglarlo | Igual | PASS |
| 5 | La misma migración **con** `-- Ámbito: NÚCLEO` | vuelve a figurar como `pendiente` normal | Igual | PASS |
| 6 | Retirada la migración de prueba | 31 aplicadas, 0 pendientes | Igual | PASS |
| 7 | Regresión: reja de hash de A1 (archivo aplicado modificado) | se detiene con código 2 y no aplica nada | Igual | PASS |
| 8 | Regresión: batería completa | 8 archivos, 117 pruebas en verde | Igual | PASS |

La migración de prueba (`999_prueba_ambito.sql`) se creó, se usó y se borró; no llegó a
aplicarse a ninguna base y no dejó traza en `schema_version`.

## 5. Decisiones tomadas

**A7b (sacar presentación del núcleo) se descarta, no se pospone.** El plan ya la marcaba
como opcional y de valor bajo; al mirarla de cerca el valor es **negativo tal como está
especificada**:

- `pesos()` tiene 103 usos en las migraciones y 11 en `web`/`worker`; `fmt_cant()`, 40.
- El alcance del plan dice explícitamente crear los equivalentes `bot_*` y **dejar los
  originales como envoltorios**, sin migrar los llamantes (renumerar o mover código aplicado
  está fuera de alcance).
- El resultado sería **dos nombres para lo mismo** con los 143 llamantes apuntando al viejo:
  exactamente la duplicación que el bloque A pasó cinco fases eliminando.

Además, dos de las cuatro no son presentación de un vertical: formatear pesos colombianos y
cantidades es *locale*, y el locale es del núcleo. Solo `emoji_especie` es genuinamente
veterinario, y son ocho líneas.

Si algún día se separa el producto genérico del veterinario, el trabajo útil es mover los
llamantes, no crear alias. Ese día lo dirá la cabecera `Ámbito:` de cada archivo, que es
justo lo que deja la parte a.

Decisión tomada con el usuario el 12-ago-2026.

## 6. Riesgos y problemas encontrados

- La reja depende de una cadena de texto con tilde (`Ámbito:`). Un archivo guardado en una
  codificación distinta de UTF-8 la haría fallar como si faltara. Es un falso positivo
  ruidoso y con solución obvia, no un falso negativo: prefiere equivocarse hacia el lado
  seguro.
- La reja no comprueba que el ámbito declarado sea el **correcto**, solo que esté declarado.
  Eso no es automatizable: es criterio.

## 7. Trabajo pendiente

Ninguno en esta fase. El bloque A queda cerrado; ver `docs/auditoria-bloque-a.md`.
