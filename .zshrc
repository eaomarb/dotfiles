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

# --- Base keybindings ---
bindkey -e
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line

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
