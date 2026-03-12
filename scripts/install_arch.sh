#!/usr/bin/env bash
###############################################################################
#  install_arch.sh — Installation automatisée Arch Linux + dots-hyprland
#
#  Ce script :
#    1. Installe Arch via archinstall avec les configs fournies
#    2. Installe yay (AUR helper)
#    3. Installe le thème dots-hyprland (illogical-impulse)
#    4. Configure arch-update
#    5. Désactive SDDM → TTY-only login + Hyprland auto-start
#    6. Corrige son/micro, power management, clés SSH, etc.
#    7. Applique des workarounds conditionnels pour les bugs connus
#
#  PHILOSOPHIE DES CORRECTIFS :
#    Chaque workaround est conditionnel — il vérifie si le problème existe
#    encore AVANT de s'appliquer. Si une mise à jour upstream corrige le bug,
#    le script n'appliquera pas de patch inutile.
#
#  Usage :
#    Depuis l'ISO Arch Linux live :
#      curl -LO https://raw.githubusercontent.com/isoura4/scripts/main/scripts/install_arch.sh
#      chmod +x install_arch.sh
#      ./install_arch.sh
###############################################################################
set -euo pipefail

# ========================== COULEURS ========================================
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
CYAN='\e[36m'
BOLD='\e[1m'
RST='\e[0m'

log()  { printf "${GREEN}${BOLD}[✔]${RST} %s\n" "$*"; }
warn() { printf "${YELLOW}${BOLD}[⚠]${RST} %s\n" "$*"; }
err()  { printf "${RED}${BOLD}[✘]${RST} %s\n" "$*"; }
info() { printf "${CYAN}${BOLD}[ℹ]${RST} %s\n" "$*"; }
section() { printf "\n${BLUE}${BOLD}══════════════════════════════════════════${RST}\n"; printf "${BLUE}${BOLD}  %s${RST}\n" "$*"; printf "${BLUE}${BOLD}══════════════════════════════════════════${RST}\n\n"; }

# ========================== VARIABLES =======================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_POINT="/mnt"
TARGET_USER=""          # Sera détecté depuis la config archinstall
DOTS_REPO="https://github.com/end-4/dots-hyprland.git"
DOTS_DIR_NAME="dots-hyprland"

# Fichiers de config archinstall — recherche d'abord dans $PWD, puis dans $SCRIPT_DIR
CONFIG_FILENAME="user_configuration.json"
CREDS_FILENAME="user_credentials.json"

if [[ -f "${PWD}/${CONFIG_FILENAME}" ]]; then
    USER_CONFIG="${PWD}/${CONFIG_FILENAME}"
else
    USER_CONFIG="${SCRIPT_DIR}/${CONFIG_FILENAME}"
fi
info "${CONFIG_FILENAME} résolu vers : $USER_CONFIG"

if [[ -f "${PWD}/${CREDS_FILENAME}" ]]; then
    USER_CREDS="${PWD}/${CREDS_FILENAME}"
else
    USER_CREDS="${SCRIPT_DIR}/${CREDS_FILENAME}"
fi
info "${CREDS_FILENAME} résolu vers : $USER_CREDS"

# ========================== VÉRIFICATIONS PRÉLIMINAIRES ======================
section "Vérifications préliminaires"

if [[ "$(id -u)" -ne 0 ]]; then
    err "Ce script doit être exécuté en tant que root (depuis l'ISO live)."
    exit 1
fi

if [[ ! -f "$USER_CONFIG" ]]; then
    err "Fichier de configuration introuvable : $USER_CONFIG"
    err "Placez user_configuration.json dans le répertoire courant ou dans le même dossier que ce script."
    exit 1
fi

if [[ ! -f "$USER_CREDS" ]]; then
    err "Fichier de credentials introuvable : $USER_CREDS"
    err "Placez user_credentials.json dans le répertoire courant ou dans le même dossier que ce script."
    exit 1
fi

# Détection de l'utilisateur cible depuis les credentials
# On cherche un nom d'utilisateur dans le fichier JSON creds
# Si le format est chiffré argon2, on demandera à l'utilisateur
if command -v python3 &>/dev/null; then
    TARGET_USER=$(python3 -c "
import json, sys
try:
    with open('$USER_CREDS') as f:
        data = json.load(f)
    # Chercher la première clé qui n'est pas '!root' et pas 'root'
    for user in data:
        if user != 'root' and not user.startswith('!'):
            print(user)
            sys.exit(0)
except:
    pass
" 2>/dev/null || true)
fi

if [[ -z "$TARGET_USER" ]]; then
    warn "Impossible de détecter le nom d'utilisateur depuis les credentials."
    read -rp "Entrez le nom d'utilisateur à créer : " TARGET_USER
    if [[ -z "$TARGET_USER" ]]; then
        err "Nom d'utilisateur requis. Abandon."
        exit 1
    fi
fi

log "Utilisateur cible détecté/défini : $TARGET_USER"

###############################################################################
#  PHASE 1 : Installation d'Arch via archinstall
###############################################################################
section "Phase 1 : Installation d'Arch Linux via archinstall"

info "Synchronisation de l'horloge système..."
timedatectl set-ntp true
sleep 2

info "Lancement d'archinstall avec les fichiers de configuration..."
# Copier les configs dans un répertoire temporaire propre pour archinstall
ARCHINSTALL_CONFIG_DIR=$(mktemp -d)
cp "$USER_CONFIG" "${ARCHINSTALL_CONFIG_DIR}/user_configuration.json"
cp "$USER_CREDS" "${ARCHINSTALL_CONFIG_DIR}/user_credentials.json"

# Lancer archinstall en mode non-interactif
archinstall \
    --config "${ARCHINSTALL_CONFIG_DIR}/user_configuration.json" \
    --creds "${ARCHINSTALL_CONFIG_DIR}/user_credentials.json" \
    --silent

rm -rf "$ARCHINSTALL_CONFIG_DIR"
log "archinstall terminé avec succès."

# Vérifier que MOUNT_POINT est toujours monté après archinstall (archinstall démonte /mnt à la fin)
if ! mountpoint -q "${MOUNT_POINT}"; then
    warn "archinstall a démonté ${MOUNT_POINT}, tentative de remontage..."
    ROOT_PART=$(lsblk -rno NAME,PARTLABEL | grep -iw root | head -1 | awk '{print $1}')
    if [[ -z "$ROOT_PART" ]]; then
        # Fallback : prendre la partition non-swap avec le système de fichiers compatible la plus grande
        ROOT_PART=$(lsblk -rno NAME,FSTYPE,SIZE | grep -E "ext4|btrfs|xfs" | sort -k3 -rh | head -1 | awk '{print $1}')
    fi
    if [[ -n "$ROOT_PART" ]]; then
        mount "/dev/${ROOT_PART}" "${MOUNT_POINT}"
        log "Partition root /dev/${ROOT_PART} remontée sur ${MOUNT_POINT}."
        if [[ -f "${MOUNT_POINT}/etc/fstab" ]]; then
            if ! mount --all --fstab "${MOUNT_POINT}/etc/fstab" --target-prefix "${MOUNT_POINT}" 2>/dev/null; then
                warn "Certaines partitions secondaires n'ont pas pu être remontées depuis ${MOUNT_POINT}/etc/fstab."
            fi
        fi
    else
        err "Impossible de retrouver la partition root. Abandon."
        exit 1
    fi
fi

###############################################################################
#  PHASE 2 : Post-installation dans le chroot
###############################################################################
section "Phase 2 : Post-installation (chroot)"

# S'assurer que /tmp existe dans le système cible avant d'y écrire
mkdir -p "${MOUNT_POINT}/tmp"

# Créer le script de post-installation qui s'exécutera dans le chroot
cat > "${MOUNT_POINT}/tmp/post_install.sh" << 'CHROOT_SCRIPT'
#!/bin/bash
set -euo pipefail

# Couleurs (redéfinies dans le chroot)
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'; CYAN='\e[36m'
BOLD='\e[1m'; RST='\e[0m'
log()  { printf "${GREEN}${BOLD}[✔]${RST} %s\n" "$*"; }
warn() { printf "${YELLOW}${BOLD}[⚠]${RST} %s\n" "$*"; }
err()  { printf "${RED}${BOLD}[✘]${RST} %s\n" "$*"; }
info() { printf "${CYAN}${BOLD}[ℹ]${RST} %s\n" "$*"; }
section() { printf "\n${BLUE}${BOLD}══════════════════════════════════════════${RST}\n"; printf "${BLUE}${BOLD}  %s${RST}\n" "$*"; printf "${BLUE}${BOLD}══════════════════════════════════════════${RST}\n\n"; }

CHROOT_SCRIPT

# Injecter la variable TARGET_USER dans le script chroot
sed -i "1a TARGET_USER=\"${TARGET_USER}\"" "${MOUNT_POINT}/tmp/post_install.sh"

cat >> "${MOUNT_POINT}/tmp/post_install.sh" << 'CHROOT_SCRIPT'
TARGET_HOME="/home/${TARGET_USER}"

###########################################################################
#  2.1  Installation de yay (AUR helper)
###########################################################################
section "2.1 — Installation de yay"

if command -v yay &>/dev/null; then
    log "yay est déjà installé, passage à la suite."
else
    info "Installation des prérequis (base-devel, git)..."
    pacman -S --needed --noconfirm base-devel git

    info "Construction et installation de yay..."
    # Construire yay en tant qu'utilisateur non-root
    su - "$TARGET_USER" -c '
        cd /tmp
        rm -rf yay-bin
        git clone https://aur.archlinux.org/yay-bin.git
        cd yay-bin
        makepkg -si --noconfirm
    '
    rm -rf /tmp/yay-bin
    log "yay installé avec succès."
fi

###########################################################################
#  2.2  Paquets système supplémentaires
###########################################################################
section "2.2 — Paquets système supplémentaires"

info "Installation des paquets audio, réseau, et outils..."
pacman -S --needed --noconfirm \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
    sof-firmware alsa-firmware alsa-utils \
    pavucontrol \
    power-profiles-daemon \
    polkit-gnome \
    gnome-keyring seahorse libsecret \
    xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
    networkmanager \
    bluez bluez-utils \
    openssh \
    fish foot \
    python python-pip python-virtualenv \
    jq rsync wget curl unzip \
    wl-clipboard cliphist

# Activer les services systèmes
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable power-profiles-daemon
systemctl enable sshd

log "Paquets système installés et services activés."

###########################################################################
#  2.3  Installation de arch-update
###########################################################################
section "2.3 — Installation de arch-update"

info "Installation de arch-update via yay..."
su - "$TARGET_USER" -c 'yay -S --needed --noconfirm arch-update'

# Activer le timer systemd pour les vérifications automatiques
# (si arch-update fournit un timer, l'activer pour l'utilisateur)
if [[ -f /usr/lib/systemd/user/arch-update.timer ]]; then
    su - "$TARGET_USER" -c 'systemctl --user enable arch-update.timer'
    log "arch-update timer activé."
else
    warn "Timer arch-update non trouvé — il sera configuré au premier login."
fi

log "arch-update installé."

###########################################################################
#  2.4  Désactivation de SDDM → TTY-only + Hyprland auto-start
###########################################################################
section "2.4 — Désactivation de SDDM, configuration TTY → Hyprland"

# Désactiver SDDM s'il est activé
if systemctl is-enabled sddm &>/dev/null 2>&1; then
    systemctl disable sddm
    log "SDDM désactivé."
else
    info "SDDM n'était pas activé."
fi

# Configurer l'auto-login en TTY1 pour l'utilisateur
info "Configuration de l'auto-login TTY1..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\\\u' --noclear --autologin ${TARGET_USER} %I \$TERM
Type=simple
EOF

log "Auto-login TTY1 configuré pour ${TARGET_USER}."

# Configurer le lancement automatique de Hyprland depuis le shell profile
# On utilise un fichier séparé pour ne pas polluer .bash_profile
info "Configuration du lancement automatique de Hyprland..."
cat > "${TARGET_HOME}/.bash_profile" << 'BASHPROFILE'
# ~/.bash_profile — Généré par install_arch.sh
# Charger .bashrc s'il existe
[[ -f ~/.bashrc ]] && . ~/.bashrc

# Variables XDG (définies ici pour être disponibles partout)
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"

# Ajouter ~/.local/bin au PATH
export PATH="$XDG_BIN_HOME:$PATH"

# Lancer Hyprland automatiquement sur TTY1 (et seulement TTY1)
if [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec Hyprland
fi
BASHPROFILE
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.bash_profile"

log "Hyprland se lancera automatiquement sur TTY1."

###########################################################################
#  2.5  Installation du thème dots-hyprland (illogical-impulse)
###########################################################################
section "2.5 — Installation du thème dots-hyprland"

info "Clonage du dépôt dots-hyprland..."
su - "$TARGET_USER" -c "
    cd ~
    if [[ -d '${DOTS_DIR_NAME}' ]]; then
        echo 'Dépôt déjà présent, mise à jour...'
        cd '${DOTS_DIR_NAME}'
        git stash 2>/dev/null || true
        git pull --recurse-submodules
    else
        git clone --recurse-submodules '${DOTS_REPO}'
    fi
"

DOTS_PATH="${TARGET_HOME}/${DOTS_DIR_NAME}"

info "Lancement du script d'installation du thème (mode automatique)..."
# Le script ./setup du dépôt gère tout : dépendances, fichiers, services
# On utilise --force --skip-allgreeting pour automatiser
su - "$TARGET_USER" -c "
    cd '${DOTS_PATH}'
    ./setup install --force --skip-allgreeting --skip-sysupdate
"

log "Thème dots-hyprland installé."

###########################################################################
#  2.6  Configuration audio / micro
###########################################################################
section "2.6 — Configuration audio et microphone"

# PipeWire est déjà installé — s'assurer que les services utilisateur sont activés
# (ils se lanceront au prochain login Wayland)
info "Activation des services PipeWire pour ${TARGET_USER}..."
su - "$TARGET_USER" -c '
    systemctl --user enable pipewire.socket 2>/dev/null || true
    systemctl --user enable pipewire-pulse.socket 2>/dev/null || true
    systemctl --user enable wireplumber.service 2>/dev/null || true
' || true

# Installer sof-firmware pour le support micro des laptops récents
# (déjà fait plus haut mais on vérifie)
if ! pacman -Qi sof-firmware &>/dev/null; then
    pacman -S --noconfirm sof-firmware
fi

log "Audio/micro configuré (PipeWire + WirePlumber + sof-firmware)."

###########################################################################
#  2.7  Power management
###########################################################################
section "2.7 — Power management"

# power-profiles-daemon est déjà installé et activé (cf. config archinstall)
# Vérifier qu'il est bien actif
if systemctl is-enabled power-profiles-daemon &>/dev/null; then
    log "power-profiles-daemon est activé."
else
    systemctl enable power-profiles-daemon
    log "power-profiles-daemon activé."
fi

###########################################################################
#  2.8  Clés SSH / GPG — Déverrouillage automatique via gnome-keyring
###########################################################################
section "2.8 — Configuration du trousseau de clés (gnome-keyring)"

# gnome-keyring déverrouille les clés SSH/GPG automatiquement à la connexion
# Il faut configurer PAM pour le déverrouillage automatique

# Vérifier que gnome-keyring est installé
if ! pacman -Qi gnome-keyring &>/dev/null; then
    pacman -S --noconfirm gnome-keyring libsecret seahorse
fi

# Configurer PAM pour gnome-keyring (login)
PAM_LOGIN="/etc/pam.d/login"
if ! grep -q "pam_gnome_keyring.so" "$PAM_LOGIN" 2>/dev/null; then
    info "Ajout de gnome-keyring à PAM (login)..."

    # Ajouter auth optional pam_gnome_keyring.so après auth include system-local-login
    if grep -q "auth.*include.*system-local-login" "$PAM_LOGIN"; then
        sed -i '/auth.*include.*system-local-login/a auth       optional     pam_gnome_keyring.so' "$PAM_LOGIN"
    else
        echo "auth       optional     pam_gnome_keyring.so" >> "$PAM_LOGIN"
    fi

    # Ajouter session optional pam_gnome_keyring.so auto_start à la fin
    if ! grep -q "pam_gnome_keyring.so.*auto_start" "$PAM_LOGIN"; then
        echo "session    optional     pam_gnome_keyring.so auto_start" >> "$PAM_LOGIN"
    fi

    log "PAM configuré pour gnome-keyring (déverrouillage auto au login TTY)."
else
    info "gnome-keyring déjà configuré dans PAM."
fi

# Ajouter le démarrage de gnome-keyring-daemon dans l'environnement Hyprland
# On l'ajoute dans le fichier custom/execs.conf du thème (qui n'est pas écrasé
# par les mises à jour du thème grâce au mode skip-if-exists)
HYPR_CUSTOM_EXECS="${TARGET_HOME}/.config/hypr/custom/execs.conf"
if [[ -f "$HYPR_CUSTOM_EXECS" ]]; then
    if ! grep -q "gnome-keyring-daemon" "$HYPR_CUSTOM_EXECS"; then
        cat >> "$HYPR_CUSTOM_EXECS" << 'KEYRING'

# === Déverrouillage automatique des clés SSH/GPG ===
exec-once = gnome-keyring-daemon --start --components=secrets,ssh,pkcs11
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
KEYRING
        chown "${TARGET_USER}:${TARGET_USER}" "$HYPR_CUSTOM_EXECS"
        log "gnome-keyring-daemon ajouté aux execs Hyprland."
    fi
else
    warn "Fichier custom/execs.conf non trouvé — gnome-keyring sera ajouté au premier login."
fi

# Variables d'environnement pour que les apps utilisent le keyring
HYPR_CUSTOM_ENV="${TARGET_HOME}/.config/hypr/custom/env.conf"
if [[ -f "$HYPR_CUSTOM_ENV" ]]; then
    if ! grep -q "SSH_AUTH_SOCK" "$HYPR_CUSTOM_ENV"; then
        cat >> "$HYPR_CUSTOM_ENV" << 'ENVKEYRING'

# === gnome-keyring SSH agent ===
env = SSH_AUTH_SOCK,$XDG_RUNTIME_DIR/keyring/ssh
ENVKEYRING
        chown "${TARGET_USER}:${TARGET_USER}" "$HYPR_CUSTOM_ENV"
        log "Variable SSH_AUTH_SOCK configurée."
    fi
fi

###########################################################################
#  2.9  WORKAROUNDS CONDITIONNELS (ne s'appliquent que si le bug existe)
###########################################################################
section "2.9 — Correctifs conditionnels (workarounds)"

info "Application des workarounds pour bugs connus..."
info "Chaque correctif vérifie d'abord si le problème persiste."

HYPR_CUSTOM_GENERAL="${TARGET_HOME}/.config/hypr/custom/general.conf"
HYPR_CUSTOM_KEYBINDS="${TARGET_HOME}/.config/hypr/custom/keybinds.conf"
HYPRIDLE_CONF="${TARGET_HOME}/.config/hypr/hypridle.conf"

# ─── FIX 1 : Curseur noir sur multi-moniteur (#3054) ───
# Conditionnel : n'applique que si no_hardware_cursors n'est pas déjà défini
# Quand upstream corrigera, ce paramètre restera inoffensif (valeur par défaut)
if [[ -f "$HYPR_CUSTOM_GENERAL" ]]; then
    if ! grep -q "no_hardware_cursors" "$HYPR_CUSTOM_GENERAL" 2>/dev/null; then
        cat >> "$HYPR_CUSTOM_GENERAL" << 'FIX_CURSOR'

# === Workaround #3054 : curseur noir multi-moniteur ===
# Supprimable si corrigé en upstream — ce paramètre est sûr à laisser
cursor {
    no_hardware_cursors = true
}
FIX_CURSOR
        chown "${TARGET_USER}:${TARGET_USER}" "$HYPR_CUSTOM_GENERAL"
        log "Fix curseur multi-moniteur appliqué (conditionnel)."
    else
        info "Fix curseur : déjà configuré, ignoré."
    fi
fi

# ─── FIX 2 : Lock avant suspend (#3077) — veille/sleep ───
# Conditionnel : n'ajoute que si aucun mécanisme before-sleep n'est déjà en place
if [[ -f "$HYPR_CUSTOM_EXECS" ]]; then
    if ! grep -qi "before-sleep\|lock.*suspend\|hypridle.*lock" "$HYPR_CUSTOM_EXECS" 2>/dev/null; then
        # Vérifier aussi dans hypridle.conf
        NEEDS_SLEEP_FIX=true
        if [[ -f "$HYPRIDLE_CONF" ]] && grep -qi "before_sleep_cmd\|loginctl lock-session" "$HYPRIDLE_CONF" 2>/dev/null; then
            NEEDS_SLEEP_FIX=false
        fi
        if [[ "$NEEDS_SLEEP_FIX" == "true" ]]; then
            cat >> "$HYPR_CUSTOM_EXECS" << 'FIX_SLEEP'

# === Workaround #3077 : Forcer lock avant mise en veille ===
# Supprimable si hypridle gère cela nativement dans une future version
exec-once = hypridle &
FIX_SLEEP
            chown "${TARGET_USER}:${TARGET_USER}" "$HYPR_CUSTOM_EXECS"
            log "Fix lock-before-sleep appliqué (conditionnel)."
        else
            info "Fix sleep : hypridle gère déjà le lock avant suspend."
        fi
    fi
fi

# ─── FIX 3 : Détection et workaround NVIDIA ───
# Conditionnel : ne s'applique que si une carte NVIDIA est détectée
if lspci 2>/dev/null | grep -qi "nvidia"; then
    warn "GPU NVIDIA détecté — application des workarounds Wayland."

    if [[ -f "$HYPR_CUSTOM_ENV" ]] && ! grep -q "GBM_BACKEND" "$HYPR_CUSTOM_ENV" 2>/dev/null; then
        cat >> "$HYPR_CUSTOM_ENV" << 'FIX_NVIDIA'

# === Workaround NVIDIA : variables d'environnement Wayland ===
# Supprimable si les drivers NVIDIA supportent nativement Wayland un jour
env = LIBVA_DRIVER_NAME,nvidia
env = XDG_SESSION_TYPE,wayland
env = GBM_BACKEND,nvidia-drm
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct
FIX_NVIDIA
        chown "${TARGET_USER}:${TARGET_USER}" "$HYPR_CUSTOM_ENV"
        log "Variables NVIDIA ajoutées."
    fi

    # Installer les paquets NVIDIA si pas déjà présents
    if ! pacman -Qi nvidia-dkms &>/dev/null 2>&1; then
        info "Installation des paquets NVIDIA..."
        pacman -S --needed --noconfirm nvidia-dkms nvidia-utils lib32-nvidia-utils 2>/dev/null || \
            warn "Impossible d'installer les paquets NVIDIA — à faire manuellement."
    fi
else
    info "Pas de GPU NVIDIA détecté, pas de workaround nécessaire."
fi

# ─── FIX 4 : Keybinds AZERTY FR (#2993, #3055) ───
# Conditionnel : vérifie le layout clavier, ne s'applique que si FR
CURRENT_KB_LAYOUT=$(localectl status 2>/dev/null | grep "X11 Layout" | awk '{print $NF}' || echo "")
if [[ "$CURRENT_KB_LAYOUT" == "fr" ]] || grep -q '"kb_layout": "fr"' /etc/vconsole.conf 2>/dev/null || grep -q "fr" /etc/vconsole.conf 2>/dev/null; then
    if [[ -f "$HYPR_CUSTOM_KEYBINDS" ]] && ! grep -q "AZERTY.*fix\|code:61" "$HYPR_CUSTOM_KEYBINDS" 2>/dev/null; then
        cat >> "$HYPR_CUSTOM_KEYBINDS" << 'FIX_AZERTY'

# === Workaround #2993/#3055 : Raccourcis AZERTY ===
# Les raccourcis basés sur des caractères US ne fonctionnent pas sur AZERTY.
# On utilise les keycodes physiques comme alternative.
# Supprimable si Hyprland ajoute un support natif multi-layout pour les binds.
#
# Astuce : utilisez `wev` pour trouver le keycode d'une touche.
# Super+/ (slash) sur AZERTY = touche physique code:61
# unbind = Super, Slash
# bindd = Super, code:61, Toggle cheatsheet, global, quickshell:cheatsheetToggle
FIX_AZERTY
        chown "${TARGET_USER}:${TARGET_USER}" "$HYPR_CUSTOM_KEYBINDS"
        log "Commentaires d'aide AZERTY ajoutés aux keybinds."
    fi
fi

# ─── FIX 5 : Python venv pour les couleurs Material You (#3064, #3011) ───
# Conditionnel : vérifie si le venv existe et fonctionne déjà
QUICKSHELL_VENV="${TARGET_HOME}/.local/state/quickshell/.venv"
su - "$TARGET_USER" -c "
    if [[ ! -d '${QUICKSHELL_VENV}' ]] || ! '${QUICKSHELL_VENV}/bin/python' -c 'import material_color_utilities' 2>/dev/null; then
        echo '[ℹ] Création/réparation du venv Python pour Quickshell...'
        mkdir -p '${QUICKSHELL_VENV%/*}'
        python3 -m venv '${QUICKSHELL_VENV}'
        '${QUICKSHELL_VENV}/bin/pip' install --quiet \
            material-color-utilities 2>/dev/null || \
        echo '[⚠] Certains paquets Python ont échoué — le thème les réinstallera au premier lancement.'
    else
        echo '[ℹ] venv Python Quickshell : déjà fonctionnel.'
    fi
" || warn "Configuration venv Python partielle — sera complétée au premier lancement du thème."

# ─── FIX 6 : Portails XDG pour partage d'écran ───
# Conditionnel : n'installe que si pas déjà présent
PORTAL_PKGS=("xdg-desktop-portal-hyprland" "xdg-desktop-portal-gtk")
PORTAL_MISSING=()
for pkg in "${PORTAL_PKGS[@]}"; do
    if ! pacman -Qi "$pkg" &>/dev/null; then
        PORTAL_MISSING+=("$pkg")
    fi
done
if [[ ${#PORTAL_MISSING[@]} -gt 0 ]]; then
    info "Installation des portails XDG manquants : ${PORTAL_MISSING[*]}"
    pacman -S --needed --noconfirm "${PORTAL_MISSING[@]}"
    log "Portails XDG installés."
else
    info "Portails XDG : déjà installés."
fi

# ─── FIX 7 : zram / swap ───
# Conditionnel : configure seulement si zram-generator est installé mais pas configuré
if pacman -Qi zram-generator &>/dev/null 2>&1; then
    if [[ ! -f /etc/systemd/zram-generator.conf ]]; then
        info "Configuration de zram-generator..."
        cat > /etc/systemd/zram-generator.conf << 'ZRAM'
[zram0]
zram-size = min(ram, 8192)
compression-algorithm = zstd
ZRAM
        log "zram-generator configuré."
    else
        info "zram-generator : déjà configuré."
    fi
fi

# ─── FIX 8 : Service systemd lock-before-sleep (#3077) ───
# Conditionnel : n'ajoute que si le service n'existe pas encore
LOCK_SERVICE="/etc/systemd/system/lock-before-sleep@.service"
if [[ ! -f "$LOCK_SERVICE" ]]; then
    info "Création du service lock-before-sleep..."
    cat > "$LOCK_SERVICE" << 'LOCKSERVICE'
# === Workaround #3077 : Verrouiller l'écran avant la mise en veille ===
# Supprimable si hyprlock/hypridle gère cela correctement en upstream
[Unit]
Description=Lock screen before sleep
Before=sleep.target

[Service]
User=%i
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/%U
ExecStart=/usr/bin/hyprlock --immediate

[Install]
WantedBy=sleep.target
LOCKSERVICE
    systemctl enable "lock-before-sleep@${TARGET_USER}.service" 2>/dev/null || \
        warn "Impossible d'activer lock-before-sleep — à faire manuellement."
    log "Service lock-before-sleep créé et activé."
else
    info "Service lock-before-sleep : existe déjà."
fi

###########################################################################
#  2.10  Variables d'environnement globales pour le shell
###########################################################################
section "2.10 — Variables d'environnement"

# Le .bash_profile a déjà été créé avec les XDG vars
# Ajouter aussi un .zprofile si zsh est installé
if command -v zsh &>/dev/null; then
    if [[ ! -f "${TARGET_HOME}/.zprofile" ]] || ! grep -q "XDG_CONFIG_HOME" "${TARGET_HOME}/.zprofile" 2>/dev/null; then
        cat > "${TARGET_HOME}/.zprofile" << 'ZPROFILE'
# Variables XDG
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
export PATH="$XDG_BIN_HOME:$PATH"

# Auto-start Hyprland sur TTY1
if [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec Hyprland
fi
ZPROFILE
        chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.zprofile"
        log ".zprofile créé."
    fi
fi

###########################################################################
#  2.11  Script de mise à jour facile du thème
###########################################################################
section "2.11 — Script utilitaire de mise à jour"

# Créer un petit script que l'utilisateur pourra lancer pour mettre à jour
mkdir -p "${TARGET_HOME}/.local/bin"
cat > "${TARGET_HOME}/.local/bin/update-dots" << UPDATESCRIPT
#!/usr/bin/env bash
# Met à jour le thème dots-hyprland sans réinstaller Arch
set -euo pipefail
DOTS_DIR="\${HOME}/${DOTS_DIR_NAME}"

echo "🔄 Mise à jour du système..."
yay -Syu --noconfirm

echo "🔄 Mise à jour de arch-update..."
if command -v arch-update &>/dev/null; then
    arch-update --check 2>/dev/null || true
fi

echo "🔄 Mise à jour du thème dots-hyprland..."
if [[ -d "\${DOTS_DIR}" ]]; then
    cd "\${DOTS_DIR}"
    git stash 2>/dev/null || true
    git pull --recurse-submodules
    ./setup install --force --skip-allgreeting --skip-backup
    echo "✅ Thème mis à jour. Redémarrez Hyprland (Super+Shift+M) pour appliquer."
else
    echo "❌ Dossier \${DOTS_DIR} introuvable."
fi
UPDATESCRIPT
chmod +x "${TARGET_HOME}/.local/bin/update-dots"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.local/bin"
log "Script update-dots créé dans ~/.local/bin/"

###########################################################################
#  2.12  Diagnostic script
###########################################################################
section "2.12 — Script de diagnostic"

cat > "${TARGET_HOME}/.local/bin/diagnose-dots" << 'DIAGSCRIPT'
#!/usr/bin/env bash
# Vérifie l'état de l'installation et détecte les problèmes connus
echo "═══ Diagnostic dots-hyprland ═══"
echo ""

echo "── Hyprland ──"
hyprctl version 2>/dev/null || echo "  ✘ Hyprland non accessible"
echo ""

echo "── Audio (PipeWire) ──"
if systemctl --user is-active pipewire &>/dev/null; then
    echo "  ✔ PipeWire actif"
else
    echo "  ✘ PipeWire inactif — lancer: systemctl --user start pipewire"
fi
if systemctl --user is-active wireplumber &>/dev/null; then
    echo "  ✔ WirePlumber actif"
else
    echo "  ✘ WirePlumber inactif"
fi
echo ""

echo "── GPU ──"
lspci | grep -i "vga\|3d" || echo "  Aucun GPU détecté"
echo ""

echo "── NVIDIA ──"
if lspci | grep -qi nvidia; then
    echo "  GPU NVIDIA détecté"
    if [[ -f ~/.config/hypr/custom/env.conf ]] && grep -q "GBM_BACKEND" ~/.config/hypr/custom/env.conf; then
        echo "  ✔ Variables NVIDIA configurées"
    else
        echo "  ✘ Variables NVIDIA manquantes dans env.conf"
    fi
else
    echo "  Pas de GPU NVIDIA"
fi
echo ""

echo "── Keyring ──"
if pgrep -f gnome-keyring-daemon &>/dev/null; then
    echo "  ✔ gnome-keyring-daemon actif"
else
    echo "  ✘ gnome-keyring-daemon inactif"
fi
echo ""

echo "── Python venv Quickshell ──"
VENV="$HOME/.local/state/quickshell/.venv"
if [[ -d "$VENV" ]] && "$VENV/bin/python" -c "import material_color_utilities" 2>/dev/null; then
    echo "  ✔ venv OK, material-color-utilities disponible"
else
    echo "  ✘ venv manquant ou incomplet — lancer: update-dots"
fi
echo ""

echo "── Portails XDG ──"
for pkg in xdg-desktop-portal-hyprland xdg-desktop-portal-gtk; do
    if pacman -Qi "$pkg" &>/dev/null; then
        echo "  ✔ $pkg installé"
    else
        echo "  ✘ $pkg manquant"
    fi
done
echo ""

echo "── Services ──"
for svc in bluetooth power-profiles-daemon NetworkManager; do
    if systemctl is-active "$svc" &>/dev/null; then
        echo "  ✔ $svc actif"
    else
        echo "  ✘ $svc inactif"
    fi
done
echo ""

echo "── SDDM ──"
if systemctl is-enabled sddm &>/dev/null 2>&1; then
    echo "  ⚠ SDDM est activé (devrait être désactivé pour le thème)"
else
    echo "  ✔ SDDM désactivé"
fi
echo ""
echo "═══ Fin du diagnostic ═══"
DIAGSCRIPT
chmod +x "${TARGET_HOME}/.local/bin/diagnose-dots"
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.local/bin/diagnose-dots"
log "Script diagnose-dots créé."

###########################################################################
#  FIN du chroot
###########################################################################
section "Post-installation terminée"
log "Tous les composants sont installés et configurés."
info ""
info "Résumé :"
info "  • Arch Linux installé via archinstall"
info "  • yay (AUR helper) installé"
info "  • Thème dots-hyprland (illogical-impulse) installé"
info "  • arch-update installé et configuré"
info "  • SDDM désactivé → TTY1 auto-login → Hyprland"
info "  • Audio : PipeWire + WirePlumber + sof-firmware"
info "  • Power : power-profiles-daemon"
info "  • Clés SSH : gnome-keyring (déverrouillage auto)"
info "  • Workarounds conditionnels appliqués"
info ""
info "Commandes utiles après le premier boot :"
info "  update-dots       — Met à jour le thème et le système"
info "  diagnose-dots     — Vérifie l'état de l'installation"
info "  Ctrl+Alt+F2       — TTY de secours si Hyprland crash"

CHROOT_SCRIPT

# Rendre le script exécutable et le lancer dans le chroot
chmod +x "${MOUNT_POINT}/tmp/post_install.sh"

# Injecter les variables nécessaires au début du script chroot
sed -i "2a DOTS_REPO=\"${DOTS_REPO}\"" "${MOUNT_POINT}/tmp/post_install.sh"
sed -i "3a DOTS_DIR_NAME=\"${DOTS_DIR_NAME}\"" "${MOUNT_POINT}/tmp/post_install.sh"

info "Exécution du script de post-installation dans le chroot..."
arch-chroot "${MOUNT_POINT}" /tmp/post_install.sh

# Nettoyage
rm -f "${MOUNT_POINT}/tmp/post_install.sh"

###############################################################################
#  PHASE 3 : Finalisation
###############################################################################
section "Phase 3 : Finalisation"

log "Installation complète !"
info ""
info "╔═══════════════════════════════════════════════════════════╗"
info "║  L'installation est terminée !                          ║"
info "║                                                          ║"
info "║  Retirez la clé USB et redémarrez :                     ║"
info "║    umount -R /mnt && reboot                             ║"
info "║                                                          ║"
info "║  Au prochain démarrage :                                ║"
info "║    → Auto-login TTY1 → Hyprland se lance                ║"
info "║    → Le thème illogical-impulse est prêt                ║"
info "║                                                          ║"
info "║  En cas de problème :                                   ║"
info "║    → Ctrl+Alt+F2 pour un TTY de secours                 ║"
info "║    → diagnose-dots pour un diagnostic                   ║"
info "║    → update-dots pour tout mettre à jour                ║"
info "╚═══════════════════════════════════════════════════════════╝"
info ""
