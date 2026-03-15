#!/usr/bin/env bash
#
# UGREEN NAS (UGOS) Setup Script
#
# Installs CLI tools and dotfiles on a UGREEN NAS running UGOS.
# Designed to be re-run after firmware updates, which reset /etc/passwd
# and may undo other system-level changes.
#
# Usage (private repo — will prompt for GitHub password/token):
#   curl -fsSL -u YOUR_GITHUB_USERNAME \
#        https://raw.githubusercontent.com/anuanandpremji/dots-ugos/main/setup.sh \
#        | bash
#
# What it does:
#   1. Fixes home directory in /etc/passwd (UGOS defaults to non-existent /home/<user>)
#   2. Installs system packages (git, curl, wget, build-essential, tree, unzip)
#   3. Installs CLI tools (fzf, fd, bat, ripgrep, eza, delta, micro)
#   4. Downloads dotfiles (as zip) and creates symlinks
#
# Idempotent — safe to re-run at any time.
# Requires: bash, curl, sudo access
# Must NOT be run as root.

set -euo pipefail

# ============================================================
# Configuration
# ============================================================
VOLUME="/volume2"
NAS_HOME="$VOLUME/home/$(whoami)"
DOTS_REPO="anuanandpremji/dots"

# ============================================================
# Colors & Logging
# ============================================================
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
    GREEN='' YELLOW='' RED='' BLUE='' BOLD='' NC=''
fi

log_info()    { printf "${GREEN}[INFO]${NC}    %s\n" "$1"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}    %s\n" "$1"; }
log_error()   { printf "${RED}[ERROR]${NC}   %s\n" "$1" >&2; }
log_section() { printf "\n${BOLD}${BLUE}── %s ──${NC}\n" "$1"; }
log_skip()    { printf "${YELLOW}[SKIP]${NC}    %s\n" "$1"; }

is_installed() {
    command -v "$1" &>/dev/null || [[ -x "$HOME/.local/bin/$1" ]]
}

# ============================================================
# Preflight
# ============================================================
if [[ "$(id -u)" -eq 0 ]]; then
    log_error "Do not run this script as root. It will use sudo when needed."
    exit 1
fi

if ! command -v curl &>/dev/null; then
    log_error "Required command not found: curl"
    exit 1
fi

# ============================================================
# Architecture Detection
# ============================================================
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)        DEB_ARCH="amd64" ;;
    aarch64|arm64) DEB_ARCH="arm64" ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# ============================================================
# GitHub Release Helpers
# ============================================================
gh_latest_url() {
    local repo="$1" pattern="$2"
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
        | grep "browser_download_url" \
        | grep -E "$pattern" \
        | head -1 \
        | sed 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/'
}

gh_install_deb() {
    local repo="$1" pattern="$2" name="$3"
    local tmp url

    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    url=$(gh_latest_url "$repo" "$pattern")
    if [[ -z "$url" ]]; then
        log_error "Could not find $name download URL (GitHub API rate limit?)"
        return 1
    fi
    log_info "Downloading $name from $url"
    curl -fsSL -o "$tmp/pkg.deb" "$url"
    sudo dpkg -i "$tmp/pkg.deb" || sudo apt-get install -f -y
}

# ============================================================
# Step 1: Fix Home Directory
# ============================================================
fix_home_directory() {
    log_section "Home directory"

    local current_home
    current_home=$(grep "^$(whoami):" /etc/passwd | cut -d: -f6)

    if [[ "$current_home" == "$NAS_HOME" ]]; then
        log_skip "Home directory already points to $NAS_HOME"
    else
        log_info "Updating /etc/passwd: $current_home -> $NAS_HOME"
        sudo sed -i "s|:${current_home}:|:${NAS_HOME}:|" /etc/passwd
    fi

    export HOME="$NAS_HOME"
    export PATH="$HOME/.local/bin:$PATH"

    # Create directory structure (idempotent — mkdir -p is a no-op if exists)
    mkdir -p "$HOME"/{.config,.local/bin,.local/share,private}

    log_info "HOME=$HOME"
}

# ============================================================
# Step 2: System Packages
# ============================================================
install_system_packages() {
    log_section "System packages"
    sudo apt-get update -qq
    sudo apt-get install -y git curl wget build-essential software-properties-common tree unzip
}

# ============================================================
# Step 3: CLI Tools
# ============================================================
install_fzf() {
    log_section "fzf"
    if is_installed fzf; then
        log_skip "fzf"
        return
    fi

    local tmp url
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN
    url=$(gh_latest_url "junegunn/fzf" "linux_${DEB_ARCH}\\.tar\\.gz")
    if [[ -z "$url" ]]; then
        log_error "Could not find fzf download URL (GitHub API rate limit?)"
        return 1
    fi
    log_info "Downloading fzf from $url"
    curl -fsSL -o "$tmp/fzf.tar.gz" "$url"
    tar -xzf "$tmp/fzf.tar.gz" -C "$tmp"
    mv "$tmp/fzf" "$HOME/.local/bin/fzf"
    chmod +x "$HOME/.local/bin/fzf"
    log_info "fzf installed to ~/.local/bin/fzf"
}

install_fd() {
    log_section "fd"
    if is_installed fd || is_installed fdfind; then
        if is_installed fdfind && ! is_installed fd; then
            log_info "fdfind found — creating fd symlink"
            ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
        else
            log_skip "fd"
        fi
        return
    fi

    gh_install_deb "sharkdp/fd" "${DEB_ARCH}\\.deb" "fd"
    if is_installed fdfind && ! is_installed fd; then
        ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    fi
}

install_bat() {
    log_section "bat"
    if is_installed bat || is_installed batcat; then
        if is_installed batcat && ! is_installed bat; then
            log_info "batcat found — creating bat symlink"
            ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
        else
            log_skip "bat"
        fi
        return
    fi

    gh_install_deb "sharkdp/bat" "bat_[^/]*_${DEB_ARCH}\\.deb" "bat"
    if is_installed batcat && ! is_installed bat; then
        ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
    fi
}

install_ripgrep() {
    log_section "ripgrep"
    if is_installed rg; then
        log_skip "ripgrep"
        return
    fi
    gh_install_deb "BurntSushi/ripgrep" "${DEB_ARCH}\\.deb" "ripgrep"
}

install_eza() {
    log_section "eza"
    if is_installed eza; then
        log_skip "eza"
        return
    fi

    if [[ ! -f /etc/apt/keyrings/gierens.gpg ]]; then
        log_info "Adding eza apt repository..."
        sudo mkdir -p /etc/apt/keyrings
        wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
            | sudo gpg --yes --dearmor -o /etc/apt/keyrings/gierens.gpg
        echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
            | sudo tee /etc/apt/sources.list.d/gierens.list
        sudo apt-get update -qq
    fi
    sudo apt-get install -y eza
}

install_delta() {
    log_section "delta"
    if is_installed delta; then
        log_skip "delta"
        return
    fi
    gh_install_deb "dandavison/delta" "${DEB_ARCH}\\.deb" "delta"
}

install_micro() {
    log_section "micro"
    if is_installed micro; then
        log_skip "micro"
        return
    fi

    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN
    log_info "Installing micro from official installer..."
    bash -c "cd '$tmp' && curl -fsSL https://getmic.ro | bash"
    mv "$tmp/micro" "$HOME/.local/bin/micro"
    chmod +x "$HOME/.local/bin/micro"
    log_info "micro installed to ~/.local/bin/micro"
}

# ============================================================
# Step 4: Dotfiles
# ============================================================
download_dotfiles() {
    log_section "Dotfiles"

    local dest="$HOME/private/dots"

    if [[ -d "$dest" && -f "$dest/.config/shell/scripts/setup-symlinks" ]]; then
        log_skip "Dotfiles already present at $dest"
        DOTFILES="$dest"
        return
    fi

    log_info "Downloading dotfiles zip from GitHub..."
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN
    curl -fsSL -o "$tmp/dotfiles.zip" \
        "https://github.com/$DOTS_REPO/archive/refs/heads/main.zip"
    unzip -q "$tmp/dotfiles.zip" -d "$tmp"
    mkdir -p "$dest"
    cp -a "$tmp"/dots-main/. "$dest"/
    log_info "Extracted to $dest"

    DOTFILES="$dest"
}

# ============================================================
# Step 5: Symlinks
# ============================================================
setup_symlinks() {
    log_section "Symlinks"

    local link_pairs=(
        # target                                            link
        "$DOTFILES/.config/shell/bash/.bashrc"              "$HOME/.bashrc"
        "$DOTFILES/.config/git/config"                      "$HOME/.config/git/config"
        "$DOTFILES/.config/micro/init.lua"                  "$HOME/.config/micro/init.lua"
        "$DOTFILES/.config/micro/bindings.json"             "$HOME/.config/micro/bindings.json"
        "$DOTFILES/.config/micro/settings.json"             "$HOME/.config/micro/settings.json"
    )

    local i=0
    while [[ $i -lt ${#link_pairs[@]} ]]; do
        local target="${link_pairs[$i]}"
        local link="${link_pairs[$((i + 1))]}"
        i=$((i + 2))

        if [[ ! -e "$target" ]]; then
            log_warn "Target not found: $target"
            continue
        fi

        mkdir -p "$(dirname "$link")"

        if [[ -L "$link" ]]; then
            local current
            current=$(readlink "$link")
            if [[ "$current" == "$target" ]]; then
                log_skip "$(basename "$link")"
                continue
            fi
            rm -f "$link"
        elif [[ -e "$link" ]]; then
            mv "$link" "${link}.bak"
            log_warn "Backed up existing $(basename "$link") to ${link}.bak"
        fi

        ln -s "$target" "$link"
        log_info "$(basename "$link") -> $target"
    done
}

# ============================================================
# Main
# ============================================================
main() {
    printf "\n"
    printf "${BOLD}========================================${NC}\n"
    printf "${BOLD} UGREEN NAS Setup${NC}\n"
    printf "${BOLD}========================================${NC}\n"
    printf " Volume:   %s\n" "$VOLUME"
    printf " User:     %s\n" "$(whoami)"
    printf " Arch:     %s\n" "$ARCH"
    printf "${BOLD}========================================${NC}\n\n"

    fix_home_directory

    install_system_packages

    install_fzf
    install_fd
    install_bat
    install_ripgrep
    install_eza
    install_delta
    install_micro

    download_dotfiles
    setup_symlinks

    printf "\n"
    log_info "========================================"
    log_info "  Setup complete!"
    log_info "========================================"
    log_info ""
    log_info "  Restart your shell for changes to take effect."
    log_info ""
    log_info "  After a UGOS firmware update, re-run this script"
    log_info "  to restore /etc/passwd and any reset settings."
    printf "\n"
}

main "$@"
