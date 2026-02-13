# MacBook Pro 15,1 (2018) — Investigacion del fallo de GPU AMD

## Identificacion de la maquina

- **Modelo:** MacBook Pro 15,1 (Mid 2018, 15 pulgadas con Touch Bar)
- **CPU:** Intel Core i7 de 6 nucleos @ 2.6 GHz (Coffee Lake, 8va generacion)
- **RAM:** 16 GB
- **GPUs:** Intel UHD Graphics 630 (integrada) + AMD Radeon Pro 560X (dedicada)
- **Pantalla:** 15.4" Retina, 2880 x 1800 resolucion nativa
- **Almacenamiento:** Apple SSD (APFS)
- **Chip de seguridad:** Apple T2
- **macOS:** 13.7.8 Ventura (Darwin 22.6.0)
- **Serial:** C02XJ3SQJG5M
- **Firmware:** 2094.40.1.0.0 (iBridge: 23.16.13087.5.3,0)
- **Fecha de la solucion:** 13 de febrero de 2026

---

## El problema

La GPU dedicada AMD Radeon Pro 560X estaba fallando intermitentemente. Sintomas:

1. **Kernel panics** — Reinicios repentinos sin aviso. El sistema se caia en pleno uso.
2. **Bucles de reinicio** — Despues de un panic, macOS intentaba reiniciar, activaba la GPU AMD de nuevo, y se caia otra vez.
3. **Crashes de WindowServer** — El servidor de pantalla se congelaba por errores de GPU, la pantalla se ponia negra y habia que forzar un reinicio.

Este es un defecto de hardware bien documentado en la linea MacBook Pro 15 pulgadas de 2018. Las soldaduras de la AMD Radeon Pro 555X/560X o el propio die de la GPU se degradan con el tiempo, especialmente bajo estres termico. Apple nunca emitio un recall formal para este modelo.

### Por que es dificil de arreglar

En un Mac normal, harias una de estas cosas:
- Reemplazar la placa logica (caro, ~$600-800 USD)
- Eliminar las extensiones de kernel (kexts) de la GPU AMD para que macOS no hable con el hardware danado

Pero en macOS 13 Ventura, el volumen del sistema esta **criptograficamente sellado** (Signed System Volume, SSV). Literalmente no puedes modificar `/System/Library/Extensions/` — ni siquiera con SIP deshabilitado, ni siquiera como root. El sello es verificado al arrancar por el chip T2 y el mecanismo de snapshots APFS. Esto significa que no puedes borrar los kexts de AMD.

La unica solucion viable por software es **interceptar la GPU a nivel de bootloader** antes de que macOS la vea.

---

## Linea de tiempo

### 29 de enero, 2026 — Primera sesion de Claude Code
- El watchdog de Claude Code se lanzo por primera vez a las 15:24
- Comenzo el diagnostico inicial
- El sistema se caia repetidamente por kernel panics de la GPU AMD

### 29 de enero - 6 de febrero, 2026 — Arreglos NVRAM y hardening de software
- Se configuro `gpuswitch=0` para forzar graficos integrados a nivel firmware
- Se configuraron las variables NVRAM `gpu-policy` y `gpu-power-prefs`
- Se deshabilitaron hibernacion, standby, power nap (para evitar que la GPU se despierte)
- Se eliminaron kexts de terceros peligrosos: Paragon NTFS, HighPoint RAID, SoftRAID
- Se deshabilitaron launch agents: AnyTrans, Steam, LastPass
- Se configuro T2 Secure Boot en "No Security" (requerido para OpenCore)
- Estos arreglos redujeron la frecuencia de crashes pero no los eliminaron — los drivers AMD seguian cargandose

### 6 de febrero, 2026 — Intento con OpenCore v1
- Se construyo un paquete OpenCore con Lilu + WhateverGreen
- boot-args: `-wegnoegpu` solamente
- **Resultado: PANTALLA NEGRA** — el sistema arranco pero la pantalla quedo apagada
- Se identifico la causa raiz (ver Intento 1 abajo)

### 12 de febrero, 2026 — Intento con OpenCore v2
- Se reconstruyo el paquete con boot-args corregidos
- **El script de instalacion fallo** — HfsPlus.efi faltaba del directorio Drivers
- Aun si se hubiera instalado, el config.plist tenia 7 bugs criticos (ver Intento 3 abajo)
- Crash del watchdog de WindowServer a las 15:28 durante la depuracion

### 12 de febrero, 2026, ~16:43 — Se logra un arranque estable
- Con la config anterior de OpenCore (de una instalacion parcialmente exitosa), el sistema arranco y se mantuvo estable
- Se confirmaron 15+ horas de uptime

### 13 de febrero, 2026 — OpenCore v3 instalado desde Recovery Mode
- El usuario arranco en Recovery Mode (Cmd+R)
- Ejecuto el script INSTALL.sh corregido
- El script monto la particion EFI, copio los archivos correctos de OpenCore
- Reinicio, selecciono "Macintosh HD" en el picker de OpenCore
- **El sistema arranco exitosamente solo con Intel UHD 630**
- Se confirmo que Lilu 1.7.1 + WhateverGreen 1.7.0 estaban cargados
- Sin kernel panics, sin GPU AMD visible para macOS

---

## Que se intento y por que fallo cada cosa

### Intento 0: Eliminar kexts de AMD de /System — IMPOSIBLE

**Que se intento:** Borrar las extensiones de kernel de la GPU AMD de `/System/Library/Extensions/AMD*.kext`

**Por que fallo:** macOS 13 Ventura usa un Signed System Volume (SSV). La particion del sistema esta montada como un snapshot APFS criptograficamente sellado. Cualquier modificacion a `/System` romperia el sello, y el chip T2 se negaria a arrancar desde ese snapshot. No es un problema de permisos — es una restriccion arquitectural fundamental de macOS moderno. Ni con SIP deshabilitado y acceso root se pueden escribir en `/System`.

**Leccion:** En macOS 11 Big Sur y posteriores, no se pueden modificar archivos del sistema. Punto. Las soluciones deben funcionar *alrededor* del volumen sellado, no a traves de el.

### Intento 1: Deshabilitar GPU solo con NVRAM — INSUFICIENTE

**Que se intento:** Configurar variables NVRAM para decirle a macOS que prefiera la GPU integrada:
```
nvram FA4CE28D-B62F-4C99-9CC3-6815686E30F9:gpu-power-prefs=%01%00%00%00
nvram gpu-policy=%01
nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch=0
```
Mas cambios en gestion de energia:
```
sudo pmset -a hibernatemode 0
sudo pmset -a standby 0
sudo pmset -a powernap 0
```

**Por que fue insuficiente:** Estas variables NVRAM le dicen a macOS que *prefiera* los graficos integrados, pero macOS aun asi carga las extensiones de kernel de AMD en memoria. El hardware de GPU defectuoso puede ser sondeado por el driver, y cualquier interaccion del driver con una GPU fallando puede provocar un kernel panic. El `gpuswitch=0` previene el cambio *intencional* a la dGPU, pero no previene que el driver AMD se inicialice.

**Leccion:** Las preferencias NVRAM son una sugerencia para macOS, no un bloqueo duro. Los drivers de AMD seguiran cargandose y pueden seguir causando crashes. Se necesita un mecanismo que impida que los drivers se conecten al hardware GPU por completo.

### Intento 2: gpuswitch=2 (automatico) — NO ES SUFICIENTE

**Que se intento:** Configurar `gpuswitch=2` que deja que macOS elija automaticamente entre iGPU y dGPU.

**Por que fallo:** Con `gpuswitch=2`, macOS activa la GPU AMD cada vez que un proceso requiere mayor rendimiento grafico (renderizado Metal, pantalla externa, algunas apps). Como el hardware de la GPU esta fallando, cualquier activacion = crash.

**Leccion:** Hay que usar `gpuswitch=0` (forzar integrada), nunca `gpuswitch=2` (automatico).

### Intento 3: OpenCore v1 — PANTALLA NEGRA

**Que se intento:** Instalar el bootloader OpenCore 1.0.6 en la particion EFI con:
- Lilu 1.7.1 (framework parchador de extensiones de kernel)
- WhateverGreen 1.7.0 (parches especificos de GPU)
- boot-args: `-wegnoegpu` (le dice a WhateverGreen que deshabilite la GPU dedicada)

**Por que fallo:** El sistema arranco bien (se escuchaba el sonido de inicio y SSH era accesible) pero la **pantalla quedo completamente negra**. Faltaban dos argumentos de arranque criticos:

1. **`agdpmod=pikera`** — El driver Apple Graphics Device Policy (AGDP) hace una verificacion de board-id. En MacBook Pros con dos GPUs, AGDP espera que la GPU dedicada maneje ciertas salidas de video. Cuando deshabilitas la dGPU con `-wegnoegpu`, AGDP ve que la GPU esperada no esta y **se niega a dejar que la Intel iGPU maneje la pantalla interna**. El flag `agdpmod=pikera` parchea AGDP para saltarse esta verificacion de board-id, permitiendo que la iGPU envie imagen al panel Retina.

2. **`-igfxblr`** — Los procesadores Intel Coffee Lake (8va gen) tienen un bug en el driver de graficos integrados donde el **registro de retroiluminacion nunca se inicializa correctamente** durante el arranque temprano. En un MacBook Pro Retina, esto significa que la retroiluminacion del LCD queda a cero de brillo aunque el framebuffer esta renderizando correctamente. El flag `-igfxblr` (Intel Graphics Fix Backlight Register) le dice a WhateverGreen que parchee la secuencia de inicializacion de retroiluminacion para que la pantalla realmente se ilumine.

**Leccion:** Deshabilitar la dGPU con `-wegnoegpu` solo no es suficiente en un MacBook Pro. Tambien se necesita `agdpmod=pikera` (para bypasear la politica de pantalla de Apple que bloquea la iGPU) y `-igfxblr` (para arreglar el bug de registro de retroiluminacion de Coffee Lake). Los tres flags son obligatorios.

### Intento 4: Script de instalacion de OpenCore v2 — SCRIPT ABORTADO

**Que se intento:** Crear un paquete OpenCore mejorado (v2) con boot-args corregidos y un script de instalacion automatizado. Se ejecuto el script desde el terminal de Recovery Mode.

**Por que fallo:** El script validaba todos los archivos requeridos antes de copiarlos a la particion EFI. Encontro que `EFI/OC/Drivers/HfsPlus.efi` faltaba y aborto con:
```
MISSING: EFI/OC/Drivers/HfsPlus.efi — Cannot proceed
```

El script de construccion que ensamblo el paquete habia descargado HfsPlus.efi (37KB) en un directorio de staging `downloads/` pero **nunca lo copio a su ubicacion final** en `EFI/OC/Drivers/`. Este es un error clasico de pipeline de build — el paso de descarga funciono pero el paso de copia/ensamblado tenia un bug.

**Leccion:** Siempre verificar el paquete final ensamblado, no solo la cache de descargas. El script de instalacion v3 fue mejorado para auto-reparar esto copiando HfsPlus.efi desde `downloads/` si falta en `Drivers/`.

### Intento 5: config.plist de OpenCore v2 — 7 BUGS CRITICOS

Aun si el script de instalacion hubiera funcionado, el config.plist tenia siete problemas separados que habrian impedido un arranque exitoso. La causa raiz fue que el config.plist apenas habia sido modificado del template `SampleCustom.plist` de OpenCore — un template disenado para **builds hackintosh** (correr macOS en hardware que no es Apple), no para Macs reales.

| # | Setting | Valor incorrecto | Valor correcto | Por que importa |
|---|---------|-----------------|----------------|-----------------|
| 1 | `Vault` | `Secure` | `Optional` | El modo Vault Seguro de OpenCore requiere archivos hash criptograficos (`vault.plist`, `vault.sig`). No los tenemos. Con `Secure`, OpenCore se niega a cargar. |
| 2 | `SecureBootModel` | `Default` | `Disabled` | El chip T2 esta en "No Security" (requerido para OpenCore). `Default` le dice a OpenCore que fuerce Apple Secure Boot, lo cual entra en conflicto con la config del T2 y causa fallo de arranque. |
| 3 | `ScanPolicy` | `17760515` | `0` | Esta mascara de bits restringe que sistemas de archivos y tipos de dispositivos OpenCore escaneara. El valor `17760515` es muy restrictivo y puede no encontrar el volumen de arranque macOS APFS. `0` significa "escanear todo". |
| 4 | `VirtualSMC.kext` | `Enabled` | `Disabled` | VirtualSMC emula el chip SMC de Apple para builds hackintosh. Esta es una **Mac real** — tiene un SMC real. Habilitar VirtualSMC sin el archivo kext en el paquete causa un error de OpenCore. |
| 5 | `AppleALC.kext` | `Enabled` | `Disabled` | AppleALC parchea codecs de audio para hackintosh. El audio de Mac real funciona nativamente. El archivo kext ni siquiera estaba en el paquete, asi que OpenCore daria error al intentar cargarlo. |
| 6 | `UpdateSMBIOS` | `true` (iMac19,1) | `false` | El spoofing de SMBIOS hace que la maquina se reporte como iMac19,1 en vez de MacBookPro15,1. En una Mac real, esto sobreescribe el numero de serie real y rompe iCloud, Find My Mac, iMessage y el estado de garantia. |
| 7 | `boot-args` | `-v keepsyms=1` | `-v -wegnoegpu agdpmod=pikera -igfxblr` | Los boot-args eran los valores por defecto de SampleCustom.plist. Los tres flags criticos para GPU faltaban. El sistema arrancaria con la GPU AMD activa, crash inmediato. |

**Leccion:** Las configs de ejemplo de OpenCore son templates hackintosh. En una Mac real, la mayoria de las configuraciones especificas de hackintosh deben deshabilitarse. Cada campo en config.plist debe revisarse contra el hardware real. Usar un template a ciegas es peligroso.

### Intento 6: Montar EFI desde macOS en ejecucion — FALLA

**Que se intento:** `diskutil mount disk0s1` desde un arranque normal de macOS para acceder a la particion EFI (sistema de archivos FAT32/MSDOS).

**Por que fallo:** En macOS 13 Ventura con seguridad de arranque estandar, el driver de sistema de archivos `msdos.kext` no se carga durante el arranque normal. El comando `diskutil mount` falla silenciosamente o con error. Esto significa que **no puedes acceder a la particion EFI desde una sesion macOS en ejecucion** en esta maquina.

**Leccion:** La particion EFI solo puede montarse desde **Recovery Mode** (Cmd+R al arrancar), donde las restricciones de seguridad estan relajadas y todos los drivers de sistema de archivos estan disponibles. Cualquier instalacion o modificacion de OpenCore debe hacerse desde Recovery Mode.

---

## Acciones destructivas que deben evitarse

### NUNCA resetear NVRAM (Cmd+Option+P+R al arrancar)
Resetear NVRAM borra `boot-args`, `gpu-policy`, `gpu-power-prefs` y `gpuswitch`. El sistema arrancaria con la GPU AMD activa y se caia inmediatamente. Toda la configuracion NVRAM que mantiene esta maquina estable se perderia.

### NUNCA resetear SMC (a menos que sea absolutamente necesario)
El reset de SMC puede cambiar `gpuswitch` a su valor por defecto (2 = automatico), lo cual permite que macOS active la GPU AMD defectuosa. Solo resetear SMC si la maquina esta completamente sin respuesta y no hay otra opcion.

### NUNCA actualizar macOS sin probar antes
Una actualizacion de macOS podria cambiar el volumen sellado del sistema, modificar el comportamiento del driver de GPU, o resetear variables NVRAM. Antes de actualizar, verificar que la nueva version es compatible con la version instalada de OpenCore y WhateverGreen.

---

## La solucion que funciona — OpenCore v3

### Arquitectura

La solucion usa un enfoque multi-capa:

```
Capa 1: Firmware (NVRAM)
  gpuswitch=0           → Decirle al firmware que prefiera GPU integrada
  gpu-policy=%01        → Hint de politica para seleccion de GPU
  gpu-power-prefs       → Preferencia de gestion de energia para iGPU

Capa 2: Bootloader (OpenCore)
  boot-args: -wegnoegpu → Decirle a WhateverGreen que deshabilite dGPU a nivel driver
  boot-args: agdpmod=pikera → Bypasear la verificacion de politica de display de Apple
  boot-args: -igfxblr   → Arreglar bug de registro de retroiluminacion Coffee Lake
  boot-args: -v         → Arranque verbose (para depuracion)

Capa 3: Extensiones de kernel (cargadas por OpenCore)
  Lilu 1.7.1            → Framework parchador de kernel/kexts
  WhateverGreen 1.7.0   → Parches especificos de GPU (lee flag -wegnoegpu)

Capa 4: Gestion de energia de macOS
  hibernatemode 0       → Deshabilitar hibernacion (evita despertar GPU)
  standby 0             → Deshabilitar standby (evita despertar GPU)
  powernap 0            → Deshabilitar power nap (evita despertar GPU)
```

### Como funciona

1. **Al encender**, el firmware de la Mac lee `gpuswitch=0` de NVRAM e inicializa solo la Intel UHD 630 para el display pre-arranque.

2. **OpenCore carga desde la particion EFI** (disk0s1). Lee `config.plist` e inyecta `boot-args` en el proceso de arranque de macOS. Tambien carga `Lilu.kext` y `WhateverGreen.kext` en la cache de extensiones de kernel.

3. **Durante la inicializacion del kernel de macOS**, Lilu parchea el kernel para permitir que WhateverGreen se enganche en la inicializacion del driver de GPU. WhateverGreen lee el argumento de arranque `-wegnoegpu` e **impide que el driver de la AMD Radeon Pro 560X se conecte al hardware**. La GPU es efectivamente invisible para macOS.

4. **`agdpmod=pikera`** parchea el driver AGDP de Apple para que no rechace la Intel iGPU como salida de pantalla. Sin esto, AGDP veria que la dGPU "esperada" falta y se negaria a dejar que la iGPU maneje el panel interno.

5. **`-igfxblr`** parchea el driver de graficos Intel para inicializar correctamente el registro de retroiluminacion en Coffee Lake. Sin esto, la retroiluminacion del LCD queda apagada.

6. **macOS arranca normalmente** solo con la Intel UHD 630 activa. La pantalla Retina funciona a 2880x1800. Todas las funciones de macOS (iCloud, Find My, etc.) funcionan porque SMBIOS no esta spoofeado.

### Configuracion clave del config.plist

```
Misc > Security > Vault: Optional
Misc > Security > SecureBootModel: Disabled
Misc > Security > ScanPolicy: 0
Misc > Security > BlacklistAppleUpdate: true   ← previene actualizaciones OTA que podrian romper OpenCore
Misc > Boot > ShowPicker: true
Misc > Boot > Timeout: 10

Kernel > Add > Lilu.kext: Enabled              ← DEBE ser primero en el array (carga antes que WhateverGreen)
Kernel > Add > WhateverGreen.kext: Enabled     ← DEBE ir despues de Lilu (depende del API de parcheo de Lilu)
Kernel > Add > VirtualSMC.kext: Disabled
Kernel > Add > AppleALC.kext: Disabled
Kernel > Quirks > DisableLinkeditJettison: true ← requerido para que Lilu funcione en macOS 12+

NVRAM > Add > 7C436110 > boot-args: -v -wegnoegpu agdpmod=pikera -igfxblr
NVRAM > Add > 7C436110 > csr-active-config: 00000000 (SIP habilitado)
NVRAM > Add > 4D1EDE21 > gpuswitch: MA== (base64 de ASCII "0" = forzar integrada)
NVRAM > Add > FA4CE28D > gpu-power-prefs: AQAAAA== (base64 de bytes 01 00 00 00)

PlatformInfo > UpdateSMBIOS: false
PlatformInfo > UpdateDataHub: false
PlatformInfo > UpdateNVRAM: false

UEFI > Drivers > OpenRuntime.efi: Enabled
UEFI > Drivers > HfsPlus.efi: Enabled
```

**Detalles importantes de la config que no son obvios:**
- **Lilu debe cargarse antes que WhateverGreen** en el array `Kernel > Add`. WhateverGreen es un plugin de Lilu — llama al API de Lilu para parchear drivers de GPU. Si WhateverGreen carga primero, no tiene nada a que engancharse y `-wegnoegpu` falla silenciosamente.
- **`DisableLinkeditJettison: true`** previene que macOS descarte el segmento `__LINKEDIT` de la memoria del kernel. Lilu necesita este segmento para hacer parcheo en tiempo de ejecucion. Sin esto, Lilu falla al cargar en macOS 12 Monterey y posteriores.
- **`BlacklistAppleUpdate: true`** previene que actualizaciones de firmware Apple se ofrezcan a traves de Actualizacion de Software. Una actualizacion accidental de firmware podria cambiar el comportamiento de arranque y romper la cadena de OpenCore.
- **`gpu-power-prefs` debe estar correctamente codificado en base64.** El config.plist original de v3 contenia `QVFBQUFBPT0=` que decodifica al string ASCII "AQAAAA==" — un error de doble codificacion base64. El valor correcto es `AQAAAA==` que decodifica a los bytes crudos `01 00 00 00`. Este bug fue inofensivo en la practica porque el valor correcto ya estaba en NVRAM via `sudo nvram`, pero se corrigio en el config.plist final para prevenir problemas en instalaciones nuevas.
- **Auto-reparacion de NVRAM:** La seccion `NVRAM > Delete` del config.plist borra `boot-args`, `gpuswitch` y `gpu-power-prefs` en cada arranque por OpenCore, y luego `NVRAM > Add` escribe los valores correctos de vuelta. Esto asegura que el fix de GPU sobrevive resets de NVRAM, actualizaciones de macOS y cambios accidentales. La variable `gpuswitch` (GUID `4D1EDE21`) fue anadida a la config de NVRAM durante la auditoria final — antes solo se configuraba manualmente via `sudo nvram` y podria haberse perdido durante una actualizacion.

### Estructura de la particion EFI

```
/Volumes/EFI/
  EFI/
    BOOT/
      BOOTx64.efi          ← Cargador bootstrap de OpenCore
    OC/
      OpenCore.efi          ← Binario principal de OpenCore
      config.plist          ← Configuracion (todos los settings de arriba)
      Drivers/
        OpenRuntime.efi     ← Servicios runtime UEFI
        HfsPlus.efi         ← Driver de sistema de archivos HFS+
      Kexts/
        Lilu.kext/          ← Parchador de kernel (1.7.1)
        WhateverGreen.kext/ ← Parchador de GPU (1.7.0)
```

### Versiones de software

| Componente | Version | Proposito |
|------------|---------|-----------|
| OpenCore | 1.0.6 | Bootloader UEFI |
| Lilu | 1.7.1 | Framework parchador de extensiones de kernel |
| WhateverGreen | 1.7.0 | Parches de kernel especificos de GPU |
| HfsPlus.efi | Propietario Apple | Driver HFS+ para OpenCore |
| OpenRuntime.efi | 1.0.6 (incluido) | Servicios runtime UEFI para OpenCore |

---

## El script de instalacion

El script de instalacion v3 (`INSTALL.sh`) fue disenado para ejecutarse desde el terminal de Recovery Mode. Realiza siete pasos:

1. **Localizar el paquete OpenCore** — Busca en multiples posibles rutas de montaje de volumenes (`/Volumes/Macintosh HD - Data/...`, `/Volumes/Data/...`, etc.) porque Recovery Mode no siempre monta los volumenes en la misma ruta.

2. **Auto-reparar archivos faltantes** — Si `HfsPlus.efi` falta de `EFI/OC/Drivers/`, lo copia desde `downloads/HfsPlus.efi` o usa como respaldo `downloads/OpenCore/X64/EFI/OC/Drivers/OpenHfsPlus.efi`.

3. **Validar todos los archivos requeridos** — Verifica que cada archivo critico existe y no esta vacio: `BOOTx64.efi`, `OpenCore.efi`, `config.plist`, `OpenRuntime.efi`, `HfsPlus.efi`, `Lilu.kext`, `WhateverGreen.kext`.

4. **Encontrar la particion EFI** — Prueba `disk0s1`, `disk1s1`, `disk2s1`, luego `diskutil list` grep por "EFI".

5. **Montar la particion EFI** — Prueba `diskutil mount`, luego `mount -t msdos`, luego `mount_msdos`. Verifica que el montaje es escribible.

6. **Instalar OpenCore** — Elimina los directorios antiguos `EFI/OC` y `EFI/BOOT`, copia los nuevos. Preserva `EFI/APPLE` si existe.

7. **Verificar la instalacion** — Confirma que todos los archivos se copiaron correctamente a la particion EFI.

### Instalacion manual de respaldo

Si el script falla por cualquier razon, los comandos manuales desde el terminal de Recovery Mode son:
```bash
diskutil mount disk0s1
mkdir -p /Volumes/EFI/EFI
cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/BOOT" /Volumes/EFI/EFI/
cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/OC" /Volumes/EFI/EFI/
```

---

## El watchdog de Claude Code

Se creo un agente launchd (`com.claude.watchdog.plist`) para asegurar que Claude Code se iniciara automaticamente despues de cada reinicio para continuar el proceso de reparacion. Esto fue necesario porque la maquina se caia repetidamente y el usuario necesitaba un agente de reparacion autonomo.

### Como funciona

- **plist de launchd** en `~/Library/LaunchAgents/com.claude.watchdog.plist`:
  - `RunAtLoad: true` — se inicia inmediatamente al login
  - `KeepAlive: true` — reinicia si el script watchdog termina
  - `StartInterval: 60` — launchd reinicia el script en 60 segundos si termina

- **Script watchdog** en `~/claude_watchdog.sh`:
  - Usa un archivo lock (`/tmp/claude_watchdog.lock`) para prevenir multiples instancias
  - El loop interno verifica cada 90 segundos si Claude Code esta corriendo via `ps aux | grep claude`
  - Si Claude Code no esta corriendo, abre Terminal.app via AppleScript y inicia Claude Code con el archivo de mision
  - Registra toda la actividad en `~/claude_watchdog.log`

### Linea de tiempo del log del watchdog

| Fecha | Evento |
|-------|--------|
| Ene 29, 15:24 | Primer inicio del watchdog, diagnostico inicial |
| Ene 29, 16:31 | Reinicio (probable crash), watchdog reinicia Claude |
| Feb 6, 17:19 | Sistema reiniciado despues de 8 dias, watchdog reinicia Claude |
| Feb 12, 14:27 | Reinicio, comienza sesion intensiva de depuracion |
| Feb 12, 15:28 | Ultima entrada en log antes de crash (timeout del watchdog de WindowServer) |
| Feb 13, 08:42 | Arranque final — v3 instalado desde Recovery Mode, sistema estable |

---

## Otros arreglos de software aplicados

### Extensiones de kernel de terceros eliminadas
Estos kexts se encontraron en `/Library/Extensions/` y eran contribuyentes potenciales de crashes:
- **Paragon NTFS** (`com.paragon-software.filesystems.ntfs`) — Driver de sistema de archivos de terceros, conocido por causar kernel panics
- **HighPoint RAID** — Driver de controlador RAID, no necesario
- **SoftRAID** — Driver de RAID por software, no necesario

### Launch agents deshabilitados
Se renombraron de `.plist` a `.plist.disabled` para prevenir auto-inicio:
- **AnyTrans** — Utilidad de transferencia de archivos (proceso en background innecesario)
- **Steam** — Cliente de juegos (provocaria cambio de GPU)
- **LastPass** — Agente de gestor de contrasenas (carga innecesaria)

### Gestion de energia
```
hibernatemode 0    → Previene hibernacion (despertar GPU puede causar crash)
standby 0          → Previene deep sleep standby
powernap 0         → Previene Power Nap (despertaria GPU)
lowpowermode 0     → Deshabilitado modo bajo consumo
```

### Configuracion de seguridad
- **SIP (System Integrity Protection):** Habilitado (`csr-active-config = 0`)
- **T2 Secure Boot:** Configurado en "No Security" (requerido para OpenCore)
- **External Boot:** Permitido (requerido para OpenCore en particion EFI)

---

## Procedimientos de recuperacion de emergencia

### Si el sistema arranca con pantalla negra (>3 minutos)
1. Mantener el boton de encendido 10 segundos para forzar apagado
2. Encender mientras se mantiene presionada la tecla **Option/Alt**
3. Seleccionar "Macintosh HD" directamente (esto salta OpenCore)
4. El sistema arrancara sin OpenCore — la GPU AMD estara activa pero el sistema puede sobrevivir lo suficiente para diagnosticar

### Si necesitas eliminar OpenCore completamente
1. Reiniciar, mantener **Cmd+R** para Recovery Mode
2. Abrir Terminal desde el menu Utilidades
3. Ejecutar:
```bash
diskutil mount disk0s1
rm -rf /Volumes/EFI/EFI/OC /Volumes/EFI/EFI/BOOT
```
4. Reiniciar — el sistema arranca normalmente sin OpenCore

### Si OpenCore v3 deja de funcionar despues de una actualizacion de macOS
1. Arrancar con Option/Alt para bypasear OpenCore
2. Descargar versiones actualizadas de Lilu y WhateverGreen desde sus releases de GitHub
3. Reemplazar los kexts en `~/Desktop/OpenCore_GPU_Fix/EFI/OC/Kexts/`
4. Re-ejecutar la instalacion desde Recovery Mode

### Camino de escalacion (si WhateverGreen deja de bloquear AMD)
- **SSDT-dGPU-Off.aml** — Una tabla ACPI override que deshabilita la GPU dedicada a nivel firmware ACPI, antes de que cualquier driver del SO cargue. Mas agresivo que `-wegnoegpu`. Archivos fuente de ejemplo existen en `~/Desktop/OpenCore_GPU_Fix/downloads/OpenCore/Docs/AcpiSamples/`
- **DeviceProperties disable-gpu** — Agregar la ruta PCI de la GPU AMD a la seccion `DeviceProperties > Add` del config.plist con una propiedad `disable-gpu`

### Opciones nucleares (si lo anterior falla)
- **Apple Diagnostics** — Reiniciar y mantener **D** al arrancar. Si el test devuelve codigos VDH001 a VDH006, la GPU tiene un fallo de hardware confirmado. Util para reclamos de garantia o confirmar el diagnostico.
- **Reinstalar macOS desde Recovery** — Reiniciar con Cmd+R, seleccionar "Reinstalar macOS". Preserva datos del usuario pero resetea archivos del sistema. Util si el volumen sellado del sistema esta danado.
- **Display externo via USB-C/Thunderbolt** — Reduce la carga en la Intel iGPU descargando pixeles. Si WindowServer se cae porque la iGPU no puede con el panel Retina 2880x1800, un display externo a menor resolucion puede ayudar.

---

## Proceso de arranque (operacion normal)

1. Presionar boton de encendido
2. El chip T2 inicializa, el firmware carga
3. **Aparece el picker de OpenCore** (timeout de 10 segundos) — muestra "Macintosh HD"
4. Seleccionar "Macintosh HD" o esperar la auto-seleccion
5. **Aparece texto de arranque verbose** (texto blanco sobre fondo negro) — esto es normal, es el flag `-v`
6. La pantalla puede parpadear o ponerse negra brevemente — es el cambio de modo de display
7. **Esperar 2-3 minutos** — el arranque es mas lento con modo verbose
8. Aparece la pantalla de login
9. El sistema esta corriendo solo con Intel UHD 630

### Como verificar que el arreglo esta funcionando
```bash
# Deberia mostrar SOLO "Intel UHD Graphics 630"
system_profiler SPDisplaysDataType | grep "Chipset Model"

# Deberia mostrar Lilu y WhateverGreen
kextstat | grep -v com.apple

# Deberia mostrar uptime creciente sin reinicios inesperados
uptime
```

---

## Conceptos tecnicos clave

### Signed System Volume (SSV)
Introducido en macOS 11 Big Sur. La particion del sistema es un snapshot APFS inmutable y criptograficamente sellado. El chip T2 verifica el sello al arrancar. Cualquier modificacion a `/System` rompe el sello e impide el arranque. Por eso no puedes simplemente borrar los kexts de AMD.

### OpenCore
Un bootloader UEFI de codigo abierto. Originalmente disenado para hackintosh (correr macOS en hardware no-Apple), pero tambien util en Macs reales para inyectar extensiones de kernel y argumentos de arranque que macOS no soporta nativamente. OpenCore vive en la EFI System Partition (ESP), que es separada del volumen sellado del sistema.

### Lilu
Un framework parchador de extensiones de kernel. Se engancha al kernel de macOS temprano en el proceso de arranque y provee un API para que otros kexts (como WhateverGreen) parcheen codigo del kernel y otros kexts al vuelo, sin modificar archivos en disco.

### WhateverGreen
Un plugin de Lilu que parchea extensiones de kernel relacionadas con GPU. El flag `-wegnoegpu` le dice que prevenga que el driver de GPU dedicada se conecte al hardware. El flag `agdpmod=pikera` parchea la politica de display de Apple. El flag `-igfxblr` arregla la inicializacion del registro de retroiluminacion Intel.

### EFI System Partition (ESP)
Una particion FAT32 (tipicamente disk0s1) que contiene archivos del bootloader. En un Mac, el propio boot.efi de Apple vive aqui. OpenCore agrega su propio bootloader (BOOTx64.efi) que se ejecuta antes de que macOS cargue. Esta particion no es parte del volumen sellado del sistema, asi que puede modificarse libremente — pero solo desde Recovery Mode en macOS 13.

### Variables NVRAM (relacionadas con GPU)
- `gpuswitch` (GUID: 4D1EDE21) — `0` = solo integrada, `1` = solo dedicada, `2` = automatico
- `gpu-policy` — Preferencia binaria para seleccion de GPU
- `gpu-power-prefs` (GUID: FA4CE28D) — Preferencia de gestion de energia de GPU
- `boot-args` (GUID: 7C436110) — Argumentos de arranque del kernel pasados a macOS

---

## Ubicaciones de archivos

| Archivo | Proposito |
|---------|-----------|
| `~/CLAUDE_FIX_COMPUTER_MISSION.md` | Documento maestro de mision con estado e instrucciones |
| `~/Desktop/OpenCore_GPU_Fix/` | Paquete v3 (listo para reinstalar si es necesario) |
| `~/Desktop/OpenCore_GPU_Fix/INSTALL.sh` | Script de instalacion automatizado |
| `~/Desktop/OpenCore_GPU_Fix/LEEME.txt` | Instrucciones de instalacion en espanol |
| `~/Desktop/OpenCore_GPU_Fix/EFI/` | Estructura completa del directorio EFI |
| `~/Desktop/OpenCore_GPU_Fix/EFI/OC/config.plist` | Configuracion de OpenCore |
| `~/Desktop/OpenCore_GPU_Fix/downloads/` | Componentes originales descargados |
| `~/Library/LaunchAgents/com.claude.watchdog.plist` | Agente launchd del watchdog |
| `~/claude_watchdog.sh` | Script del watchdog |
| `~/claude_watchdog.log` | Log de actividad del watchdog |
| `~/.claude/projects/-Users-daftlog/memory/MEMORY.md` | Memoria persistente de Claude Code |

---

## Resumen

Una MacBook Pro 15,1 (2018) con una AMD Radeon Pro 560X defectuosa fue estabilizada mediante:

1. **OpenCore 1.0.6** bootloader en la particion EFI
2. **Lilu 1.7.1** + **WhateverGreen 1.7.0** kexts para bloquear el driver AMD
3. **boot-args:** `-v -wegnoegpu agdpmod=pikera -igfxblr`
4. **NVRAM:** `gpuswitch=0`, `gpu-policy=%01`, `gpu-power-prefs` configurado
5. **Gestion de energia:** hibernacion, standby y power nap deshabilitados
6. **Limpieza:** kexts de terceros peligrosos eliminados, launch agents innecesarios deshabilitados

Se necesitaron 3 iteraciones de la configuracion de OpenCore para que funcionara. Los principales obstaculos fueron:
- El volumen sellado del sistema de macOS 13 (impide borrar kexts)
- La particion EFI no montable desde macOS en ejecucion (requiere Recovery Mode)
- Los boot args `agdpmod=pikera` y `-igfxblr` faltantes (causan pantalla negra)
- Un bug del script de build que olvido copiar HfsPlus.efi
- Un config.plist que era un template hackintosh apenas modificado con 7 errores criticos

El sistema ahora esta estable y deberia mantenerse asi mientras no se resetee la NVRAM y las actualizaciones de macOS no rompan la compatibilidad con WhateverGreen.
