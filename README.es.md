# Claude Usage Tray

Icono en la bandeja de Windows con tu consumo de cuota de Claude. Dos números:
el de arriba es la **sesión** (ventana de 5 h), el de abajo la **semana** (todos
los modelos). Click izquierdo abre el panel con los tiempos de reset.

Sin dependencias: usa Windows PowerShell 5.1 y .NET Framework 4.8, que vienen de
serie en cualquier Windows 10/11.

---

## Instalar en un PC nuevo

Doble click en **`install.cmd`**. No pide permisos de administrador ni hace
preguntas. Hace cuatro cosas:

1. Ancla la carpeta en OneDrive (*conservar siempre en este dispositivo*), para que
   los archivos existan al arrancar aunque OneDrive no haya sincronizado todavía.
2. Quita la marca de internet de los archivos, que es lo que haría que Windows los
   tratase como no fiables.
3. Registra el arranque automático en `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
4. Comprueba que la API responde y arranca la app.

Para quitarlo: **`uninstall.cmd`**. Borra la entrada de arranque y para la app;
no borra archivos.

## Qué toca en el sistema

Solo tu cuenta de usuario. Nada más:

| Sitio | Para qué |
|---|---|
| `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | arranque automático |
| `%LOCALAPPDATA%\ClaudeUsageTray\` | caché del último dato y registro |
| esta carpeta de OneDrive | el código |

Nunca escribe en `HKLM`, ni en `ProgramData`, ni en el perfil de otro usuario, ni
pide elevación. La cuenta de administrador y el resto de usuarios del equipo no se
ven afectados.

## De dónde salen los números

De `GET https://api.anthropic.com/api/oauth/usage`, el mismo endpoint que usa el
comando `/usage` de Claude Code. Son los datos reales de tu cuenta, no una
estimación.

La app lee tu credencial OAuth de `~\.claude\.credentials.json` **en cada máquina**,
la usa solo para esa petición HTTPS y no la guarda en ningún sitio. **Por OneDrive
solo viaja código: el token nunca sale de cada PC.** La caché local guarda
únicamente porcentajes y fechas de reset.

Si la credencial caduca, la app **no la renueva a propósito**: renovarla rotaría el
refresh token por detrás de Claude Code y podría dejarte sin sesión. En su lugar
muestra el último dato en gris y se recupera sola en cuanto abras Claude Code.

## Uso

- **Click izquierdo** en el icono: panel con los tres porcentajes, sus barras y los
  tiempos de reset. Se cierra al pinchar fuera.
- **Pasar el ratón**: resumen corto en el tooltip.
- **Click derecho**: menú.

### Menú

| Opción | Qué hace |
|---|---|
| Actualizar ahora | fuerza una consulta inmediata |
| Frecuencia de actualización | tiempo real (15 s), 1, 2, 5, 15, 30 min, 1 h o 2 h |
| Abrir carpeta de la app | esta carpeta |
| Ver registro | `%LOCALAPPDATA%\ClaudeUsageTray\tray.log` |
| Iniciar con Windows | activa o desactiva el arranque automático |
| Salir | cierra la app |

La frecuencia elegida se guarda en `config.json`, así que se sincroniza por
OneDrive y el resto de PCs la heredan. Por defecto: **cada 15 minutos**.

Además se actualiza sola al abrir el panel (si el dato tiene más de un minuto) y al
despertar el equipo de suspensión.

## Se actualiza sola

Si editas `tray.ps1` o `config.json`, OneDrive los sincroniza y **cada PC reinicia
la app por su cuenta** en menos de un minuto. No hay que volver a ejecutar nada.
Antes de reiniciar espera a ver el archivo estable dos comprobaciones seguidas, para
no arrancar una versión a medio sincronizar. Se desactiva con `"autoUpdate": false`.

## Colores

Verde por debajo del 80 %, ámbar del 80 al 94, rojo del 95 en adelante. Gris
significa que el dato es viejo (sin red o credencial caducada). Los umbrales y los
colores están en `config.json`.

## `config.json`

```json
{
  "pollSeconds": 900,        // 15 = tiempo real, 7200 = cada 2 horas
  "autoUpdate": true,        // reiniciarse cuando OneDrive traiga una version nueva
  "warnPercent": 80,
  "critPercent": 95,
  "showScopedRow": true,     // fila del modelo con limite propio, si lo has usado
  "iconOutline": true,       // halo oscuro: legible en barras de tareas claras
  "colors": { "normal": "#3ED16B", "warning": "#F5A623",
              "critical": "#FF5A5F", "stale": "#9AA0A6" }
}
```

## Diagnóstico

```powershell
# imprime los valores y el tooltip, sin tocar la bandeja
powershell -NoProfile -ExecutionPolicy Bypass -File tray.ps1 -Once

# genera un PNG con el icono ampliado y el panel real
powershell -NoProfile -ExecutionPolicy Bypass -File tray.ps1 -Preview salida.png

# ejecuta con consola visible y log en pantalla
powershell -NoProfile -ExecutionPolicy Bypass -File tray.ps1 -Foreground
```

## Firma de código (opcional)

`trust.cmd` firma los scripts con un certificado autofirmado propio.

Sirve para que PowerShell deje de verlos como código sin identificar, y para que la
app siga funcionando si algún día este equipo pasa a política `AllSigned`.

**No** hace que Defender, SmartScreen ni un antivirus corporativo lo consideren un
editor de confianza: un certificado autofirmado no tiene reputación externa, solo
garantiza que el archivo no ha cambiado desde que lo firmaste. Windows te pedirá
confirmación una vez al meterlo en el almacén raíz.

Coste: cada vez que se edite `tray.ps1` la firma deja de valer y hay que volver a
ejecutarlo. Con la política por defecto (`RemoteSigned`) eso es inofensivo, pero con
`AllSigned` la app no arrancaría hasta refirmarla. Si no estás bajo `AllSigned`,
`install.cmd` ya es suficiente.

## Notas de implementación

- El icono son 16x16 píxeles físicos. El texto TrueType a ese tamaño es ilegible,
  así que los dígitos se dibujan con una fuente de píxeles hecha a mano: 5x7 para
  una y dos cifras, 3x5 para tres (5x7 no cabría en 16 px de ancho). Un halo oscuro
  translúcido los mantiene legibles sobre barras de tareas claras.
- `Icon.FromHandle(bmp.GetHicon())` devuelve un handle sin gestionar que el
  recolector de basura nunca libera. La app llama a `DestroyIcon` sobre el anterior
  en cada refresco. Medido: 12 handles GDI estables tras 600 refrescos; sin esa
  llamada, +1800.
- El panel crea sus controles una sola vez y después solo cambia textos y anchos.
  Reconstruirlos en cada tick era lo que provocaba el parpadeo.
- `NotifyIcon.Text` tiene un tope duro de 63 caracteres y lanza excepción por
  encima; de ahí el formato corto del tooltip.
- La consulta HTTP corre en un runspace aparte, así que una red caída nunca
  congela el icono.
