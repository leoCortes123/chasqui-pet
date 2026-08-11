# Guía de operación — Chasqui Pet

Para el personal de la clínica. No hace falta saber nada de computadores: todo
se hace por Telegram, con botones.

Si algo no está aquí, escríbale **`/ayuda`** al bot.

---

## Antes de empezar

**Usted no se registra solo.** El administrador lo da de alta con el número de
su Telegram, y desde ese momento el bot le contesta. Si le responde *«Para tomar
un turno, escanea el código QR»*, es que todavía no está dado de alta: avísele al
administrador.

Para saber su número de Telegram: escríbale a **@userinfobot**, le responde con
un número. Ese número es el que hay que darle al administrador.

**Escríbale `/menu` al bot.** Ese es el punto de partida de todo. Los botones que
vea dependen de su cargo: un veterinario ve *Llamar siguiente*, un auxiliar ve
*Cobrar*. Si no ve un botón, es que ese cargo no hace esa tarea.

---

## 1. La cola de pacientes

### El dueño toma su turno solo

En la entrada hay un afiche con un código QR. El dueño lo escanea con la cámara
del celular, se le abre Telegram, presiona **Iniciar** y el bot le contesta al
instante con su turno, cuántos hay antes y cuánto va a esperar.

**No le pide nombre, ni documento, ni nada.** Y como el bot tiene su chat, le
avisa solo cuando falten dos turnos y otra vez cuando le toque, con el
consultorio al que debe pasar.

### Cuando el dueño no tiene celular

Nadie se queda sin turno por eso. Desde el bot:

**`/menu` → ➕ Turno manual → el tipo de servicio**

Sale el turno igual, con su código. Como no hay chat, a esa persona hay que
llamarla en voz alta; el bot no puede avisarle.

### Atender

Al empezar el día, el veterinario abre su consultorio:

**`/menu` → 🚪 Abrir consultorio → Consultorio 1 o 2**

Desde ahí:

| Botón | Qué hace |
|---|---|
| 📢 **Llamar siguiente** | Toma el primero de la cola, se lo asigna a su consultorio y le avisa al dueño por Telegram. |
| ✅ **Ya llegó** | El paciente entró. Empieza la atención y **se abre sola la cuenta de cobro**. |
| ⚠️ **No se presentó** | Lo saca de la cola y le ofrece llamar al siguiente. |
| ↩️ **Reencolar** | Devuelve un ausente al final de la cola. Sólo se puede una vez. |
| 🏁 **Finalizar** | Termina la atención. La cuenta queda lista para que recepción cobre. |
| 📋 **Ver cola** | Quién está esperando y desde hace cuánto. |

**La cola es una sola para los dos consultorios.** El que se desocupa primero se
lleva el siguiente. Si los dos veterinarios presionan *Llamar siguiente* en el
mismo segundo, cada uno se lleva un paciente distinto: el sistema no deja que dos
consultorios llamen al mismo.

### Urgencias

Un caso urgente se adelanta con **🚨 Marcar urgencia**. El turno sube al principio
de la cola. Desde el QR nadie puede marcarse urgente: eso lo decide el personal.

### La pantalla de la sala de espera

En el monitor de la sala se ve el turno de cada consultorio en grande y los tres
siguientes en pequeño. Se actualiza sola. Si alguna vez se queda quieta, basta
recargar la página (F5); no hay que reiniciar nada.

---

## 2. Dueños y mascotas

**`/menu` → 🐾 Pacientes**

Buscar antes de crear. La búsqueda **aguanta errores de tipeo**: escriba
«mishifu» y encuentra a «Michifú». Se puede buscar por el nombre de la mascota,
por el del dueño o por el teléfono.

Para crear uno nuevo el bot pide, en este orden: nombre de la mascota, especie,
sexo, nombre del dueño y teléfono. **Sólo el nombre del dueño es obligatorio.**
Pedir cédula frena la atención y casi nunca hace falta.

Si el sistema sospecha que ese paciente ya existe, se lo dice antes de crear otro.
Haga caso a ese aviso: dos fichas del mismo animal parten su historia en dos.

### El consentimiento del dueño

Al vincular el Telegram de un dueño, el bot le pide **su autorización** para
escribirle (Ley 1581 de 2012). Si no la da, el sistema no le manda nada: ni el
resumen de la consulta ni el recibo. No es un trámite: es la ley, y el dueño
puede pedir que se borren sus datos cuando quiera.

---

## 3. La consulta

**`/menu` → 🩺 Consulta**, con el paciente ya en atención.

Todo lo que se puede elegir se elige con botones —especie, mucosas, hidratación,
condición corporal—. Sólo se escribe lo que de verdad hay que escribir.

**Se va guardando en cada paso.** Si se le apaga el celular en la mitad, al
volver el bot le ofrece seguir donde iba.

### Firmar

Una consulta sin firmar es un **borrador**: no vale como historia clínica. Para
firmarla hacen falta tres cosas y nada más:

- motivo de la consulta,
- diagnóstico,
- tratamiento.

Todo lo demás es opcional y se puede saltar.

> **Lo firmado no se edita.** Si se le olvidó algo, se le agrega una **adenda**,
> que queda con su nombre y la hora. Es como se lleva una historia clínica seria:
> no se borra lo escrito, se aclara.

Al firmar, si el dueño dio su autorización, le llega por Telegram un resumen de
la consulta.

### En el computador

Lo mismo se puede hacer en el portal, con el formulario completo y la historia
del paciente en una línea de tiempo. Es más cómodo para escribir párrafos largos.

---

## 4. Sacar un medicamento

**`/menu` → 💊 Salida**

Cuatro toques y ya:

1. Escriba el nombre (aguanta errores: «amoxi» encuentra Amoxicilina).
2. Toque el medicamento.
3. Toque la cantidad.
4. **Confirmar**.

**El lote no se pregunta:** el sistema toma el que vence primero, que es lo
correcto casi siempre. Si necesita otro —porque el frasco abierto es ese—, toque
*🔁 Otro lote* y escriba por qué. Queda registrado; no es un castigo, es para
saber después por qué se venció algo.

Si el paciente está en atención, **el medicamento cae solo en su cuenta**, al
precio del catálogo. Nadie teclea el precio.

### Lo que el sistema no deja hacer

- Sacar más de lo que hay.
- Sacar de un lote vencido. Sale bloqueado y sólo admite darlo de baja.

### Si se equivocó

No se borra. Se registra el movimiento contrario: una **devolución** o un
**ajuste**, con el motivo. Así el inventario siempre explica por qué cambió.

---

## 5. Cobrar

**`/menu` → 💵 Cobrar**

1. Toque la cuenta (las de pacientes que ya terminaron salen con ✅).
2. Revise el detalle: los medicamentos ya están ahí.
3. Agregue el servicio con **➕ Servicio**.
4. Toque **💵 Cobrar** y el medio de pago.

**El valor no se pregunta:** por defecto se cobra lo que falta. En efectivo puede
recibir de más y el bot le dice cuánto devolver.

### Descuentos

Sólo los ve quien tiene el permiso. Pide **cuánto** y **por qué**, y queda con su
nombre.

> El descuento **nunca borra ni cambia una línea**. El total original se conserva
> y la rebaja va aparte, para que a fin de mes se pueda ver qué se descontó y por
> qué.

### El recibo

Al cerrar la cuenta se emite un recibo con número consecutivo, y si el dueño
autorizó, le llega a su Telegram.

> ⚠️ **Es un documento interno de la clínica, no una factura electrónica.** El
> recibo lo dice. Para facturar de verdad ante la DIAN falta integrarlo, y eso es
> tarea del administrador antes de operar en firme.

### Si cobró mal

Igual que en inventario: no se borra, se **reversa**. El reverso también queda, y
la caja del día sigue cuadrando.

---

## 6. La caja

**`/menu` → 🧾 Caja**

**Al abrir la clínica:** *🔓 Abrir caja* y escriba con cuánta base arranca. Si no
hay base, escriba 0.

**Al cerrar:** cuente el efectivo del cajón —incluida la base— y escriba el total
en *🔒 Cerrar caja*. El bot compara con lo que debería haber y le dice si sobra o
falta.

Dos cosas que conviene saber:

- **No deja cerrar si quedan cuentas con saldo.** Primero se cobra, después se
  cuadra.
- **Si hay diferencia, el administrador se entera.** No es desconfianza: una
  diferencia que nadie mira se repite al mes siguiente.

---

## 7. Recibir mercancía del proveedor

**`/menu` → 📥 Entrada** (o escriba `/entrada`)

1. Elija el proveedor, o escriba el nombre si es nuevo.
2. **➕ Medicamento** por cada renglón de la factura: cuál, cuántos, a cuánto,
   cuándo vence y el número de lote.
3. **📎 Foto**: tómele una foto a la factura y mándela al chat. Si le pone como
   texto el número de factura, el bot lo toma también.
4. **✅ Ingresar al inventario**.

> **Hasta que no toque «Ingresar al inventario», nada ha entrado.** Puede dejarlo
> a medias, atender un paciente y volver después: el bot le dice *«Entrada (sin
> terminar)»* y sigue donde iba.

El vencimiento se escribe como venga en la caja: `12/2027` o `31/12/2027`, las dos
sirven.

Si el sistema le avisa que **compró más caro de lo que vende**, revise antes de
confirmar: casi siempre es un cero de más.

Una entrada ya confirmada no se edita. Si se equivocó, se arregla con un ajuste de
inventario, que queda con su motivo.

---

## 8. El portal (en el computador)

Se entra en **`http://<la dirección del servidor>:3100/entrar`**.

**No hay contraseña.** La pantalla muestra un código de seis dígitos, usted lo
confirma en el bot y entra. Cada vez que se abre una sesión, le llega un aviso a
su Telegram: si le llega uno que usted no pidió, presione **No fui yo** y esa
sesión queda cerrada.

**Desde el chat, sin teclear el código.** En el menú del bot está
**🖥️ Entrar al portal** (o escriba `/portal`): le devuelve un enlace que abre el
portal ya adentro. Sirve **una sola vez y por cinco minutos**, y pedir uno nuevo
anula el anterior. Si lo abre en el celular, entra en el celular; para entrar en
el computador de la clínica, cópielo allá. Ese enlace es su llave: quien lo abra
entra con su usuario, así que no se reenvía a nadie.

Ese enlace funciona **desde cualquier parte**, no sólo dentro de la clínica: el
portal sale a internet por el túnel, con la misma dirección por la que entra el
bot. Así se puede revisar la caja o una historia desde la casa.

La dirección que el bot pone en el enlace la mantiene el sistema solo (el
servicio `registrador` la escribe en **Administración → Configuración →
`portal_url`** cada vez que cambia). Sólo hay que tocarla a mano si se decide
operar sin túnel, dentro de la red: ahí va la IP del servidor
(`http://192.168.x.x:3100`).

Qué hay ahí que no esté en el chat:

- **Panel:** la cola en vivo, la caja del día y lo que está bajo mínimo.
- **Inventario:** el catálogo con los precios, editables en la misma tabla.
- **Compras:** el histórico de facturas y los proveedores.
- **Reportes:** los de abajo, todos con filtro de fechas y botón para bajarlos a
  Excel.
- **Administración** (sólo el administrador): personal y permisos, tarifas,
  tiempos de la cola y el rastro de todo lo que se ha hecho.

### Los reportes que más se usan

| Reporte | Para qué sirve de verdad |
|---|---|
| **Stock actual** | Qué hay que pedir esta semana. |
| **Turnos por hora** | A qué hora se llena la sala. Dice cuándo hace falta el segundo consultorio abierto. |
| **Caja por día** | Cuánto entró, por qué medio, y si algún día quedó descuadrado. |
| **Margen** | Cuánto se gana con cada medicamento, contra lo que costó el lote que salió. |
| **Trazabilidad de lote** | El día que un laboratorio retire un producto: se escribe el número del lote y salen los dueños a los que hay que llamar, con teléfono. |

---

## 9. Hablar con Chasqui

Los botones son el camino corto para lo que se hace todos los días. Cuando lo
que necesita no cabe en un botón —o no sabe en cuál está— escriba `/chasqui` o
toque **💬 Habla con Chasqui** en el menú, y pregunte como le preguntaría a un
compañero.

> — ¿cómo va la cola?
> — Hay 4 esperando. El más antiguo lleva 22 minutos y hay una urgencia, T-014.

> — ¿nos queda amoxicilina?
> — Sí, 288 tabletas. El lote que debe salir primero vence el 25 de agosto.

> — ¿qué falta por cobrar hoy?
> — Dos cuentas: la de Bruno por $41.200 y la de Kira por $28.000.

Consulta los datos reales, los del momento. No inventa cifras: si no encuentra
algo, se lo dice.

**También sirve para preguntas del negocio**, no solo del día: qué servicios se
atienden, cuánto vale una consulta, cómo está configurado algo, cómo se hace un
trámite en el bot.

### Cuando le pide que haga algo

Puede pedirle que llame al siguiente turno, saque un medicamento o registre un
pago. **Chasqui no lo hace solo.** Le muestra primero, con los datos concretos,
qué va a pasar:

> 💊 **Salida de inventario**
> Amoxicilina 500 mg · Lote DEMO-A24 · vence 28/03/2027
> Sale: **2 tabletas**
> Hay 30 → quedarían **28**
> ¿Lo hago? [✅ Sí, hazlo] [✖️ No]

Lo lee, y usted decide. La regla 3 del final de esta guía también aplica aquí, y
por el mismo motivo: nadie —ni una persona apurada ni el asistente— cambia el
inventario o la caja sin ese toque de más. Si pasan más de 10 minutos, la
propuesta caduca y hay que pedirla otra vez, porque los datos ya pudieron
cambiar.

**Solo puede hacer lo que usted puede hacer.** Si su cargo no cobra, pedirle que
cobre no lo va a lograr: se lo dice y le ofrece otra cosa.

Con **🧹 Olvidar lo hablado** empieza la conversación de cero. Con `/menu`
vuelve a los botones de siempre.

---

## 10. Cuando algo sale mal

**El bot no contesta.**
Espere unos segundos y vuelva a escribir `/menu`. Si sigue mudo, avísele al
administrador: probablemente sea la conexión a internet.

**Me quedé a mitad de algo y no sé dónde.**
Escriba `/menu`. Todo lo que estaba a medias está guardado: la consulta como
borrador, la factura del proveedor como entrada sin terminar.

**Toqué un botón y no pasó nada.**
El menú que tenía en pantalla puede ser viejo. Escriba `/menu` para pedir uno
nuevo.

**Me equivoqué en algo que ya confirmé.**
Nada se borra en este sistema; todo se corrige agregando lo contrario. Dígaselo
al administrador con lo que pasó: hay forma de arreglar todo, y queda claro qué
se arregló y quién lo hizo.

**No me aparece un botón que necesito.**
Ese botón es de otro cargo. Si de verdad le corresponde, el administrador puede
habilitárselo desde el portal en un minuto, sin tocar nada más.

**Al dueño no le llegó el recibo.**
Puede ser que no haya autorizado que se le escriba, o que no tenga su Telegram
vinculado. El administrador lo confirma en el portal, en *Administración →
Tareas*.

---

## 11. Tres reglas que el sistema no deja saltarse

Están puestas a propósito. Si alguna le estorba, hable con el administrador; no
busque la vuelta.

1. **Lo firmado y lo cobrado no se edita.** Se corrige agregando: una adenda, un
   reverso, un ajuste. Siempre queda quién y cuándo.
2. **Quien despacha el medicamento no es quien recibe el dinero.** El veterinario
   saca del inventario, recepción cobra. Es la forma más simple de que un error
   se note.
3. **Toda operación con dinero o inventario pide confirmación.** Ese toque de más
   es lo único que separa un cero mal puesto de un problema de verdad.
