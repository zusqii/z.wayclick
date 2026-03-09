# WayClick

## File Placement

```bash
mkdir -p ~/.scripts/wayclick
cp .scripts/wayclick/*.sh ~/.scripts/wayclick/
chmod +x ~/.scripts/wayclick/*.sh

mkdir -p ~/.config/wayclick/audio_pack_1
cp .config/wayclick/config.json ~/.config/wayclick/
cp .config/wayclick/audio_pack_1/*.wav ~/.config/wayclick/audio_pack_1/
```

## One-Time Setup

**1. Add yourself to the `input` group:**
```bash
sudo usermod -aG input $USER
```
Log out and back in for the change to take effect.

**2. Run first-time setup** (installs deps, compiles native extensions — ~1-2 min):
```bash
~/.scripts/wayclick/wayclick.sh --setup
```

## Usage

| Command | Effect |
|---|---|
| `~/.scripts/wayclick/wayclick.sh` | Toggle on/off |
| `~/.scripts/wayclick/wayclick.sh --setup` | Install/build only |
| `~/.scripts/wayclick/wayclick.sh --reset` | Stop + delete venv |
| `~/.scripts/wayclick/wayclick_tui.sh` | Open TUI configurator |
| `~/.scripts/wayclick/detect_hardware.sh` | Show which devices will play sounds |

## Audio

The script auto-detects PipeWire/PulseAudio/ALSA. On a fresh Arch install with no audio, run `--setup` first — it will install PipeWire automatically.

## Autostart (Hyprland)

```
exec-once = ~/.scripts/wayclick/wayclick.sh
```

## Keybind Toggle (Hyprland)

```
bind = $mainMod, F9, exec, ~/.scripts/wayclick/wayclick.sh
```
