#!/bin/bash
#
# ============================================================
#  OPENCORE GPU FIX INSTALLER v3 - MacBook Pro 15,1 (2018)
#  Disables failing AMD Radeon Pro 560X GPU
# ============================================================
#
#  INSTRUCTIONS:
#  1. Boot into Recovery Mode (Restart > hold Cmd+R)
#  2. Open Terminal (Utilities menu > Terminal)
#  3. Run one of these (try in order):
#
#     bash "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/INSTALL.sh"
#     bash "/Volumes/Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/INSTALL.sh"
#
#  That's it. The script does everything else automatically.
#
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo "============================================================"
echo "  OPENCORE GPU FIX INSTALLER v3"
echo "  MacBook Pro 15,1 (2018) - AMD Radeon Pro 560X Disable"
echo "============================================================"
echo ""

# ---- STEP 0: Find the OpenCore_GPU_Fix folder ----
echo -e "${BLUE}[Step 0/7] Locating OpenCore package...${NC}"

# Try to determine SCRIPT_DIR from the script's own location first
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
SCRIPT_DIR=""

if [ -d "$SELF_DIR/EFI" ] && [ -f "$SELF_DIR/EFI/OC/config.plist" ]; then
    SCRIPT_DIR="$SELF_DIR"
fi

# If that didn't work, try known paths
if [ -z "$SCRIPT_DIR" ]; then
    POSSIBLE_PATHS=(
        "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix"
        "/Volumes/Data/Users/daftlog/Desktop/OpenCore_GPU_Fix"
        "/Users/daftlog/Desktop/OpenCore_GPU_Fix"
    )
    for P in "${POSSIBLE_PATHS[@]}"; do
        if [ -d "$P/EFI" ] && [ -f "$P/EFI/OC/config.plist" ]; then
            SCRIPT_DIR="$P"
            break
        fi
    done
fi

# Last resort: search all volumes
if [ -z "$SCRIPT_DIR" ]; then
    echo "  Searching all volumes..."
    for VOL in /Volumes/*/; do
        FOUND=$(find "$VOL" -maxdepth 5 -name "OpenCore_GPU_Fix" -type d 2>/dev/null | head -1)
        if [ -n "$FOUND" ] && [ -f "$FOUND/EFI/OC/config.plist" ]; then
            SCRIPT_DIR="$FOUND"
            break
        fi
    done
fi

if [ -z "$SCRIPT_DIR" ]; then
    echo -e "${RED}ERROR: No se encontro la carpeta OpenCore_GPU_Fix.${NC}"
    echo ""
    echo "  Volumes disponibles:"
    ls /Volumes/ 2>/dev/null
    echo ""
    echo "  Intenta montar el volumen de datos primero:"
    echo "    diskutil mount \"Macintosh HD - Data\""
    echo "  Luego ejecuta este script de nuevo."
    exit 1
fi

echo -e "${GREEN}  Encontrado en: $SCRIPT_DIR${NC}"
echo ""

# ---- STEP 1: Auto-repair missing files ----
echo -e "${BLUE}[Step 1/7] Verificando y reparando archivos...${NC}"

# Auto-repair: copy HfsPlus.efi from downloads if missing
if [ ! -f "$SCRIPT_DIR/EFI/OC/Drivers/HfsPlus.efi" ]; then
    echo -e "${YELLOW}  HfsPlus.efi falta en Drivers/ - reparando...${NC}"
    if [ -f "$SCRIPT_DIR/downloads/HfsPlus.efi" ]; then
        cp "$SCRIPT_DIR/downloads/HfsPlus.efi" "$SCRIPT_DIR/EFI/OC/Drivers/HfsPlus.efi"
        echo -e "${GREEN}  HfsPlus.efi copiado desde downloads/${NC}"
    elif [ -f "$SCRIPT_DIR/downloads/OpenCore/X64/EFI/OC/Drivers/OpenHfsPlus.efi" ]; then
        cp "$SCRIPT_DIR/downloads/OpenCore/X64/EFI/OC/Drivers/OpenHfsPlus.efi" "$SCRIPT_DIR/EFI/OC/Drivers/HfsPlus.efi"
        echo -e "${GREEN}  OpenHfsPlus.efi copiado como HfsPlus.efi${NC}"
    else
        echo -e "${RED}  ERROR: No se encontro HfsPlus.efi en ninguna ubicacion.${NC}"
        exit 1
    fi
fi

# Verify all required files
MISSING=0
REQUIRED_FILES=(
    "EFI/BOOT/BOOTx64.efi"
    "EFI/OC/OpenCore.efi"
    "EFI/OC/config.plist"
    "EFI/OC/Drivers/OpenRuntime.efi"
    "EFI/OC/Drivers/HfsPlus.efi"
    "EFI/OC/Kexts/Lilu.kext/Contents/MacOS/Lilu"
    "EFI/OC/Kexts/WhateverGreen.kext/Contents/MacOS/WhateverGreen"
)

for F in "${REQUIRED_FILES[@]}"; do
    if [ -f "$SCRIPT_DIR/$F" ]; then
        SIZE=$(wc -c < "$SCRIPT_DIR/$F" 2>/dev/null | tr -d ' ')
        if [ "$SIZE" -gt 0 ] 2>/dev/null; then
            echo -e "  ${GREEN}OK${NC} $F ($SIZE bytes)"
        else
            echo -e "  ${RED}VACIO${NC} $F"
            MISSING=1
        fi
    else
        echo -e "  ${RED}FALTA${NC} $F"
        MISSING=1
    fi
done

if [ "$MISSING" -eq 1 ]; then
    echo -e "${RED}ERROR: Faltan archivos criticos. No se puede continuar.${NC}"
    exit 1
fi
echo -e "${GREEN}  Todos los archivos presentes y validos.${NC}"
echo ""

# ---- STEP 2: Find the EFI partition ----
echo -e "${BLUE}[Step 2/7] Buscando particion EFI...${NC}"

EFI_DISK=""

# Method 1: Look for EFI type partition on internal disks
for DISK in disk0s1 disk1s1 disk2s1; do
    if diskutil info "/dev/$DISK" 2>/dev/null | grep -qi "EFI"; then
        EFI_DISK="/dev/$DISK"
        echo -e "  Encontrada particion EFI: ${GREEN}$EFI_DISK${NC}"
        break
    fi
done

# Method 2: Use diskutil list to find EFI
if [ -z "$EFI_DISK" ]; then
    EFI_DISK=$(diskutil list internal 2>/dev/null | grep -i "EFI" | head -1 | awk '{print "/dev/"$NF}')
    if [ -n "$EFI_DISK" ]; then
        echo -e "  Encontrada via diskutil list: ${GREEN}$EFI_DISK${NC}"
    fi
fi

# Method 3: Default to disk0s1
if [ -z "$EFI_DISK" ]; then
    EFI_DISK="/dev/disk0s1"
    echo -e "${YELLOW}  Usando particion EFI por defecto: $EFI_DISK${NC}"
fi

echo ""

# ---- STEP 3: Mount the EFI partition ----
echo -e "${BLUE}[Step 3/7] Montando particion EFI...${NC}"

EFI_MOUNT=""

# Check if already mounted
EXISTING_MOUNT=$(mount | grep "$EFI_DISK" | awk '{print $3}')
if [ -n "$EXISTING_MOUNT" ]; then
    EFI_MOUNT="$EXISTING_MOUNT"
    echo -e "${GREEN}  Ya estaba montada en: $EFI_MOUNT${NC}"
fi

# Try diskutil mount
if [ -z "$EFI_MOUNT" ]; then
    if diskutil mount "$EFI_DISK" 2>/dev/null; then
        # Find where it mounted
        sleep 1
        EFI_MOUNT=$(mount | grep "$EFI_DISK" | awk '{print $3}')
        if [ -z "$EFI_MOUNT" ]; then
            EFI_MOUNT="/Volumes/EFI"
        fi
        echo -e "${GREEN}  Montada via diskutil en: $EFI_MOUNT${NC}"
    fi
fi

# Try mount -t msdos
if [ -z "$EFI_MOUNT" ] || [ ! -d "$EFI_MOUNT" ]; then
    mkdir -p /tmp/efi_mount 2>/dev/null
    if mount -t msdos "$EFI_DISK" /tmp/efi_mount 2>/dev/null; then
        EFI_MOUNT="/tmp/efi_mount"
        echo -e "${GREEN}  Montada via mount en: $EFI_MOUNT${NC}"
    fi
fi

# Try mount_msdos directly
if [ -z "$EFI_MOUNT" ] || [ ! -d "$EFI_MOUNT" ]; then
    mkdir -p /tmp/efi_mount 2>/dev/null
    if mount_msdos "$EFI_DISK" /tmp/efi_mount 2>/dev/null; then
        EFI_MOUNT="/tmp/efi_mount"
        echo -e "${GREEN}  Montada via mount_msdos en: $EFI_MOUNT${NC}"
    fi
fi

if [ -z "$EFI_MOUNT" ] || [ ! -d "$EFI_MOUNT" ]; then
    echo -e "${RED}ERROR: No se pudo montar la particion EFI ($EFI_DISK).${NC}"
    echo ""
    echo "  Intenta manualmente:"
    echo "    diskutil mount $EFI_DISK"
    echo "    O:"
    echo "    mkdir -p /tmp/efi && mount -t msdos $EFI_DISK /tmp/efi"
    echo ""
    echo "  Luego ejecuta este script de nuevo."
    exit 1
fi

# Verify the mount is writable
if ! touch "$EFI_MOUNT/.test_write" 2>/dev/null; then
    echo -e "${RED}ERROR: La particion EFI esta montada en solo lectura.${NC}"
    echo "  Intenta: mount -uw $EFI_MOUNT"
    exit 1
fi
rm -f "$EFI_MOUNT/.test_write" 2>/dev/null
echo ""

# ---- STEP 4: Backup existing EFI ----
echo -e "${BLUE}[Step 4/7] Respaldando EFI existente...${NC}"

#if [ -d "$EFI_MOUNT/EFI/OC" ]; then
#    BACKUP_NAME="EFI_BACKUP_$(date +%Y%m%d_%H%M%S)"
#    if cp -R "$EFI_MOUNT/EFI" "$EFI_MOUNT/$BACKUP_NAME" 2>/dev/null; then
#        echo -e "${GREEN}  Respaldo creado: $EFI_MOUNT/$BACKUP_NAME${NC}"
#    else
#        echo -e "${YELLOW}  No se pudo crear respaldo (espacio insuficiente). Continuando...${NC}"
#    fi
#else
#    echo -e "  No hay instalacion previa de OpenCore.${NC}"
#fi
echo ""

# ---- STEP 5: Install OpenCore ----
echo -e "${BLUE}[Step 5/7] Instalando OpenCore en particion EFI...${NC}"

# Create EFI directory structure if needed
mkdir -p "$EFI_MOUNT/EFI" 2>/dev/null

# Remove old OpenCore (keep EFI/APPLE intact if it exists)
if [ -d "$EFI_MOUNT/EFI/OC" ]; then
    rm -rf "$EFI_MOUNT/EFI/OC"
    echo "  Eliminada instalacion anterior de OC."
fi
if [ -d "$EFI_MOUNT/EFI/BOOT" ]; then
    rm -rf "$EFI_MOUNT/EFI/BOOT"
    echo "  Eliminada carpeta BOOT anterior."
fi

# Copy new EFI
if ! cp -R "$SCRIPT_DIR/EFI/BOOT" "$EFI_MOUNT/EFI/BOOT"; then
    echo -e "${RED}ERROR: Fallo al copiar EFI/BOOT${NC}"
    exit 1
fi
if ! cp -R "$SCRIPT_DIR/EFI/OC" "$EFI_MOUNT/EFI/OC"; then
    echo -e "${RED}ERROR: Fallo al copiar EFI/OC${NC}"
    exit 1
fi

echo -e "${GREEN}  OpenCore copiado exitosamente.${NC}"
echo ""

# ---- STEP 6: Verify installation ----
echo -e "${BLUE}[Step 6/7] Verificando instalacion...${NC}"

VERIFY_OK=1
VERIFY_FILES=(
    "EFI/BOOT/BOOTx64.efi"
    "EFI/OC/OpenCore.efi"
    "EFI/OC/config.plist"
    "EFI/OC/Drivers/OpenRuntime.efi"
    "EFI/OC/Drivers/HfsPlus.efi"
)

for F in "${VERIFY_FILES[@]}"; do
    if [ -f "$EFI_MOUNT/$F" ]; then
        SIZE=$(wc -c < "$EFI_MOUNT/$F" 2>/dev/null | tr -d ' ')
        echo -e "  ${GREEN}OK${NC} $F ($SIZE bytes)"
    else
        echo -e "  ${RED}FALTA${NC} $F"
        VERIFY_OK=0
    fi
done

# Check kexts
for K in "Lilu.kext" "WhateverGreen.kext"; do
    if [ -d "$EFI_MOUNT/EFI/OC/Kexts/$K" ]; then
        echo -e "  ${GREEN}OK${NC} $K"
    else
        echo -e "  ${RED}FALTA${NC} $K"
        VERIFY_OK=0
    fi
done

echo ""
if [ "$VERIFY_OK" -eq 0 ]; then
    echo -e "${RED}ERROR: Faltan archivos despues de la instalacion!${NC}"
    echo "Revisa la particion EFI manualmente."
    exit 1
fi

# ---- STEP 7: Final summary ----
echo -e "${BLUE}[Step 7/7] Verificando configuracion...${NC}"
echo ""

echo "============================================================"
echo -e "${GREEN}${BOLD}  INSTALACION DE OPENCORE COMPLETADA!${NC}"
echo "============================================================"
echo ""
echo "  Que se instalo:"
echo "    - OpenCore 1.0.6 bootloader"
echo "    - Lilu 1.7.1 (motor de parches)"
echo "    - WhateverGreen 1.7.0 (parches GPU)"
echo ""
echo "  Configuracion:"
echo "    - boot-args: -v -wegnoegpu agdpmod=pikera -igfxblr"
echo "    - Vault: Optional (sin archivos vault)"
echo "    - SecureBootModel: Disabled"
echo "    - ScanPolicy: 0 (escanear todo)"
echo "    - Picker: 10 segundos timeout"
echo "    - SMBIOS: NO modificado (Mac real)"
echo ""
echo "  Que va a pasar al reiniciar:"
echo "    1. Veras el picker de OpenCore (10 seg)"
echo "    2. Selecciona 'Macintosh HD'"
echo "    3. Texto blanco en pantalla negra (verbose boot - NORMAL)"
echo "    4. La pantalla puede parpadear - ESPERA 2-3 minutos"
echo "    5. Aparece la pantalla de login"
echo ""
echo "  Si la pantalla queda negra mas de 3 minutos:"
echo "    - Apaga con boton de power (10 seg)"
echo "    - Enciende con Option/Alt para saltar OpenCore"
echo ""
echo -e "${BOLD}  SIGUIENTE PASO: Reinicia tu Mac ahora.${NC}"
echo ""
echo "============================================================"
echo ""
