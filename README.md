# HostForge Community Edition

HostForge helps you install and manage a Mount & Blade II: Bannerlord dedicated
server on Ubuntu Linux.

This guide is written for someone who has never used Linux or Git before. Run
the commands below on your Linux server through PuTTY, not in Windows Command
Prompt or PowerShell.

## Before You Start

You need:

- an Ubuntu Linux server (Ubuntu 24.04 is recommended)
- the server's IP address
- the server's Linux username and password
- [PuTTY](https://www.putty.org/) on your Windows computer
- a [GitHub](https://github.com/) account

Important beginner notes:

- Run one command box at a time.
- In PuTTY, right-clicking usually pastes copied text.
- Linux passwords are invisible while you type or paste them. You will not see
  dots or stars. This is normal. Press Enter after entering the password.
- Do not share your Linux password, GitHub device code, or Bannerlord auth token.

## 1. Connect to the Linux Server with PuTTY

1. Open PuTTY on your Windows computer.
2. Enter your server's IP address in **Host Name (or IP address)**.
3. Keep **Port** set to `22`.
4. Select **SSH** as the connection type.
5. Click **Open**.
6. On the first connection, PuTTY may show a server host-key warning. Confirm
   the fingerprint with your server provider, then accept it.
7. At `login as:`, enter your Linux username and press Enter.
8. Enter your Linux password and press Enter. The password will be invisible.

You are now working inside the Linux server.

## 2. Install GitHub CLI

GitHub CLI is the `gh` command. The commands below are the official Debian and
Ubuntu installation method from
[GitHub's Linux installation guide](https://github.com/cli/cli/blob/trunk/docs/install_linux.md).

Copy the entire command box, paste it into PuTTY, and press Enter:

```bash
(type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
  && sudo apt update \
  && sudo apt install gh -y
```

If Linux asks for your password, enter the same Linux password used to connect
with PuTTY. The password will be invisible.

Check that GitHub CLI was installed:

```bash
gh --version
```

You should see a GitHub CLI version number.

## 3. Log In to GitHub

Start the login:

```bash
gh auth login
```

Use the arrow keys and Enter to choose these answers:

1. **Where do you use GitHub?** Choose `GitHub.com`.
2. **What is your preferred protocol for Git operations?** Choose `HTTPS`.
3. **Authenticate Git with your GitHub credentials?** Choose `Yes`.
4. **How would you like to authenticate GitHub CLI?** Choose
   `Login with a web browser`.

GitHub CLI will display a one-time device code. The code usually looks like
`ABCD-1234`.

1. Copy or write down the one-time code. Do not share it with anyone.
2. Leave PuTTY open. Do not try to open a web browser inside the Linux server.
3. On your normal Windows web browser, open
   [https://github.com/login/device](https://github.com/login/device).
4. Log in to the GitHub account you want to use.
5. Enter the one-time code shown in PuTTY.
6. Click **Continue**, then authorize GitHub CLI.
7. Return to PuTTY. The login should finish automatically; press Enter if PuTTY
   is still waiting.

Check that the login worked:

```bash
gh auth status
```

The result should say that you are logged in to `github.com` and using the
`https` Git protocol.

## 4. Download HostForge

Move to your Linux home directory:

```bash
cd ~
```

Clone this repository and name the downloaded folder `hostforge`:

```bash
git clone https://github.com/Sartiye/Hosforge-Bannerlord-Linux-Panel.git hostforge
```

Enter the new folder:

```bash
cd hostforge
```

Check that the files are present:

```bash
ls
```

You should see `setup.sh` and `hostforge.sh` in the list.

## 5. Install HostForge and Bannerlord

Start the installer:

```bash
./setup.sh
```

The installer downloads and configures the required Linux packages, SteamCMD,
Wine, the Bannerlord dedicated server, HostForge services, and the web panel.
This can take a while. Keep PuTTY open and let the installer finish.

During setup:

- Answer the questions shown in PuTTY.
- Press Enter at the HostForge web-password question to use the default password
  `admin123`, or type a different password.
- The Bannerlord dedicated-server auth token is optional during the first setup.
  Press Enter to skip it if you do not have one yet. You can add it later from
  the HostForge menu.

## 6. Open the HostForge Menu

After setup finishes, run:

```bash
./hostforge.sh
```

The HostForge menu will appear. Type a menu number and press Enter to select an
action.

## Opening HostForge Again Later

Reconnect to the server with PuTTY, then run:

```bash
cd ~/hostforge
./hostforge.sh
```

## Common Problems

### `Permission denied` when running a script

Run:

```bash
chmod +x setup.sh hostforge.sh
```

Then try the command again.

### `gh: command not found`

GitHub CLI was not installed successfully. Repeat **Step 2** and look for an
error message.

### `fatal: destination path 'hostforge' already exists`

The `hostforge` folder already exists. Do not clone it again. Enter it with:

```bash
cd ~/hostforge
```

### PuTTY disconnected

Reconnect with PuTTY. If the installation did not finish, return to the folder
and run setup again:

```bash
cd ~/hostforge
./setup.sh
```

The installer is designed to be run again when needed.

## More Information

See [OPERATIONS.md](OPERATIONS.md) for the complete HostForge operations and
configuration reference.
