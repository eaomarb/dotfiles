# ============================================================
# ~/.zshrc — pure Zsh, no framework
# ============================================================

# --- History ---
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt EXTENDED_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY

# --- General options ---
setopt AUTO_CD
setopt AUTO_PUSHD
setopt PUSHD_IGNORE_DUPS
setopt INTERACTIVE_COMMENTS
setopt NO_BEEP

# --- Environment ---
export EDITOR="nano"
export VISUAL="$EDITOR"
export PATH="$HOME/.local/bin:$PATH"

# --- Plugin paths ---
ZSH_PLUGINS="$HOME/.local/share/zsh/plugins"

# --- fpath for zsh-completions (must be before compinit) ---
fpath=("$ZSH_PLUGINS/zsh-completions/src" $fpath)

# --- Cache for compinit ---
[[ -d "$HOME/.cache/zsh" ]] || mkdir -p "$HOME/.cache/zsh"

# --- Completion ---
autoload -Uz compinit
compinit -d "$HOME/.cache/zsh/zcompdump"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list \
  'm:{a-zA-Z}={A-Za-z}' \
  'r:|[._-]=* r:|=*' \
  'l:|=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# --- Official plugins (dnf, /usr/share) ---
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# --- Unofficial plugins (cloned by setup.sh) ---
source "$ZSH_PLUGINS/zsh-history-substring-search/zsh-history-substring-search.zsh"
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# fzf: keybindings + completion (dnf package) — before fzf-tab
[[ -f /usr/share/fzf/shell/key-bindings.zsh ]] && \
  source /usr/share/fzf/shell/key-bindings.zsh
[[ -f /usr/share/fzf/shell/completion.zsh ]] && \
  source /usr/share/fzf/shell/completion.zsh

# fzf-tab: must load after compinit
source "$ZSH_PLUGINS/fzf-tab/fzf-tab.plugin.zsh"
zstyle ':fzf-tab:*' fzf-flags --height=50%

# syntax-highlighting: ALWAYS last among plugins
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# --- Automatic keybindings based on terminfo ---

# Ensure Emacs keymap is active (the standard)
bindkey -e

# Helper function to avoid repeating logic in .zshrc
function _bindkey_from_terminfo() {
  # $1 = terminfo capability name (e.g. kcuu1)
  # $2 = Zsh widget name to bind to (e.g. backward-word)
  local terminfo_code="${terminfo[$1]}"
  if [[ -n "$terminfo_code" ]]; then
    bindkey "$terminfo_code" "$2"
  fi
}

# --- Navigation keys ---
_bindkey_from_terminfo kcuu1  up-line-or-history         # Up arrow
_bindkey_from_terminfo kcud1  down-line-or-history       # Down arrow
_bindkey_from_terminfo kcub1  backward-char              # Left arrow
_bindkey_from_terminfo kcuf1  forward-char               # Right arrow

# --- Home and End ---
_bindkey_from_terminfo khome  beginning-of-line          # Home
_bindkey_from_terminfo kend   end-of-line                # End

# --- Delete ---
_bindkey_from_terminfo kdch1  delete-char                # Delete key

# --- Word navigation (Alt or Ctrl + arrows) ---
# Alt + Left/Right
_bindkey_from_terminfo kLFT   backward-word              # Alt + Left
_bindkey_from_terminfo kRIT   forward-word               # Alt + Right

# Note: Ctrl + arrows sometimes has no standard terminfo capability.
# If it doesn't work, it can be added manually, but Alt is usually enough.
# For Ctrl + arrows, uncomment and adjust if needed:
# bindkey "^[[1;5D" backward-word
# bindkey "^[[1;5C" forward-word

# --- Word navigation (Alt + B/F, universal) ---
# These are Emacs shortcuts that almost always work without extra config
bindkey "^[b" backward-word   # Alt + B
bindkey "^[f" forward-word    # Alt + F

# --- Word deletion ---
_bindkey_from_terminfo kDC    kill-word                  # Ctrl + Delete (if applicable)
_bindkey_from_terminfo kbs    backward-delete-char       # Backspace

# --- Tools with own init ---
eval "$(starship init zsh)"
eval "$(zoxide init zsh)"
eval "$(mise activate zsh)"

# --- Aliases ---
command -v lsd >/dev/null && {
  alias ls='lsd'
  alias ll='lsd -lh'
  alias la='lsd -lah'
  alias lt='lsd --tree'
}
command -v bat >/dev/null && {
  alias cat='bat --paging=never'
  alias catp='bat'
}
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -h'
alias mkdir='mkdir -p'

# --- Custom aliases ---
alias duc="docker compose up -d"
alias c="clear"
alias C="clear"
alias CD="cd"

# --- Optional local overrides (not tracked) ---
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
