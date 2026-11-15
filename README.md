# lockoutserver

Launch and manage Fabric Minecraft servers on AWS EC2 from the command line. A server's mod set (Lockout, Shared Health, …) is picked at launch from a **profile**, and everything else, from the instance type to the world seed, is a launch flag.

```bash
bin/mc launch --profile lockout --name friday --seed 12345
```

The command creates the instance, installs Java, Fabric and the mods, starts the server and prints the IP to connect to.

## Repo Structure

```
lockoutserver/
├── bin/
│   ├── mc               # the CLI (runs on your machine)
│   └── lib/             # config.sh → render.sh → aws.sh, plus commands.sh
├── profiles/            # one KEY=value file per mod set
│   ├── lockout.conf
│   └── sharedhealth.conf
├── mods/
│   ├── 1.21.11/         # jars, grouped by Minecraft version
│   └── 26.2/
├── server/              # runs on the instance, works with any profile
│   ├── setup.sh         # first-boot install
│   ├── common.sh        # shared helpers
│   ├── start.sh
│   ├── stop.sh
│   └── newworld.sh
└── .env.example         # copy to .env
```

---

## Setup (once)

1. **Install the AWS CLI v2** and sign in. A named profile is easiest:
   ```bash
   aws configure --profile mc
   ```
   On Windows, run `bin/mc` from **Git Bash**.
2. **Create your `.env`:**
   ```bash
   cp .env.example .env
   ```
   Set `AWS_PROFILE` (e.g. `mc`), `AWS_REGION`, and your Minecraft username in `OPS`. `.env` is gitignored.

The SSH key pair is created on first launch and saved to `KEY_PATH` (`~/.ssh/lockoutserver.pem` by default). If you launch in a new region later, the same key is imported there.

---

## Launching a Server

```bash
bin/mc launch                                   # default profile from .env
bin/mc launch --profile sharedhealth --name hc  # another mod set
bin/mc launch --type m7i.large --view-distance 12 --motd "Friday Lockout"
bin/mc launch --prop pvp=false --prop spawn-protection=0
bin/mc launch --dry-run ...                     # show the resolved config, launch nothing
```

When it finishes (~5–8 minutes on first boot), you get:

```
friday is up (profile: lockout)
  Connect:   3.98.x.x  (port 25565)
  Ports:     tcp 25565, udp 24454
  SSH:       bin/mc ssh friday
  Console:   bin/mc console friday
  ...
```

Run `bin/mc launch --help` for every flag. In short:

| Area | Flags |
|---|---|
| Server | `--name`, `--profile`, `--mod JAR`, `--no-mod JAR`, `--ref REF` |
| Instance | `--region`, `--type`, `--disk GB`, `--spot`, `--elastic-ip` |
| World | `--seed`, `--gamemode`, `--difficulty`, `--hardcore`, `--max-players`, `--motd`, `--view-distance`, `--sim-distance`, `--level-type`, `--prop KEY=VALUE` |
| Players | `--ops "a,b"`, `--whitelist "a,b"` |
| Other | `--dry-run`, `--render-only` |

The server name defaults to the profile name, so a second server with the same profile needs `--name`.

### Where settings come from

From lowest to highest precedence:

**built-in defaults → `profiles/<profile>.conf` → `.env` → launch flags**

Each layer overrides the one before, except `PROPS` (server.properties), which **adds up**: the defaults set `view-distance=20;simulation-distance=10`, a profile adds e.g. `hardcore=true`, and `--prop` adds more. When a key appears twice, the last one wins.

---

## Managing a Server

| Action | Command |
|---|---|
| List servers | `bin/mc list` |
| SSH in | `bin/mc ssh <name>` |
| Attach to console | `bin/mc console <name>` (detach: `Ctrl + A` then `D`) |
| Follow setup log | `bin/mc logs <name>` (game log: `--game`) |
| New world | `bin/mc newworld <name>` |
| Download worlds | `bin/mc backup <name>` → `backups/` |
| Stop instance | `bin/mc stop <name>` (world is saved; disk still billed) |
| Start instance | `bin/mc start <name>` (prints the new IP) |
| Terminate everything | `bin/mc destroy <name>` |
| SSH from a new IP | `bin/mc allow-ip <name>` |

`<name>` can be left out when only one server exists (except for `destroy`). Every command takes `--region`.

### On the server

You have the same control as before. The server runs in the `mc` screen session and starts automatically on boot:

| Action | Command |
|---|---|
| Start server | `bash ~/minecraft/start.sh` (or `sudo systemctl restart minecraft`) |
| Stop server safely | `bash ~/minecraft/stop.sh`, or attach and type `stop` |
| Attach / detach | `screen -r mc` / `Ctrl + A` then `D` |
| New world | `bash ~/minecraft/newworld.sh` |
| Setup log | `tail -f /var/log/mc-setup.log` |

RAM is allocated automatically (total RAM minus 2 GB for the OS). `newworld.sh` archives the current world as `world_YYYYMMDD_HHMMSS`. Old worlds are never deleted automatically. If you launched with `--seed`, the new world uses the same seed unless you change `level-seed` in `server.properties`.

---

## Profiles

A profile is a plain `KEY=value` file in `profiles/`. It can set any config key, but usually only sets what makes the mod set different:

```bash
# profiles/sharedhealth.conf
MC_VERSION=26.2
FABRIC_INSTALLER_VERSION=1.1.2
JAVA_VERSION=25
MODS="fabric-api-0.160.0+26.2.jar lithium-fabric-0.25.3+mc26.2.jar sharedhealth-1.2.12.jar"
PORTS="tcp:25565"
PROPS="hardcore=true;difficulty=hard"
```

- `MODS` and `PORTS` are space-separated. `PROPS` is `;`-separated because values like `motd` can contain spaces.
- Java is always Eclipse Temurin `JAVA_VERSION` from the Adoptium repo.
- Profiles and `.env` are **data, not shell scripts**: no `$`, quotes inside values, backticks, backslashes or inline comments. Unknown keys are rejected, so typos fail loudly.

### Adding a profile or updating mods

1. Put the jars in `mods/<MC_VERSION>/`.
2. Add or edit `profiles/<name>.conf`.
3. **Push the jars.** Instances download mods from GitHub at `REPO_REF` (default `main`). To test from a branch, push it and launch with `--ref <branch>`. `launch` checks that every mod is downloadable before creating anything.

Changes to `server/` scripts don't need a push. They're embedded into the instance's user data from your local checkout, and `launch` warns if they're uncommitted.

---

## How It Works

- **`bin/mc launch`** resolves the config, renders EC2 user data (gzipped) and calls the AWS CLI: latest Ubuntu 24.04 AMI from SSM, a security group `mc-<name>` (game ports open to everyone, SSH only to your IP), and the instance with a gp3 root volume.
- **The user data** writes `server.env` (the resolved profile) and the `server/` scripts to `~/minecraft`, then runs `setup.sh`. That installs Java, Fabric and the mods, writes `server.properties`, `ops.json` and `whitelist.json`, and installs a `minecraft` systemd service.
- **Everything is tagged** `Project=lockoutserver`, `Name=<name>`, `Profile=<profile>`. Commands find servers by tag, so there's no local state, and anything launched from any machine shows up in `bin/mc list`.
- **`destroy`** cancels any spot request, terminates the instance, and deletes the security group and Elastic IP. Run it with a name that has no instance to clean up leftovers from a failed launch.

### Launching from the EC2 console instead

`bin/mc launch --render-only [flags] > userdata.sh` prints the user data. It's slightly over the console's 16 KB limit as plain text, so paste the output of `... | gzip -9 | base64 -w0` and tick **"User data has already been base64 encoded"**. Open the profile's `PORTS` and SSH in the security group yourself.

---

## Choosing an Instance Type

- **`c7i.xlarge`** (4 vCPU / 8 GB) is the default. **`m7i.large`** (2 vCPU / 8 GB) is the budget option.
- **Avoid the `t3` family.** It is burstable: a `t3.medium` ran at ~95% CPU with a small group and, once its CPU credits ran out, got throttled and lagged.
- Minecraft is mostly single-threaded, so clock speed matters more than core count. The `c7i`/`m7i` (Intel), `c7a`/`m7a` (AMD) and `c7g`/`m7g` (Graviton, ARM) families all work. `launch` picks the right AMI for ARM types.
- View distance 20 needs the 8 GB. On a 4 GB instance, use `--view-distance 10`. `launch` warns about this.
- `--spot` is much cheaper but AWS can interrupt it. The instance stops (world saved) rather than being deleted, and `bin/mc start` brings it back.

---

## Client Setup (Players)

- **Required:** a vanilla Minecraft client on the profile's version (**1.21.11** for Lockout, **26.2** for Shared Health).
- **Lockout:** install [Simple Voice Chat](https://modrinth.com/plugin/simple-voice-chat) on a local Fabric profile to use voice chat.
- **Optional (better FPS):** a local Fabric profile with [Sodium](https://modrinth.com/mod/sodium).

---

## Costs

An instance bills **until it's stopped or terminated**. Closing your terminal or stopping Minecraft doesn't stop billing.

- `bin/mc stop` halts compute charges, but you still pay for the disk.
- `bin/mc destroy` stops all charges and deletes the worlds (it offers to download them first).
- `bin/mc list` shows everything still running in the region.
