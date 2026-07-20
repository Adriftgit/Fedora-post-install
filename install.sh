#!/bin/bash
# Fedora-post-install setup

# ── Helper functions ─────────────────────────────────────────────────────
is_installed_dnf() {
    rpm -q "$1" &>/dev/null
}

warn() {
    echo "[WARNING] $*" >&2
}

enable_copr_if_needed() {
    local copr_repo="$1"
    if ! sudo dnf copr list 2>/dev/null | grep -qF "$copr_repo"; then
        sudo dnf copr enable -y "$copr_repo" || warn "Failed to enable COPR: $copr_repo"
    fi
}

# ── Determine non-root target user and home ──────────────────────────────
if [ -n "${SUDO_USER:-}" ]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="$USER"
fi
TARGET_HOME=$(eval echo ~"$TARGET_USER")

# ── Flags ────────────────────────────────────────────────────────────────
AUTO_REBOOT=false   # you may change this or activate via a parameter later

echo "──────────────────────────────────────────"
echo " Fedora Post-Install Setup"
echo "──────────────────────────────────────────"
## ── DNF OPTIMISATION ──────────────────────────────────────────────────────
echo "Applying DNF Optimisations "
grep -q 'max_parallel_downloads' /etc/dnf/dnf.conf || {
  echo 'max_parallel_downloads=10' | sudo tee -a /etc/dnf/dnf.conf
  echo 'defaultyes=True'           | sudo tee -a /etc/dnf/dnf.conf
  }
echo "DNF configuration updated."

## ── RPM FUSION ────────────────────────────────────────────────────────────
echo "Checking RPM Fusion repos..."

if ! is_installed_dnf "rpmfusion-free-release"; then
    echo "Enabling RPM Fusion Free..."
    sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
else
    echo "[SKIP] RPM Fusion Free is already installed."
fi

if ! is_installed_dnf "rpmfusion-nonfree-release"; then
    echo "Enabling RPM Fusion Non-Free..."
    sudo dnf install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
else
    echo "[SKIP] RPM Fusion Non-Free is already installed."
fi

## ── Enable additional Repos ───────────────────────────────────────────────
echo "Checking additional COPR repos..."
enable_copr_if_needed "lionheartp/Hyprland"
enable_copr_if_needed "theblackdon/kineticwe"
enable_copr_if_needed "linuxgamerlife/lgl-system-loadout"

## ── Virtualization ────────────────────────────────────────────────────────
if ! command -v virt-manager &> /dev/null; then
    echo "virt-manager not found. Installing virtualization environment..."
    sudo dnf install -y @virtualization
    sudo systemctl enable libvirtd --now
    sudo usermod -aG libvirt "$USER"
    echo "Done! Remember to log out and back in for the 'libvirt' group membership to take effect."
else
    echo "virt-manager is already installed. Skipping installation."
fi

## ── Custom performance kernel (CachyOS) ───────────────────────────────────
echo -e "\n---> CachyOS Kernel with addons"

# Check if CachyOS kernel is already installed
if rpm -q kernel-cachyos &>/dev/null; then
    echo "[INFO] CachyOS Kernel is already installed. Skipping..."
else
    if [ "$ENABLE_CACHYOS_PROMPT" = true ]; then
        read -p "Install CachyOS Kernel and Performance Schedulers? (y/N): " choice_cachy
        [[ "$choice_cachy" =~ ^[Yy]$ ]] && INSTALL_CACHYOS_KERNEL=true || INSTALL_CACHYOS_KERNEL=false
    fi

    if [ "$INSTALL_CACHYOS_KERNEL" = true ]; then
        dnf copr enable -y bieszczaders/kernel-cachyos || handle_error "CachyOS kernel COPR"
        dnf copr enable -y bieszczaders/kernel-cachyos-addons || handle_error "CachyOS addons COPR"
        dnf install -y --skip-broken kernel-cachyos kernel-cachyos-devel-matched libdnf5-plugin-actions || handle_error "CachyOS kernel"
      
        mkdir -p /etc/dnf/libdnf5-plugins/actions.d
        cat << 'EOF' > /etc/dnf/libdnf5-plugins/actions.d/cachy-default.actions
# Set the latest CachyOS kernel as the default boot entry
post_transaction:kernel*:in::/usr/bin/sh -c "/usr/bin/grubby --set-default=/boot/\$(ls /boot | grep vmlinuz.*cachy | sort -V | tail -1)"
EOF

        dnf swap -y zram-generator-defaults cachyos-settings || handle_error "swapping cachyos-settings"
        dracut -f || handle_error "dracut regeneration"
    else
        echo "[INFO] Skipping CachyOS Kernel"
    fi
fi

## ── User Apps  ────────────────────────────────────────────────────────────
echo -e "\n---> User Applications "

# --------- Group 1: Core Apps ---------
echo -e "\n--- Group 1: Core Apps (dolphin, kitty, flatpak, zed, Brave, Bazaar) ---"
read -p "Install ALL Core Apps? (y/N): " install_all_group1
if [[ "${install_all_group1:-}" =~ ^[Yy]$ ]]; then
    flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    flatpak update --user -y
    flatpak install --user -y flathub com.github.tchx84.Flatseal || warn "Flatseal install failed"
    flatpak install --user -y flathub dev.zed.Zed      || warn "Zed install failed"
    flatpak install --user -y flathub io.github.kolunmi.Bazaar || warn "Bazaar install failed"
    sudo dnf install -y dnf-plugins-core
    sudo dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-nightly.s3.brave.com/brave-browser-nightly.repo
    sudo dnf install -y dolphin kitty flatpak brave-origin-nightly || warn "Group 1 dnf packages failed"
fi

# --------- Group 2: Utility Apps ---------
echo -e "\n--- Group 2: Utility Apps ---"
group2_packages=("mpv" "loupe" "gnome-calculator" "qbittorrent" "kde-partitionmanager" "yazi" "fastfetch" "zsh" "rsync" "duf" "btop" "tldr" "htop" "distrobox" "starship")
read -p "Install ALL utility apps? (y/N): " install_all_group2

if [[ "${install_all_group2:-}" =~ ^[Yy]$ ]]; then
    sudo dnf copr enable -y lihaohong/yazi
    sudo dnf copr enable -y atim/starship
    sudo dnf install -y --skip-broken "${group2_packages[@]}" || warn "Utility Apps Installation failed"
else
    for PKG in "${group2_packages[@]}"; do
        is_installed_dnf "$PKG" && { echo "[SKIP] $PKG (already installed)"; continue; }
        read -p "Install $PKG? [y/N]: " c
        if [[ "${c:-}" =~ ^[Yy]$ ]]; then
            case "$PKG" in
                yazi) enable_copr_if_needed "lihaohong/yazi" ;;
                starship) enable_copr_if_needed "atim/starship" ;;
            esac
            sudo dnf install -y "$PKG" || warn "$PKG install failed"
        else
            echo "[SKIP] $PKG"
        fi
    done
fi

# --------- Group 3: Gaming Apps ---------
echo -e "\n--- Group 3: Gaming Apps ---"
group3_packages=("lact" "steam" "mangohud" "gamescope" "protontricks" "protonplus" "goverlay")
read -p "Install ALL Gaming apps? (y/N): " install_all_group3

if [[ "${install_all_group3:-}" =~ ^[Yy]$ ]]; then
    sudo dnf copr enable -y ilyaz/LACT
    sudo dnf copr enable -y wehagy/protonplus
    sudo dnf install -y --skip-broken "${group3_packages[@]}" || warn "Gaming Apps Installation failed"
else
    for PKG in "${group3_packages[@]}"; do
        is_installed_dnf "$PKG" && { echo "[SKIP] $PKG (already installed)"; continue; }
        read -p "Install $PKG? [y/N]: " c
        if [[ "${c:-}" =~ ^[Yy]$ ]]; then
            [[ "$PKG" == "protonplus" ]] && enable_copr_if_needed "wehagy/protonplus"
            [[ "$PKG" == "lact" ]] && enable_copr_if_needed "ilyaz/LACT"
            sudo dnf install -y "$PKG" || warn "$PKG install failed"
        else
            echo "[SKIP] $PKG"
        fi
    done
fi

# Apply Starship preset if installed
if command -v starship &>/dev/null; then
    echo "Applying Starship preset (gruvbox-rainbow)..."
    sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/.config"
    sudo -u "$TARGET_USER" starship preset gruvbox-rainbow -o "$TARGET_HOME/.config/starship.toml" || \
        warn "Could not apply Starship preset"
fi

# Firefox removal if Brave installed
if is_installed_dnf "brave-origin-nightly"; then
    if is_installed_dnf "firefox"; then
        read -p "Remove Firefox? [y/N]: " c
        [[ "${c:-}" =~ ^[Yy]$ ]] && sudo dnf remove -y firefox || warn "Could not remove Firefox"
    fi
fi

## ===== Full system update =====
echo -e "\nFull system update "
sudo dnf upgrade --refresh -y || warn "System upgrade encountered errors"
sudo dnf distro-sync -y || warn "Distro-sync encountered errors"

# ===================================================
# Final messages & reboot
# ===================================================
echo -e "\n==================================================="
echo " INSTALLATION COMPLETE "
echo "==================================================="
echo "MANUAL CONFIGURATIONS REQUIRED"
echo "---------------------------------------------------"
echo " 1. "If starting the desktop from TTY, use: start-kineticwe"
echo " 2. For Noctalia, enable Polkit in Security settings."
echo ""
echo " 3. In KDE System Settings go to search section:"
echo "    - Disable File Search, Plasma Search, and KRunner History."
echo "==================================================="

echo -e "\nSystem changes require a reboot to take effect."

if $AUTO_REBOOT; then
    echo "[INFO] Auto-reboot selected. Rebooting in 5 seconds..."
    sleep 5
    sudo reboot
else
    read -p "Would you like to reboot the system now? " do_reboot
    if [[ "${do_reboot:-}" =~ ^[Yy]$ ]]; then
        echo "Rebooting system..."
        sudo reboot
    else
        echo "Reboot cancelled. Please remember to manually run 'sudo reboot' later."
    fi
fi
