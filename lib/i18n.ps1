<#
.SYNOPSIS
    Shared English/Spanish string tables for the tray app and the installer.

.DESCRIPTION
    Dot-source this file, call Set-AppLanguage once, then use T to look a string up.

    English is the base table and the fallback: any key missing from Spanish falls
    back to English, and a key missing from both returns the key itself. That way a
    forgotten translation shows up as a visible marker instead of an empty label or
    a crash — Set-StrictMode does not guard hashtable lookups, so a missing key would
    otherwise silently produce $null.

    Spanish strings are deliberately written without accents. The same tables feed a
    WinForms UI (Unicode, no problem) and a console window that may be running under
    codepage 850, where accented characters render as mojibake.
#>

$script:Strings = @{

    en = @{
        # ---- tray: refresh interval menu ----
        'poll.realtime'   = 'Real time (15 s)'
        'poll.min1'       = 'Every minute'
        'poll.min2'       = 'Every 2 minutes'
        'poll.min5'       = 'Every 5 minutes'
        'poll.min15'      = 'Every 15 minutes'
        'poll.min30'      = 'Every 30 minutes'
        'poll.hour1'      = 'Every hour'
        'poll.hour2'      = 'Every 2 hours'

        # ---- tray: limit names ----
        'limit.session'          = 'Session'
        'limit.weekly_all'       = 'Week - all models'
        'limit.weekly_scoped'    = 'Week - {0}'
        'limit.weekly_generic'   = 'Week - specific model'
        'short.session'          = 'Session'
        'short.weekly'           = 'Week'
        'short.model'            = 'Model'

        # ---- tray: reset countdowns ----
        'reset.none'      = 'no reset date'
        'reset.imminent'  = 'resetting now'
        'reset.days'      = 'resets in {0}d {1}h'
        'reset.hours'     = 'resets in {0}h {1}m'
        'reset.minutes'   = 'resets in {0}m'
        'reset.invalid'   = 'invalid reset date'
        'short.now'       = 'now'

        # ---- tray: errors ----
        'err.nodata'      = 'no data yet'
        'err.nolimits'    = 'response had no limit data'
        'err.unreadable'  = 'unreadable response'
        'err.noresponse'  = 'no response'
        'err.login'       = 'sign in to Claude Code'
        'err.expired'     = 'credential expired: open Claude Code'

        # ---- tray: panel ----
        'panel.title'     = 'Claude usage'
        'panel.updated'   = 'updated {0}'
        'panel.offline'   = 'offline - {0}'
        'panel.nodata'    = 'no data'
        'panel.empty'     = 'No usage data.'
        'tip.offline'     = '(offline)'

        # ---- tray: menu ----
        'menu.refresh'    = 'Refresh now'
        'menu.frequency'  = 'Refresh frequency'
        'menu.folder'     = 'Open app folder'
        'menu.log'        = 'View log'
        'menu.autostart'  = 'Start with Windows'
        'menu.language'   = 'Language'
        'menu.lang.auto'  = 'Automatic (system)'
        'menu.exit'       = 'Exit'

        # ---- plan detection (shared) ----
        'plan.pro'        = 'Claude Pro'
        'plan.max5'       = 'Claude Max 5x'
        'plan.max20'      = 'Claude Max 20x'
        'plan.team'       = 'Claude Team'
        'plan.enterprise' = 'Claude Enterprise'
        'plan.unknown'    = 'Claude subscription'
        'plan.api'        = 'API key (no quota)'
        'plan.none'       = 'not signed in'
        'plan.expired'    = 'credential expired'

        'plan.detail.ok'        = 'Quota limits are read from this subscription.'
        'plan.detail.expired'   = 'The stored credential has expired. Open Claude Code once to renew it; this app will not rotate it for you.'
        'plan.detail.api'       = 'This machine is set up for direct API access (API key, Bedrock or Vertex). Those are billed per token and have no session or weekly quota, so there is nothing for this app to display.'
        'plan.detail.none'      = 'No Claude Code credential was found for this Windows account. If you use Claude Code inside WSL, its credential lives in the Linux filesystem and this app cannot reach it.'
        'plan.detail.unreadable'= 'The credential file exists but could not be read.'

        # ---- installer: framing ----
        'wiz.title'       = 'Claude Usage Tray - Setup'
        'wiz.subtitle'    = 'Shows your Claude quota in the Windows notification area'
        'wiz.step'        = 'Step {0} of {1}'
        'wiz.lang.header' = 'Language'
        'wiz.lang.found'  = 'Detected system language: {0}'
        'wiz.lang.ask'    = 'Press E for English, S for Spanish, or Enter to keep it'
        'wiz.lang.set'    = 'Continuing in English.'

        'wiz.about.header'   = 'What this app does'
        'wiz.about.1'        = 'Draws your session and weekly Claude usage into a 16x16 tray icon.'
        'wiz.about.2'        = 'Reads the OAuth token Claude Code already stored on this account.'
        'wiz.about.3'        = 'Calls exactly one address: api.anthropic.com. Nothing else, ever.'
        'wiz.about.4'        = 'No admin rights, no service, no telemetry, no third-party code.'

        'wiz.check.header'   = 'Checking this machine'
        'wiz.check.os'       = 'Windows version'
        'wiz.check.ps'       = 'Windows PowerShell'
        'wiz.check.lang'     = 'Language mode'
        'wiz.check.policy'   = 'Execution policy'
        'wiz.check.files'    = 'App files'
        'wiz.check.ok'       = 'ok'
        'wiz.check.warn'     = 'warning'
        'wiz.check.fail'     = 'blocked'
        'wiz.check.langfail' = 'Constrained Language Mode is active, usually via AppLocker. This app needs full language mode and cannot run here.'
        'wiz.check.policywarn' = 'Machine policy forces AllSigned. Run trust.cmd after installing, or the app will not start.'
        'wiz.check.filesfail'  = 'tray.ps1 was not found next to this script.'

        'wiz.plan.header'    = 'Your Claude plan'
        'wiz.plan.found'     = 'Detected: {0}'
        'wiz.plan.tier'      = 'Rate limit tier: {0}'
        'wiz.plan.abort'     = 'Nothing was installed and nothing on this machine was changed.'
        'wiz.plan.aborthint' = 'Sign in with a Claude Pro or Max subscription and run this again.'

        'wiz.dest.header'    = 'Where it will be installed'
        'wiz.dest.from'      = 'From'
        'wiz.dest.to'        = 'To'
        'wiz.dest.inplace'   = 'Running in place: the app will stay in the folder above.'
        'wiz.dest.free'      = 'You can delete the source folder afterwards.'
        'wiz.dest.state'     = 'Cache and log'
        'wiz.dest.autostart' = 'Autostart'

        'wiz.perm.header'    = 'What it will touch'
        'wiz.perm.will'      = 'It writes'
        'wiz.perm.never'     = 'It never touches'
        'wiz.perm.never.1'   = 'HKLM or any machine-wide setting'
        'wiz.perm.never.2'   = 'Program Files, ProgramData, System32'
        'wiz.perm.never.3'   = 'Any other user account on this PC'
        'wiz.perm.never.4'   = 'Any host other than api.anthropic.com'
        'wiz.perm.continue'  = 'Press Enter to install, or Ctrl+C to cancel'

        'wiz.run.header'     = 'Installing'
        'wiz.run.copy'       = 'Files copied ({0})'
        'wiz.run.copyskip'   = 'Running in place, nothing copied'
        'wiz.run.unblock'    = 'Internet mark removed ({0} files)'
        'wiz.run.pin'        = 'Pinned in OneDrive (always keep on this device)'
        'wiz.run.pinskip'    = 'Not inside OneDrive, no pinning needed'
        'wiz.run.pinfail'    = 'Could not pin in OneDrive (not critical)'
        'wiz.run.cert'       = 'Signing certificate trusted (your account only)'
        'wiz.run.certfail'   = 'Could not trust the certificate: {0}'
        'wiz.run.autostart'  = 'Autostart registered under HKCU (your account only)'
        'wiz.run.started'    = 'App started'
        'wiz.run.stopped'    = 'Running copies stopped: {0}'

        'wiz.test.header'    = 'Testing the connection'
        'wiz.test.ok'        = 'The API answered. Your real numbers:'
        'wiz.test.fail'      = 'The API did not answer:'
        'wiz.test.hint'      = 'Open Claude Code once to renew the credential, then run install.cmd again.'

        'wiz.done.header'    = 'Done'
        'wiz.done.look'      = 'Look for the icon with two numbers in the notification area.'
        'wiz.done.hidden'    = 'If you cannot see it, open the hidden icons flyout (the ^ arrow) and drag it out.'
        'wiz.done.installed' = 'Installed at'
        'wiz.done.log'       = 'Log file'
        'wiz.done.uninstall' = 'To remove it: run uninstall.cmd'
        'wiz.done.repair'    = 'If anything breaks later: run install.cmd /repair'

        'wiz.repair.header'  = 'Repairing'
        'wiz.repair.done'    = 'Autostart rewritten and the app restarted.'

        'wiz.uninst.header'  = 'Uninstalling Claude Usage Tray'
        'wiz.uninst.run'     = 'Autostart entry removed from HKCU'
        'wiz.uninst.norun'   = 'There was no autostart entry'
        'wiz.uninst.files'   = 'App files are still at'
        'wiz.uninst.cache'   = 'Local cache is still at'
        'wiz.uninst.manual'  = 'Delete them by hand if you do not want them.'

        'wiz.credit'         = 'developed by iaeks.com'
    }

    es = @{
        'poll.realtime'   = 'Tiempo real (15 s)'
        'poll.min1'       = 'Cada minuto'
        'poll.min2'       = 'Cada 2 minutos'
        'poll.min5'       = 'Cada 5 minutos'
        'poll.min15'      = 'Cada 15 minutos'
        'poll.min30'      = 'Cada 30 minutos'
        'poll.hour1'      = 'Cada hora'
        'poll.hour2'      = 'Cada 2 horas'

        'limit.session'          = 'Sesion'
        'limit.weekly_all'       = 'Semana - todos los modelos'
        'limit.weekly_scoped'    = 'Semana - {0}'
        'limit.weekly_generic'   = 'Semana - modelo especifico'
        'short.session'          = 'Sesion'
        'short.weekly'           = 'Semana'
        'short.model'            = 'Modelo'

        'reset.none'      = 'sin fecha de reset'
        'reset.imminent'  = 'reset inminente'
        'reset.days'      = 'reset en {0}d {1}h'
        'reset.hours'     = 'reset en {0}h {1}m'
        'reset.minutes'   = 'reset en {0}m'
        'reset.invalid'   = 'fecha de reset invalida'
        'short.now'       = 'ya'

        'err.nodata'      = 'sin datos todavia'
        'err.nolimits'    = 'respuesta sin datos de limites'
        'err.unreadable'  = 'respuesta ilegible'
        'err.noresponse'  = 'sin respuesta'
        'err.login'       = 'inicia sesion en Claude Code'
        'err.expired'     = 'credencial caducada: abre Claude Code'

        'panel.title'     = 'Uso de Claude'
        'panel.updated'   = 'actualizado {0}'
        'panel.offline'   = 'sin conexion - {0}'
        'panel.nodata'    = 'sin datos'
        'panel.empty'     = 'Sin datos de uso.'
        'tip.offline'     = '(sin conexion)'

        'menu.refresh'    = 'Actualizar ahora'
        'menu.frequency'  = 'Frecuencia de actualizacion'
        'menu.folder'     = 'Abrir carpeta de la app'
        'menu.log'        = 'Ver registro'
        'menu.autostart'  = 'Iniciar con Windows'
        'menu.language'   = 'Idioma'
        'menu.lang.auto'  = 'Automatico (sistema)'
        'menu.exit'       = 'Salir'

        'plan.pro'        = 'Claude Pro'
        'plan.max5'       = 'Claude Max 5x'
        'plan.max20'      = 'Claude Max 20x'
        'plan.team'       = 'Claude Team'
        'plan.enterprise' = 'Claude Enterprise'
        'plan.unknown'    = 'Suscripcion de Claude'
        'plan.api'        = 'Clave de API (sin cuota)'
        'plan.none'       = 'sin sesion iniciada'
        'plan.expired'    = 'credencial caducada'

        'plan.detail.ok'        = 'Los limites de cuota se leen de esta suscripcion.'
        'plan.detail.expired'   = 'La credencial guardada ha caducado. Abre Claude Code una vez para renovarla; esta app no la rota por ti.'
        'plan.detail.api'       = 'Este equipo usa acceso directo a la API (clave de API, Bedrock o Vertex). Eso se factura por tokens y no tiene cuota de sesion ni semanal, asi que no hay nada que mostrar.'
        'plan.detail.none'      = 'No se ha encontrado ninguna credencial de Claude Code en esta cuenta de Windows. Si usas Claude Code dentro de WSL, su credencial vive en el sistema de archivos de Linux y esta app no puede leerla.'
        'plan.detail.unreadable'= 'El fichero de credenciales existe pero no se ha podido leer.'

        'wiz.title'       = 'Claude Usage Tray - Instalacion'
        'wiz.subtitle'    = 'Muestra tu cuota de Claude en la barra de Windows'
        'wiz.step'        = 'Paso {0} de {1}'
        'wiz.lang.header' = 'Idioma'
        'wiz.lang.found'  = 'Idioma del sistema detectado: {0}'
        'wiz.lang.ask'    = 'Pulsa E para ingles, S para espanol, o Enter para mantenerlo'
        'wiz.lang.set'    = 'Continuamos en espanol.'

        'wiz.about.header'   = 'Que hace esta app'
        'wiz.about.1'        = 'Dibuja tu uso de sesion y semanal de Claude en un icono de 16x16 en la bandeja.'
        'wiz.about.2'        = 'Lee el token OAuth que Claude Code ya guardo en esta cuenta.'
        'wiz.about.3'        = 'Llama a una sola direccion: api.anthropic.com. A ninguna mas, nunca.'
        'wiz.about.4'        = 'Sin permisos de administrador, sin servicios, sin telemetria, sin codigo de terceros.'

        'wiz.check.header'   = 'Comprobando este equipo'
        'wiz.check.os'       = 'Version de Windows'
        'wiz.check.ps'       = 'Windows PowerShell'
        'wiz.check.lang'     = 'Modo de lenguaje'
        'wiz.check.policy'   = 'Directiva de ejecucion'
        'wiz.check.files'    = 'Archivos de la app'
        'wiz.check.ok'       = 'ok'
        'wiz.check.warn'     = 'aviso'
        'wiz.check.fail'     = 'bloqueado'
        'wiz.check.langfail' = 'Constrained Language Mode esta activo, normalmente por AppLocker. Esta app necesita modo completo y no puede funcionar aqui.'
        'wiz.check.policywarn' = 'La directiva del equipo fuerza AllSigned. Ejecuta trust.cmd despues de instalar o la app no arrancara.'
        'wiz.check.filesfail'  = 'No se encuentra tray.ps1 junto a este script.'

        'wiz.plan.header'    = 'Tu plan de Claude'
        'wiz.plan.found'     = 'Detectado: {0}'
        'wiz.plan.tier'      = 'Nivel de limite: {0}'
        'wiz.plan.abort'     = 'No se ha instalado nada y no se ha cambiado nada en este equipo.'
        'wiz.plan.aborthint' = 'Inicia sesion con una suscripcion Claude Pro o Max y vuelve a ejecutarlo.'

        'wiz.dest.header'    = 'Donde se va a instalar'
        'wiz.dest.from'      = 'Desde'
        'wiz.dest.to'        = 'A'
        'wiz.dest.inplace'   = 'Ejecucion en el sitio: la app se queda en la carpeta de arriba.'
        'wiz.dest.free'      = 'Puedes borrar la carpeta de origen despues.'
        'wiz.dest.state'     = 'Cache y registro'
        'wiz.dest.autostart' = 'Arranque automatico'

        'wiz.perm.header'    = 'Que va a tocar'
        'wiz.perm.will'      = 'Escribe en'
        'wiz.perm.never'     = 'Nunca toca'
        'wiz.perm.never.1'   = 'HKLM ni ningun ajuste de toda la maquina'
        'wiz.perm.never.2'   = 'Program Files, ProgramData, System32'
        'wiz.perm.never.3'   = 'Ninguna otra cuenta de usuario de este PC'
        'wiz.perm.never.4'   = 'Ningun host que no sea api.anthropic.com'
        'wiz.perm.continue'  = 'Pulsa Enter para instalar, o Ctrl+C para cancelar'

        'wiz.run.header'     = 'Instalando'
        'wiz.run.copy'       = 'Archivos copiados ({0})'
        'wiz.run.copyskip'   = 'Ejecucion en el sitio, no se copia nada'
        'wiz.run.unblock'    = 'Marca de internet quitada ({0} archivos)'
        'wiz.run.pin'        = 'Anclado en OneDrive (conservar siempre en este dispositivo)'
        'wiz.run.pinskip'    = 'No esta dentro de OneDrive, no hace falta anclar'
        'wiz.run.pinfail'    = 'No se pudo anclar en OneDrive (no critico)'
        'wiz.run.cert'       = 'Certificado de firma confiado (solo tu cuenta)'
        'wiz.run.certfail'   = 'No se pudo confiar el certificado: {0}'
        'wiz.run.autostart'  = 'Arranque automatico registrado en HKCU (solo tu cuenta)'
        'wiz.run.started'    = 'App arrancada'
        'wiz.run.stopped'    = 'Copias en ejecucion detenidas: {0}'

        'wiz.test.header'    = 'Probando la conexion'
        'wiz.test.ok'        = 'La API ha respondido. Tus numeros reales:'
        'wiz.test.fail'      = 'La API no ha respondido:'
        'wiz.test.hint'      = 'Abre Claude Code una vez para renovar la credencial y vuelve a ejecutar install.cmd.'

        'wiz.done.header'    = 'Listo'
        'wiz.done.look'      = 'Busca el icono con los dos numeros en la bandeja del sistema.'
        'wiz.done.hidden'    = 'Si no lo ves, abre el desplegable de iconos ocultos (la flecha ^) y arrastralo fuera.'
        'wiz.done.installed' = 'Instalado en'
        'wiz.done.log'       = 'Archivo de registro'
        'wiz.done.uninstall' = 'Para quitarlo: ejecuta uninstall.cmd'
        'wiz.done.repair'    = 'Si algo falla mas adelante: ejecuta install.cmd /repair'

        'wiz.repair.header'  = 'Reparando'
        'wiz.repair.done'    = 'Arranque automatico reescrito y app reiniciada.'

        'wiz.uninst.header'  = 'Desinstalando Claude Usage Tray'
        'wiz.uninst.run'     = 'Entrada de arranque eliminada de HKCU'
        'wiz.uninst.norun'   = 'No habia entrada de arranque'
        'wiz.uninst.files'   = 'Los archivos de la app siguen en'
        'wiz.uninst.cache'   = 'La cache local sigue en'
        'wiz.uninst.manual'  = 'Borralos a mano si no los quieres.'

        'wiz.credit'         = 'developed by iaeks.com'
    }
}

$script:Lang = 'en'

function Get-AppLanguage {
    <# 'auto' resolves against the Windows UI culture; anything else is taken as-is
       when we have a table for it, and falls back to English when we do not. #>
    param([string]$Preference = 'auto')

    $value = if ($Preference) { $Preference.ToLowerInvariant() } else { 'auto' }
    if ($value -eq 'auto' -or -not $script:Strings.ContainsKey($value)) {
        try {
            $ui = (Get-UICulture).TwoLetterISOLanguageName
        } catch {
            $ui = 'en'
        }
        return $(if ($script:Strings.ContainsKey($ui)) { $ui } else { 'en' })
    }
    return $value
}

function Set-AppLanguage {
    param([string]$Language)
    $script:Lang = Get-AppLanguage $Language
    return $script:Lang
}

function T {
    <# Returns the string for $Key. Callers that need placeholders apply -f
       themselves: (T 'reset.days') -f 3, 9 #>
    param([string]$Key)

    $table = $script:Strings[$script:Lang]
    if ($table -and $table.ContainsKey($Key)) { return $table[$Key] }
    $fallback = $script:Strings['en']
    if ($fallback.ContainsKey($Key)) { return $fallback[$Key] }
    return $Key
}
