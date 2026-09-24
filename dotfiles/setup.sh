#!/bin/bash
set -eE -o pipefail

trap 'echo "ERROR: setup.sh failed at line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR

DOTFILES="$HOME/dotfiles"
PKG_DIR="$DOTFILES/packages"
SHELL_PLUGIN_DIR="$HOME/.local/share/zsh/plugins"

# --- Pre-flight ---
[[ -f /etc/fedora-release ]] || { echo "Not Fedora. Aborting." >&2; exit 1; }
command -v sudo >/dev/null || { echo "sudo not found. Aborting." >&2; exit 1; }

for f in copr-repos.txt dnf-packages.txt flatpak-apps.txt mise-tools.txt; do
  [[ -f "$PKG_DIR/$f" ]] || { echo "Missing $PKG_DIR/$f. Aborting." >&2; exit 1; }
done

mkdir -p "$SHELL_PLUGIN_DIR" "$HOME/.local/bin" "$HOME/.cache/zsh"

clone_or_update() {
  local url="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" pull --ff-only
  else
    git clone --depth=1 "$url" "$dest"
  fi
}

read_list() {
  grep -vE '^\s*(#|$)' "$1" || true
}

# --- 0. RPM Fusion ---
if ! rpm -q rpmfusion-free-release &>/dev/null; then
  sudo dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
fi

# --- 1. COPR repos ---
while read -r repo; do
  sudo dnf copr enable -y "$repo"
done < <(read_list "$PKG_DIR/copr-repos.txt")

# --- 2. dnf packages ---
mapfile -t DNF_PKGS < <(read_list "$PKG_DIR/dnf-packages.txt")
[[ ${#DNF_PKGS[@]} -gt 0 ]] && sudo dnf install -y "${DNF_PKGS[@]}"

# --- 3. Flatpak apps ---
mapfile -t FLATPAK_APPS < <(read_list "$PKG_DIR/flatpak-apps.txt")
if [[ ${#FLATPAK_APPS[@]} -gt 0 ]]; then
  flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo
  sudo flatpak install -y flathub "${FLATPAK_APPS[@]}"
fi

# --- 4. mise (official installer, no COPR) ---
if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# --- 5. mise tools ---
while read -r tool; do
  mise use -g "$tool"
done < <(read_list "$PKG_DIR/mise-tools.txt")

# --- 6. Unofficial Zsh plugins ---
clone_or_update \
  https://github.com/zsh-users/zsh-history-substring-search \
  "$SHELL_PLUGIN_DIR/zsh-history-substring-search"
clone_or_update \
  https://github.com/Aloxaf/fzf-tab \
  "$SHELL_PLUGIN_DIR/fzf-tab"
clone_or_update \
  https://github.com/zsh-users/zsh-completions \
  "$SHELL_PLUGIN_DIR/zsh-completions"

# --- 7. Starship (official installer, no sudo) ---
if ! command -v starship >/dev/null 2>&1; then
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
fi

# --- 8. yadm (direct script, no COPR/OBS) ---
if ! command -v yadm >/dev/null 2>&1; then
  curl -fsSL https://github.com/yadm-dev/yadm/raw/master/yadm \
    -o "$HOME/.local/bin/yadm"
  chmod +x "$HOME/.local/bin/yadm"
fi

# --- 9. Default shell ---
ZSH_BIN="$(command -v zsh)"
if [[ "$SHELL" != "$ZSH_BIN" ]]; then
  chsh -s "$ZSH_BIN"
fi

# --- 10. User scripts (symlink from ~/dotfiles/scripts to ~/.local/bin) ---
if [[ -d "$DOTFILES/scripts" ]]; then
  for script in "$DOTFILES/scripts"/*; do
    [[ -f "$script" ]] || continue
    ln -sf "$script" "$HOME/.local/bin/$(basename "$script")"
  done
fi

# --- 11. Freebuff container image (if Containerfile exists) ---
FREEBUFF_CF="$DOTFILES/containers/freebuff/Containerfile"
if [[ -f "$FREEBUFF_CF" ]] && ! podman image exists localhost/freebuff-image:latest; then
  podman build -t localhost/freebuff-image:latest -f "$FREEBUFF_CF" "$(dirname "$FREEBUFF_CF")"
fi

# --- 11b. dev-base image (if Containerfile exists) ---
DEV_BASE_CF="$DOTFILES/containers/dev-base/Containerfile"
if [[ -f "$DEV_BASE_CF" ]] && ! podman image exists localhost/dev-base:latest; then
  podman build -t localhost/dev-base:latest -f "$DEV_BASE_CF" "$(dirname "$DEV_BASE_CF")"
fi
