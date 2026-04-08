#!/bin/bash
# RESTAURAR + DESHABILITAR AMD al maximo
# Recovery > Terminal:
#   diskutil mount "Macintosh HD - Data"
#   bash "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/RESTORE.sh"

echo ""
echo "============================================"
echo "  RESTAURAR + DESHABILITAR AMD"
echo "============================================"
echo ""

# --- Paso 1: Encontrar volumen del sistema ---
echo "[1/5] Buscando volumen del sistema..."
SYS_DEV="/dev/disk3s4"
for d in $(diskutil apfs list 2>/dev/null | grep "APFS Volume Disk" | awk '{print $NF}'); do
    ROLE=$(diskutil info "$d" 2>/dev/null | grep "Volume Role" | sed 's/.*: *//')
    NAME=$(diskutil info "$d" 2>/dev/null | grep "Volume Name" | sed 's/.*: *//')
    if echo "$ROLE" | grep -qi "system"; then
        SYS_DEV="/dev/$d"
        echo "  Encontrado: $SYS_DEV ($NAME)"
        break
    fi
done
if [ -z "$SYS_DEV" ]; then
    echo "  ERROR: No encontre volumen del sistema."
    echo "  Ejecuta: diskutil apfs list"
    exit 1
fi

# --- Paso 2: Montar y restaurar AMD kexts ---
echo ""
echo "[2/5] Montando volumen y restaurando AMD kexts..."

MNT="/Volumes/mnt1"
mkdir -p "$MNT"
umount "/Volumes/Macintosh HD" 2>/dev/null || true
#/sbin/mount_apfs -o nobrowse "$SYS_DEV" "$MNT"
MOUNTED=1
/sbin/mount_apfs -o nobrowse "$SYS_DEV" "$MNT" 2>/dev/null && MOUNTED=1
if [ "$MOUNTED" = "0" ]; then
    mount -o nobrowse -t apfs "$SYS_DEV" "$MNT" 2>/dev/null && MOUNTED=1
fi

if [ "$MOUNTED" = "0" ]; then
    echo "  No se pudo montar. Intenta:"
    echo "    csrutil disable"
    echo "    csrutil authenticated-root disable"
    echo "    reboot"
    echo "  Luego vuelve a Recovery y ejecuta este script de nuevo."
    exit 1
fi
echo "  Montado en $MNT"

# Restaurar kexts desde backup si existen
if [ -d "$MNT/AMD_Kext_Backup" ] && [ "$(ls -A "$MNT/AMD_Kext_Backup/" 2>/dev/null)" ]; then
    echo "  Restaurando AMD kexts desde backup..."
    for K in "$MNT/AMD_Kext_Backup/"*.kext; do
        [ -d "$K" ] || continue
        KNAME=$(basename "$K")
        [ ! -d "$MNT/System/Library/Extensions/$KNAME" ] && mv "$K" "$MNT/System/Library/Extensions/$KNAME" && echo "    Restaurado: $KNAME"
    done
    rmdir "$MNT/AMD_Kext_Backup" 2>/dev/null || true
else
    echo "  No hay backup (kexts ya en su lugar o snapshot los restaura)"
fi

# --- Paso 3: Restaurar snapshot ---
echo ""
echo "[3/5] Restaurando snapshot booteable..."

if bless --mount "$MNT" --last-sealed-snapshot 2>/dev/null; then
    echo "  EXITO: Snapshot sellado original restaurado!"
elif bless --folder "$MNT/System/Library/CoreServices" --bootefi --create-snapshot 2>/dev/null; then
    echo "  Nuevo snapshot creado."
elif bless --folder "$MNT/System/Library/CoreServices" --bootefi 2>/dev/null; then
    echo "  bless aplicado (sin snapshot nuevo)."
else
    echo "  ADVERTENCIA: bless fallo. El sistema podria no arrancar."
    echo "  Si no arranca, usa: Reinstalar macOS desde Recovery."
fi

# --- Paso 4: NVRAM - forzar Intel, deshabilitar AMD al maximo ---
echo ""
echo "[4/5] Configurando NVRAM para deshabilitar AMD..."

# gpuswitch=0: fuerza GPU integrada (Intel)
nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch=%30 2>/dev/null || true
echo "  gpuswitch=0 (forzar Intel)"

# gpu-power-prefs: preferir integrada
nvram fa4ce28d-b62f-4c99-9cc3-6815686e30f9:gpu-power-prefs=%01%00%00%00 2>/dev/null || true
echo "  gpu-power-prefs=01000000 (preferir integrada)"

# boot-args: agc=-1 deshabilita el switching de GPUs de Apple
nvram 7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args="agc=-1" 2>/dev/null || true
echo "  boot-args=agc=-1 (deshabilitar GPU switching)"

# gpu-policy: preferir integrada
nvram gpu-policy=%01 2>/dev/null || true
echo "  gpu-policy=01 (preferir integrada)"

# --- Paso 5: LaunchDaemon para re-aplicar en cada boot ---
echo ""
echo "[5/5] Instalando LaunchDaemon para proteger config..."

# Montar Data volume si no esta montado
diskutil mount "Macintosh HD - Data" 2>/dev/null || true

# Buscar la ruta correcta al Data volume
DATA_PATH=""
for P in "/Volumes/Macintosh HD - Data" "/Volumes/Data"; do
    if [ -d "$P/Users" ]; then
        DATA_PATH="$P"
        break
    fi
done

if [ -n "$DATA_PATH" ]; then
    DAEMON_DIR="$DATA_PATH/private/var/db/com.apple.xpc.launchd/disabled.plist"
    PLIST_DIR="$DATA_PATH/Library/LaunchDaemons"
    mkdir -p "$PLIST_DIR" 2>/dev/null

    cat > "$PLIST_DIR/com.local.disable-amd-gpu.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.disable-amd-gpu</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>pmset -a gpuswitch 0; nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch=%30; nvram fa4ce28d-b62f-4c99-9cc3-6815686e30f9:gpu-power-prefs=%01%00%00%00</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLISTEOF
    chmod 644 "$PLIST_DIR/com.local.disable-amd-gpu.plist"
    chown 0:0 "$PLIST_DIR/com.local.disable-amd-gpu.plist" 2>/dev/null || true
    echo "  LaunchDaemon instalado: re-aplica gpuswitch=0 en cada boot"
else
    echo "  No se encontro Data volume para LaunchDaemon"
    echo "  (puedes crearlo manualmente despues desde macOS)"
fi

# SIP queda deshabilitado
echo ""
echo "  SIP: queda DESHABILITADO"
csrutil disable 2>/dev/null || true
csrutil authenticated-root disable 2>/dev/null || true

echo ""
echo "============================================"
echo "  COMPLETADO"
echo "============================================"
echo ""
echo "  Escribe: reboot"
echo ""
echo "  Que se hizo:"
echo "    - AMD kexts restaurados (necesarios para power management)"
echo "    - Snapshot booteable restaurado/creado"
echo "    - NVRAM: gpuswitch=0, gpu-power-prefs, agc=-1"
echo "    - LaunchDaemon: re-aplica config en cada boot"
echo "    - SIP deshabilitado para futuras intervenciones"
echo ""
echo "  La AMD queda con drivers cargados (para que no se"
echo "  sobrecaliente) pero NUNCA se usa para display."
echo "  Intel UHD 630 maneja todo."
echo "============================================"
echo ""
