# HostForge Community Operations

HostForge Community Edition is a lightweight Linux SSH toolkit for running Mount & Blade II: Bannerlord dedicated server profiles under Wine with systemd, a small private web control plane, collector logs, Cloudflare quick tunnels, and optional firewall traffic controls.

## Setup

Run setup on the Linux host:

```bash
bash setup.sh
```

Setup installs the Bannerlord dedicated runtime prerequisites, SteamCMD content, Wine, Xvfb, the HostForge collector website, and systemd service templates. It does not install a backend service or MongoDB.

## HostForge Module

Community Edition can ship the published HostForge module under:

```text
module-hostforge/
```

Use the terminal or website repo-maintenance page to sync it into:

```text
<Bannerlord server>/Modules/MBWarlords.HostForge
```

`Update HostForge module` pulls this HostForge repository, then syncs the bundled module folder into the server.

The repo-maintenance page can also track custom Git-backed modules. Entries are
stored in:

```text
configs/custom-mods.tsv
```

Each custom mod entry has:

- Git repo directory
- Module directory, absolute or relative to the Git repo directory
- Module name, used as the target folder under `<Bannerlord server>/Modules/`

Custom mod editing is delete and re-add in v1. Deleting an entry does not remove
the Git repo or installed game files.

## Profiles

Profiles are plain text files under `configs/`:

```text
configs/ds_params_<profile>.txt
configs/ds_config_<profile>.txt
configs/bannerlord-path-server.txt
```

Community Edition ships with an empty `configs/` directory. You can create and
edit profile pairs from the private website at `/profiles/`, or edit the files
directly over SSH. Then run:

```bash
bash hostforge.sh
```

Use the terminal menu or web UI to inspect, activate, deactivate, restart, edit,
delete, and view logs for profiles. Deleting profile files from the website is
blocked while that profile service is active.

## Services

Installed HostForge units:

```text
hostforge@<profile>.service
hostforge-collector.service
hostforge-firewall.service
hostforge-cloudflared-quick.service
```

The collector website defaults to port `8080`.

## Website

The website exposes:

- dashboard and profile controls
- profile logs and collector logs
- firewall tracking, blacklist, and geo country blocks
- repo maintenance for HostForge and an optional module repo
- crash dump downloads

Setup prompts for the shared web password used by the private HostForge website,
including when it is exposed through Cloudflared. Press Enter to keep the existing
password on reruns, or to use the first-install default:

```text
HF_WEB_PASSWORD=admin123
```

You can also preseed it for unattended setup:

```bash
HF_WEB_PASSWORD='change-me' bash setup.sh
```

## Firewall

The firewall manager can:

- track player IP traffic on discovered Bannerlord profile ports
- blacklist individual IPs
- clear the blacklist
- maintain geo country block files under `configs/firewall-geo/`
- load country CIDR files into one `ipset hash:net`

Geo country blocks apply only to Bannerlord profile ports.

## Repo Maintenance

Community Edition keeps repo maintenance minimal:

- update HostForge
- pull an optional sibling module repo
- sync module folders into the Bannerlord dedicated server install

The default sibling module repo path is:

```text
../The-Last-Concord
```

Override it with `HF_LASTCONCORD_DIR` in `configs/hostforge.env` if needed.
