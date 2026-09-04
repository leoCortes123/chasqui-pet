# db/simulacion — banco de datos para pruebas de usuario

Deja la base como una clínica a media jornada, con **todo** lo que hoy tiene
el sistema fechado en el **día en curso**: turnos, inventario, historia
clínica, cobro, compras, agenda de citas, controles y remisiones.

Existe porque los turnos y las citas son de hoy: una carga de ayer ya no
sirve para probar nada. Estos archivos se pueden volver a correr cada
mañana —o varias veces al día— y siempre anclan la jornada al momento en
que se ejecutan.

## Uso

```bash
bash scripts/simular.sh            # = dia
bash scripts/simular.sh dia        # rehace la jornada de hoy
bash scripts/simular.sh limpiar    # deja la base vacía de operación
bash scripts/simular.sh todo       # limpiar + dia
bash scripts/simular.sh estado     # qué hay cargado ahora mismo
```

Añada `--si` para no preguntar (útil al encadenarlo en otro script o en un
cron de la mañana).

## Qué corre y en qué orden

| Paso | Archivo | Para qué |
|---|---|---|
| 1 | `000_limpiar.sql` | Sólo en `limpiar` y `todo`: borra **toda** la operación de la base. |
| 2 | `005_soltar.sql` | Suelta remisiones y citas, que apuntan a las consultas que el paso 3 va a borrar. |
| 3 | `db/demo/*.sql` | El MVP, ya existente: turnos, inventario, clínica, cobro, compras. |
| 4 | `100_agenda.sql` | Franjas de atención y citas de hoy, de ayer y de los próximos días. |
| 5 | `110_controles.sql` | Consultas firmadas con próxima revisión, en varios horizontes. |
| 6 | `120_remisiones.sql` | Remisiones en plazo, vencidas, recibida y anulada. |
| 7 | `130_canales.sql` | Deja los avisos a dueños en un estado en el que se puedan probar. |

`dia` salta el paso 1: rehace lo simulado sin tocar lo que la clínica haya
capturado a mano probando el portal. `todo` sí arrasa.

## Marcas: qué es dato de prueba y qué no

- **Personal de simulación:** `usuario.telegram_user_id` entre `900000000` y
  `900999999`. El rango es **cerrado por arriba**: los ids de Telegram
  reales pasan de los diez dígitos y quedan *por encima* de él, así que un
  corte abierto («todo lo que supere 900000000») borraría a las personas
  de verdad, empezando por el superadministrador.
- **Chats de dueños inventados:** `telegram_chat_id` entre `900100000` y
  `900999999`.
- **Fichas de simulación:** `paciente.notas = 'DEMO'` y `dueno.notas = 'DEMO'`.
- **Inventario de simulación:** `medicamento.notas = 'DEMO'`,
  `lote.numero_lote LIKE 'DEMO-%'`, `entrada_inventario.observaciones = 'DEMO'`.

## Avisos de Telegram

`130_canales.sql` le pone a **dos** dueños el chat de una persona real del
sistema (el primer usuario que no sea de simulación y tenga chat, en la
práctica el superadministrador) y le **quita** el chat inventado a los
demás. Así los recordatorios de cita, los avisos de control y los
resultados de remisión llegan de verdad a un Telegram que se puede mirar,
y el resto no llena la cola de tareas fallidas con «chat not found».

Si nadie ha escrito todavía al bot desde una cuenta real, la base no tiene
ningún chat al que enganchar y el archivo lo dice por consola. Escríbale
`/menu` al bot una vez y vuelva a correr `bash scripts/simular.sh dia`.

## Advertencias

- Es un **banco de pruebas**. `limpiar` borra toda la operación de la base,
  incluida la auditoría. No lo corra sobre datos reales de la clínica.
- Los generadores escriben directo sobre las tablas en vez de llamar a
  `crear_cita()`, `crear_remision()` o `agendar_control()`. Es deliberado:
  esas funciones —con razón— rechazan el pasado, y una simulación necesita
  precisamente el pasado del día para que los indicadores no salgan en
  cero. Lo que sí se respeta es el modelo: cada fila cae donde caería en
  operación real y ninguna viola una restricción de la tabla.
- Nada de esto es una migración. `scripts/migrar.sh` no mira esta carpeta.
