# Dotfiles

GNOME Terminal, Zsh, and systemd-boot setup.

```bash
dconf load /org/gnome/terminal/ < gnome-terminal/profiles.dconf
cp shell/zshrc ~/.zshrc
sudo cp scripts/update-systemdboot.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/update-systemdboot.sh
sudo cp hooks/99-update-systemdboot.hook /etc/pacman.d/hooks/
