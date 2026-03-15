# dots-ugos

Setup script for UGREEN NAS devices running UGOS. Installs CLI tools and dotfiles — tailored for an environment that actively resists being customized.

## Why does this exist?

UGOS is not a general-purpose Linux distribution. It's an appliance OS built on Debian with an overlay filesystem, designed to be firmware-updatable, factory-resettable, and difficult to brick. Noble goals. Unfortunately, this also means it fights you at every turn if you want to do anything beyond what the web UI offers.

The main [dots](https://github.com/anuanandpremji/dots) setup script targets workstations (Ubuntu, Fedora, macOS). This repo exists because the NAS has enough quirks that shoehorning workarounds into the main script would make it worse for every other machine.

For more UGOS workarounds (SSH key persistence, port reclaiming, Tailscale integration), see [ln-12/UGOS_scripts](https://github.com/ln-12/UGOS_scripts) — an excellent collection of systemd-based fixes for UGOS's more aggressive behaviors.

## UGOS Quirks

A field guide to the things that will make you question your life choices.

### The phantom home directory

Your user exists. Your home directory does not.

```
$ echo $HOME
/home/Zuko
$ ls /home/Zuko
ls: cannot access '/home/Zuko': No such file or directory
```

`/home` lives on a read-only overlay backed by the eMMC system partition. You cannot `mkdir`, `ln -s`, or even `sudo` your way into creating anything there. User data is meant to live on the storage volumes (`/volume1`, `/volume2`, etc.), but nobody told `/etc/passwd`.

To make things worse, the home directory may not even exist at boot — [UGOS appears to create or mount it asynchronously](https://github.com/ln-12/UGOS_scripts), so services that depend on it need to poll and wait.

### SSH ignores `$HOME`

You might think `export HOME=/volume2/home/me` solves everything. SSH disagrees. OpenSSH reads the home directory from `/etc/passwd`, not the `$HOME` environment variable. So even with `$HOME` set correctly:

```
$ ssh -T github-private
ssh: Could not resolve hostname github-private: Name or service not known
```

Your `~/.ssh/config` with the `Host github-private` alias is sitting right there. SSH just refuses to look at it because it's checking `/home/Zuko/.ssh/config`, which doesn't exist.

The fix: `sudo sed -i 's|/home/Zuko|/volume2/home/Zuko|' /etc/passwd`

### UGOS actively fights your permissions

UGOS doesn't just ignore your config — it actively rewrites it. Permissions on the home directory, `~/.ssh/`, and `~/.ssh/authorized_keys` get reset by UGOS on reboot and whenever you change settings through the web UI. This breaks SSH public key authentication, which requires strict permissions (`700` on `.ssh`, `600` on `authorized_keys`).

If you need SSH key auth to survive reboots, you'll need a systemd service that watches for permission changes via `inotifywait` and immediately re-fixes them. See [ln-12/UGOS_scripts](https://github.com/ln-12/UGOS_scripts) for a working implementation.

### The overlay giveth, the overlay taketh away

That `/etc/passwd` fix? A UGOS firmware update will probably revert it. The overlay filesystem is designed so that the base system image can be cleanly replaced. Your changes to `/etc` sit on a writable layer that may or may not survive an update.

This is actually the safety net — if you break something in `/etc`, a firmware update or factory reset brings it back. But it means any system-level customization needs to be re-applied.

UGOS also aggressively rewrites config files it manages — including nginx configs and anything tied to the web UI. If you modify a UGOS-managed file, expect it to be overwritten on the next reboot or settings change.

### Crontab is useless

Don't bother with `crontab -e`. UGOS overwrites the crontab on reboot. For anything that needs to run on a schedule or at boot, use systemd unit files in `/etc/systemd/system/` — these survive reboots (though possibly not firmware updates).

### No changing your shell

`chsh` doesn't work. PAM authentication fails, probably because UGOS restricts shell changes to prevent users from locking themselves out of a headless device with no keyboard or monitor attached. Fair enough.

```
$ chsh -s /usr/bin/zsh
chsh: PAM: Authentication failure
```

If you want zsh, the workaround is `exec zsh` in `.bashrc`. This script skips zsh entirely — bash works fine for a NAS.

### sudo mkdir? No.

Even with sudo, you cannot create directories on the read-only overlay:

```
$ sudo mkdir -p /home/Zuko
mkdir: cannot create directory '/home/Zuko': Operation not permitted
$ sudo ln -s /volume2/home/Zuko /home/Zuko
ln: failed to create symbolic link '/home/Zuko': Operation not permitted
```

### Tailscale DNS conflict

If you're running Tailscale on the NAS (via Docker or natively), be aware that Tailscale overwrites `/etc/resolv.conf` by default, which breaks all DNS resolution for the NAS. Start it with:

```
sudo tailscale up --accept-dns=false
```

### Docker is fine (mostly)

If you're worried about the `/etc/passwd` home directory change breaking Docker containers — don't be. Containers have their own `/etc/passwd` internally, mount volumes by explicit path, and use UIDs (not home directory paths) for file permissions. Tailscale, Immich, and anything else in Docker won't notice.

One caveat: don't store your own docker-compose files in the UGOS-managed docker directory. Permissions there get overwritten by the system. Use a directory on your data volume instead (e.g., `/volume1/docker_compose/` or `/volume2/docker_compose/`).

### The persistence cheat sheet

| Method | Survives reboot? | Survives firmware update? | Notes |
|--------|:---:|:---:|-------|
| Files on `/volume1/`, `/volume2/` | Yes | Yes | This is where your data lives |
| Scripts in `/usr/local/bin/` | Yes | Unknown | |
| systemd units in `/etc/systemd/system/` | Yes | Unknown | The only way to run things at boot |
| Changes to `/etc/passwd` | Yes | Probably not | Re-run the setup script after updates |
| Crontab entries | **No** | No | UGOS overwrites crontab on reboot |
| Home directory permissions | **No** | No | UGOS resets them on reboot and settings changes |
| UGOS-managed configs (nginx, etc.) | **No** | No | Need `inotifywait` watchers to re-apply |

## Hardware context

This script was written for a UGREEN NAS with:

| Component | Details |
|-----------|---------|
| volume1 | 3.6 TB RAID1 — two HDDs (`sda` + `sdb`) |
| volume2 | 450 GB RAID1 — NVMe SSD (`nvme0n1`) |
| System | 29 GB eMMC (`mmcblk0`) — overlay root |
| OS | UGOS (Debian Bookworm base) |

The home directory is placed on `volume2` (SSD) for speed. Adjust the `VOLUME` variable at the top of the script if your setup differs.

## What gets installed

### System packages (apt)

`git` `curl` `wget` `build-essential` `software-properties-common` `tree` `unzip`

### CLI tools (latest from GitHub releases)

| Tool | What it does |
|------|-------------|
| [fzf](https://github.com/junegunn/fzf) | Fuzzy finder |
| [fd](https://github.com/sharkdp/fd) | Fast file finder (better `find`) |
| [bat](https://github.com/sharkdp/bat) | Cat with syntax highlighting |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | Fast grep |
| [eza](https://github.com/eza-community/eza) | Modern ls |
| [delta](https://github.com/dandavison/delta) | Better git diffs |
| [micro](https://micro-editor.github.io/) | Terminal text editor |

### Not installed (and why)

- **zsh** — `chsh` doesn't work on UGOS, and adding shell-switching hacks to `.bashrc` isn't worth it for a NAS
- **neovim** — AppImage support is unreliable on the overlay filesystem; micro is sufficient for NAS-level editing
- **GUI apps** — It's a NAS
- **Fonts** — They render on the local terminal you SSH from, not on the NAS
- **SSH keys** — UGOS resets `~/.ssh` permissions on reboot and settings changes, breaking key auth without a systemd watcher

### Dotfiles

Downloaded as a zip from [anuanandpremji/dots](https://github.com/anuanandpremji/dots) (no git clone — the repo is not maintained on the NAS). Symlinks are created for:

- `~/.bashrc` — shell configuration
- `~/.config/git/config` — git settings
- `~/.config/micro/*` — micro editor settings

## Usage

### First run (private repo — will prompt for GitHub token)

```bash
curl -fsSL -u YOUR_GITHUB_USERNAME \
     https://raw.githubusercontent.com/anuanandpremji/dots-ugos/main/setup.sh \
     | bash
```

When prompted for a password, use a [GitHub personal access token](https://github.com/settings/tokens) (classic, with `repo` scope).

### After a firmware update

Same command. The script is idempotent — it skips what's already installed and re-applies what got reset (like the `/etc/passwd` home directory fix).

### Cleanup (nuclear option)

If you want to start fresh:

```bash
rm -rf ~/private/dots ~/.bashrc ~/.config/git/config ~/.config/micro/{init.lua,bindings.json,settings.json} ~/.local/bin/{fzf,fd,micro} && sudo apt remove --purge -y bat fd-musl ripgrep eza git-delta-musl 2>/dev/null; sudo apt autoremove -y
```

## See also

- [ln-12/UGOS_scripts](https://github.com/ln-12/UGOS_scripts) — systemd services for SSH key persistence, port reclaiming, and other UGOS workarounds
- [anuanandpremji/dots](https://github.com/anuanandpremji/dots) — the main dotfiles repo (for workstations)
