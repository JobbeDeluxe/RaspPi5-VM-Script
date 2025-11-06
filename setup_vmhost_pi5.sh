#!/usr/bin/env bash
# Setup-Skript: Raspberry Pi 5 als KVM-VM-Host (Linux-VMs, optional Windows-ARM)
# Getestet für: Raspberry Pi OS / Debian-basiert, aarch64

set -euo pipefail

###########################################################
# Farben & Hilfsfunktionen
###########################################################

if [ -t 1 ]; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

info()  { echo "${BLUE}[INFO]${RESET}  $*"; }
ok()    { echo "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo "${RED}[ERROR]${RESET} $*" >&2; }

pause() {
  read -rp "Weiter mit [Enter] ..."
}

ask_yes_no_default_yes() {
  local prompt="$1"
  local answer
  read -rp "$prompt [Y/n]: " answer
  case "${answer:-Y}" in
    [YyJj]*) return 0 ;;
    *)       return 1 ;;
  esac
}

ask_yes_no_default_no() {
  local prompt="$1"
  local answer
  read -rp "$prompt [y/N]: " answer
  case "${answer:-N}" in
    [YyJj]*) return 0 ;;
    *)       return 1 ;;
  esac
}

###########################################################
# Root-Rechte sicherstellen
###########################################################

if [ "${EUID}" -ne 0 ]; then
  info "Skript braucht Root-Rechte – starte neu mit sudo ..."
  exec sudo bash "$0" "$@"
fi

###########################################################
# Begrüßung
###########################################################

cat <<'EOF'
===========================================
 Raspberry Pi 5 VM-Host Setup (KVM + libvirt)
===========================================

Dieses Skript wird:
- die Hardwarevirtualisierung prüfen (KVM),
- benötigte Pakete installieren (qemu, libvirt, virt-manager, ...),
- libvirtd aktivieren,
- das libvirt-Standardnetzwerk "default" einrichten,
- deinen Benutzer in die Gruppen 'kvm' und 'libvirt' aufnehmen,
- optional eine erste Ubuntu-ARM64-VM anlegen.

Bitte lies die Ausgaben aufmerksam.
EOF

pause

###########################################################
# System-Checks
###########################################################

ARCH="$(uname -m)"
info "Architektur erkannt: ${ARCH}"
if [ "${ARCH}" != "aarch64" ]; then
  warn "Dieses Skript ist für aarch64 (64-bit ARM) gedacht. Du nutzt: ${ARCH}"
  warn "KVM-Hardwarebeschleunigung funktioniert möglicherweise nicht."
  if ! ask_yes_no_default_no "Trotzdem fortfahren?"; then
    error "Abgebrochen auf Wunsch des Benutzers."
    exit 1
  fi
fi

# CPU-Fähigkeiten checken
if grep -Eqi "virt|kvm" /proc/cpuinfo; then
  ok "CPU meldet Virtualisierungsfunktionen (virt/kvm) – gut!"
else
  warn "In /proc/cpuinfo wurden keine Virtualisierungs-Flags gefunden."
  warn "Auf einem Raspberry Pi 5 sollte das normalerweise vorhanden sein."
  warn "Es kann trotzdem mit reiner Emulation weitergehen, aber deutlich langsamer."
fi

###########################################################
# KVM-Module laden
###########################################################

info "Prüfe KVM-Module (kvm, kvm_arm64) ..."
if ! lsmod | grep -q "^kvm"; then
  info "Versuche, KVM-Module zu laden ..."
  modprobe kvm || warn "Konnte 'kvm' nicht laden (evtl. Kernel ohne KVM-Unterstützung?)."
fi

if ! lsmod | grep -q "kvm_arm64"; then
  info "Versuche, kvm_arm64-Modul zu laden ..."
  modprobe kvm_arm64 || warn "Konnte 'kvm_arm64' nicht laden."
fi

if [ -e /dev/kvm ]; then
  ok "/dev/kvm ist vorhanden – Hardwarebeschleunigung sollte funktionieren."
else
  warn "/dev/kvm ist NICHT vorhanden. VMs laufen dann nur in Emulation (deutlich langsamer)."
fi

###########################################################
# Benutzer bestimmen, der VMs verwalten darf
###########################################################

DEFAULT_USER=""

if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  DEFAULT_USER="${SUDO_USER}"
else
  # Versuche, einen sinnvollen Standard aus /home zu wählen
  HOMES=(/home/*)
  if [ "${#HOMES[@]}" -eq 1 ]; then
    DEFAULT_USER="$(basename "${HOMES[0]}")"
  else
    DEFAULT_USER="pi"
  fi
fi

read -rp "Welcher NICHT-root Benutzer soll VMs verwalten dürfen? [${DEFAULT_USER}]: " VM_USER
VM_USER="${VM_USER:-${DEFAULT_USER}}"

if ! id "${VM_USER}" >/dev/null 2>&1; then
  error "Benutzer '${VM_USER}' existiert nicht. Bitte vorher anlegen und Skript erneut starten."
  exit 1
fi
ok "Verwende Benutzer: ${VM_USER}"

###########################################################
# Paketinstallation
###########################################################

info "Prüfe/verwalte benötigte Pakete (qemu, libvirt, virt-manager, ...)."

REQUIRED_PACKAGES=(
  qemu-system
  qemu-efi-aarch64
  libvirt-daemon-system
  libvirt-clients
  virtinst
  virt-manager
  bridge-utils
  dnsmasq
)

MISSING_PKGS=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
  ok "Alle benötigten Pakete scheinen bereits installiert zu sein."
else
  info "Folgende Pakete fehlen und sollten installiert werden:"
  printf '  - %s\n' "${MISSING_PKGS[@]}"
  if ask_yes_no_default_yes "Diese Pakete jetzt mit apt installieren?"; then
    info "Führe 'apt update' aus ..."
    apt-get update -y
    info "Installiere benötigte Pakete ..."
    if ! apt-get install -y "${MISSING_PKGS[@]}"; then
      error "Paketinstallation fehlgeschlagen. Bitte Ausgabe prüfen."
      exit 1
    fi
    ok "Pakete erfolgreich installiert."
  else
    warn "Du hast die Paketinstallation abgelehnt. Einige Funktionen werden evtl. nicht funktionieren."
  fi
fi

###########################################################
# libvirtd aktivieren
###########################################################

info "Aktiviere und starte libvirtd-Service ..."
if systemctl enable --now libvirtd; then
  ok "libvirtd läuft."
else
  warn "Konnte libvirtd nicht starten. Bitte 'systemctl status libvirtd' manuell prüfen."
fi

###########################################################
# Benutzer in Gruppen aufnehmen
###########################################################

info "Füge Benutzer '${VM_USER}' zu Gruppen 'kvm' und 'libvirt' hinzu ..."
usermod -aG kvm "${VM_USER}" || warn "Konnte Benutzer nicht zur Gruppe 'kvm' hinzufügen."
usermod -aG libvirt "${VM_USER}" || warn "Konnte Benutzer nicht zur Gruppe 'libvirt' hinzufügen."
ok "Gruppen wurden gesetzt. Du musst dich später einmal ab- und wieder anmelden."

###########################################################
# libvirt-Standardnetzwerk "default" prüfen/aktivieren
###########################################################

info "Prüfe libvirt-Netzwerk 'default' ..."

if ! command -v virsh >/dev/null 2>&1; then
  warn "'virsh' ist nicht verfügbar. Netzwerk-Konfiguration kann nicht geprüft werden."
else
  if virsh net-list --all | grep -q " default "; then
    info "Netzwerk 'default' ist definiert."
  else
    warn "Netzwerk 'default' ist NICHT definiert. Erzeuge Standard-NAT-Netzwerk ..."
    TMP_NET_XML=$(mktemp)
    cat > "${TMP_NET_XML}" <<'NETXML'
<network>
  <name>default</name>
  <uuid>00000000-0000-0000-0000-000000000001</uuid>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
NETXML
    virsh net-define "${TMP_NET_XML}" && ok "Netzwerk 'default' wurde definiert."
    rm -f "${TMP_NET_XML}"
  fi

  # Netzwerk starten und Autostart setzen
  if virsh net-info default >/dev/null 2>&1; then
    if ! virsh net-info default | grep -q "Active:.*yes"; then
      info "Starte Netzwerk 'default' ..."
      virsh net-start default || warn "Konnte 'default'-Netzwerk nicht starten."
    fi
    virsh net-autostart default >/dev/null 2>&1 || warn "Konnte Autostart für 'default' nicht setzen."
    ok "Netzwerk 'default' ist aktiv und autostart-fähig."
  fi
fi

###########################################################
# Optional: Beispiel-VM (Ubuntu ARM64) anlegen
###########################################################

if ask_yes_no_default_no "Möchtest du jetzt eine Beispiel-VM (Ubuntu 22.04 ARM64 Server) anlegen?"; then
  VM_NAME_DEFAULT="ubuntu-arm64"
  VM_DISK_DEFAULT="$HOME/${VM_NAME_DEFAULT}.qcow2"
  VM_DISK_SIZE_DEFAULT="20G"
  VM_RAM_DEFAULT="4096"

  read -rp "VM-Name [${VM_NAME_DEFAULT}]: " VM_NAME
  VM_NAME="${VM_NAME:-${VM_NAME_DEFAULT}}"

  read -rp "Pfad für virtuelle Disk [${VM_DISK_DEFAULT}]: " VM_DISK
  VM_DISK="${VM_DISK:-${VM_DISK_DEFAULT}}"

  read -rp "Größe der Disk (z.B. 20G) [${VM_DISK_SIZE_DEFAULT}]: " VM_DISK_SIZE
  VM_DISK_SIZE="${VM_DISK_SIZE:-${VM_DISK_SIZE_DEFAULT}}"

  read -rp "RAM in MB [${VM_RAM_DEFAULT}]: " VM_RAM
  VM_RAM="${VM_RAM:-${VM_RAM_DEFAULT}}"

  ISO_DEFAULT="$HOME/ubuntu-22.04.5-live-server-arm64.iso"
  read -rp "Pfad zum Ubuntu-ISO (ARM64) [${ISO_DEFAULT}]: " VM_ISO
  VM_ISO="${VM_ISO:-${ISO_DEFAULT}}"

  if [ ! -f "${VM_ISO}" ]; then
    warn "ISO-Datei '${VM_ISO}' existiert nicht."
    if ask_yes_no_default_yes "Soll das Ubuntu-ARM64-ISO jetzt mit wget in ${ISO_DEFAULT} heruntergeladen werden?"; then
      ISO_URL="https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.5-live-server-arm64.iso"
      info "Lade ISO von: ${ISO_URL}"
      sudo -u "${VM_USER}" wget -O "${ISO_DEFAULT}" "${ISO_URL}" || {
        error "Download des ISOs fehlgeschlagen."
        exit 1
      }
      VM_ISO="${ISO_DEFAULT}"
      ok "ISO heruntergeladen."
    else
      error "Ohne ISO kann keine Beispiel-VM angelegt werden. Überspringe VM-Erstellung."
      VM_ISO=""
    fi
  fi

  if [ -n "${VM_ISO}" ]; then
    info "Erstelle virtuelle Disk: ${VM_DISK} (${VM_DISK_SIZE}) ..."
    sudo -u "${VM_USER}" qemu-img create -f qcow2 "${VM_DISK}" "${VM_DISK_SIZE}" >/dev/null
    ok "Disk erstellt."

    info "Starte VM-Installation via virt-install ..."
    sudo -u "${VM_USER}" virt-install \
      --name "${VM_NAME}" \
      --memory "${VM_RAM}" \
      --vcpus 4 \
      --cpu host \
      --disk "path=${VM_DISK},format=qcow2" \
      --cdrom "${VM_ISO}" \
      --network network=default \
      --os-variant ubuntu22.04 \
      --boot uefi \
      --graphics gtk \
      --noautoconsole || {
        error "virt-install ist fehlgeschlagen. Bitte Ausgabe prüfen."
        exit 1
      }

    ok "VM '${VM_NAME}' wurde erstellt. Die Installation läuft im angezeigten Fenster."
  fi
else
  info "Beispiel-VM wird übersprungen."
fi

###########################################################
# Abschluss
###########################################################

cat <<EOF

${BOLD}FERTIG!${RESET}

Zusammenfassung:
- KVM-Module geprüft und (falls möglich) geladen.
- libvirtd aktiviert/gestartet (sofern möglich).
- Benutzer '${VM_USER}' zu Gruppen 'kvm' und 'libvirt' hinzugefügt.
- libvirt-Standardnetzwerk 'default' geprüft/angelegt/aktiviert.
- Optional wurde eine Beispiel-VM erstellt (falls gewählt).

WICHTIG:
- Bitte melde dich als Benutzer '${VM_USER}' einmal ab und wieder an,
  damit die neuen Gruppenrechte aktiv werden.
- Danach kannst du mit:

    ${BOLD}virt-manager${RESET}

  (unter '${VM_USER}') eine grafische Verwaltungsoberfläche für deine VMs starten.

Für CLI-Management:
- Alle VMs anzeigen: ${BOLD}virsh list --all${RESET}
- VM starten:        ${BOLD}virsh start <name>${RESET}
- VM stoppen:        ${BOLD}virsh shutdown <name>${RESET}

Viel Spaß beim Virtualisieren auf deinem Raspberry Pi 5! 🚀
EOF
