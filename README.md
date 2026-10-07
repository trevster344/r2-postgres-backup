# r2-postgres-backup

A container that periodically dumps PostgreSQL and uploads the archive to a
[Cloudflare R2](https://developers.cloudflare.com/r2/) bucket using `rclone`.

The container runs a loop. Each iteration:

1. Dumps the target with `pg_dump` (default) or `pg_dumpall` (see `PG_DUMP_MODE`).
2. Uploads the file to `r2://<bucket>/<prefix>/`.
3. Deletes the local file and sleeps for `BACKUP_INTERVAL_SECONDS`.

`PG_DUMP_MODE`:

- `database` (default) — `pg_dump -Fc` of the single `PGDATABASE` (custom `.dump`).
- `cluster` — `pg_dumpall --clean`: the whole cluster (all databases plus
  globals/roles) as plain `.sql`; the `--clean` DROPs make restores into an
  existing cluster cleaner.

The PostgreSQL client is **baked into the image at build time** — Linux installs
Alpine's `postgresql18-client`; the Windows image downloads the PostgreSQL 18
client from EnterpriseDB. No runtime mount. `rclone` is bundled for the upload.

Two variants:

- **Linux** — `Dockerfile` / `entrypoint.sh` (Alpine 3.23, PostgreSQL 18 client).
- **Windows** — `Dockerfile.windows` / `entrypoint.cmd` (Server Core + PostgreSQL
  18 client), for **Windows Server 2019** running Windows containers.

## Prerequisites

- An R2 API token with **Object Read & Write** on the target bucket.
- The bundled `pg_dump` is PostgreSQL 18, so it can dump servers up to
  PostgreSQL 18 (an older client cannot dump a newer server).

## Configuration

Container settings are supplied through environment variables. Copy the
example file and fill in your values:

```sh
cp .env.example .env
```

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `PGHOST` | yes | — | PostgreSQL host |
| `PGPORT` | no | `5432` | PostgreSQL port |
| `PGUSER` | yes | — | PostgreSQL user |
| `PGPASSWORD` | yes | — | PostgreSQL password |
| `PGDATABASE` | yes* | — | Database to dump (*required only when `PG_DUMP_MODE=database`) |
| `PG_DUMP_MODE` | no | `database` | `database` = `pg_dump` PGDATABASE; `cluster` = `pg_dumpall` (all DBs + globals) |
| `R2_ACCESS_KEY_ID` | yes | — | R2 access key ID |
| `R2_SECRET_ACCESS_KEY` | yes | — | R2 secret access key |
| `R2_ENDPOINT` | yes | — | `https://<accountid>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | yes | — | Target bucket |
| `R2_PATH_PREFIX` | no | `` | Folder inside the bucket |
| `BACKUP_INTERVAL_SECONDS` | no | `86400` | Seconds between backups |

`.env` is git-ignored and never copied into the image. Environment-specific
files such as `.env.production` are also ignored (`.env.*`, except
`.env.example`).

## Linux (Alpine)

Alpine 3.23 with `postgresql18-client` (pg_dump 18). No mount, no host client.

```sh
docker build -t r2-postgres-backup .
docker run -d --name pg-backup --restart unless-stopped --env-file .env r2-postgres-backup
```

### Database in another Docker network

If the database runs in another Compose project and its port is **not**
published to the host, attach this container to that network and use the
database's service/container name as `PGHOST`. `docker-compose.yml` joins an
external network selected by `${DB_NETWORK}` (default
`mals-sync-test_mals_net`):

```sh
DB_NETWORK=my_project_my_net docker compose up -d
```

For a database reachable on the host machine, use
`PGHOST=host.docker.internal` (the Compose file already maps this).

## Windows Server 2019 (Windows containers)

Windows Server 2019 runs **Windows containers only** — it cannot run the Linux
image. `Dockerfile.windows` uses
`mcr.microsoft.com/windows/servercore:ltsc2019` (build 17763, matching the
host) with a `cmd` entrypoint (`entrypoint.cmd`).

### Recommended: Docker Engine (Moby)

Docker Engine has the most complete Windows-container implementation (working
`build`, automatic HNS/NAT networking, `docker compose`). Install it (elevated
PowerShell), per Microsoft's Windows Server quickstart:

```powershell
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1" -o install-docker-ce.ps1
.\install-docker-ce.ps1
# reboot if prompted, then open a new terminal and verify:
docker version
```

Build and run (the PostgreSQL 18 client is downloaded during the build):

```powershell
docker build -f Dockerfile.windows -t r2-postgres-backup:windows .
docker run -d --name pg-backup --restart unless-stopped `
  --env-file .env `
  --add-host "host.docker.internal:192.168.1.50" `
  r2-postgres-backup:windows
docker logs -f pg-backup
```

Or Compose (`HOST_IP` required):

```powershell
$env:HOST_IP = '192.168.1.50'
docker compose -f docker-compose.windows.yml up -d
```

> The Microsoft Docker CE installer does **not** include the Compose plugin.
> Install it once (the Docker CLI searches `%ProgramFiles%\Docker\cli-plugins`):
>
> ```powershell
> $dir = "$env:ProgramFiles\Docker\cli-plugins"
> New-Item -ItemType Directory -Force $dir | Out-Null
> Invoke-WebRequest "https://github.com/docker/compose/releases/latest/download/docker-compose-windows-x86_64.exe" -OutFile "$dir\docker-compose.exe"
> docker compose version
> ```

> The image installs the Visual C++ runtime (`vc_redist.x64.exe`) because the
> host's runtime is not visible inside the container; the baked-in `pg_dump.exe`
> needs it.

### Alternative: containerd + nerdctl + BuildKit

nerdctl can run/manage, but its Windows support is experimental
([containerd/nerdctl#28](https://github.com/containerd/nerdctl/issues/28)), and
`nerdctl build` is **broken for Windows containers** — it fails with
`error: invalid local: resolve : The system cannot find the path specified.`

> Build with `buildctl` instead, and run commands from **PowerShell or cmd**
> (not Git Bash, to avoid MSYS path mangling).

Build with `buildctl` (buildkitd must be running with the containerd worker in
the `default` namespace), from the repository root:

```powershell
buildctl build --progress=plain --frontend=dockerfile.v0 --local=context=. --local=dockerfile=. --opt=filename=Dockerfile.windows --output=type=image,name=r2-postgres-backup:windows
```

Run with nerdctl:

```powershell
nerdctl run -d --name pg-backup --restart unless-stopped `
  --env-file .env `
  --add-host "host.docker.internal:192.168.1.50" `
  r2-postgres-backup:windows
```

### Build locally and transfer (no build toolchain on the server)

Build on a Windows 11/10 dev machine with Docker Desktop in **Windows
containers** mode and ship the image as a tar:

```powershell
docker build -f Dockerfile.windows -t r2-postgres-backup:windows .
docker save r2-postgres-backup:windows -o r2win.tar
# copy r2win.tar to the server, then load it:
docker load -i r2win.tar          # Docker Engine
# or, with containerd/nerdctl:
nerdctl load -i r2win.tar
```

### Windows host prerequisites

For the container to reach PostgreSQL running on the Windows host:

1. `postgresql.conf`: set `listen_addresses = '*'` (or include the host IP).
2. `pg_hba.conf`: allow the container's source address for the role.
3. Windows Firewall: allow inbound TCP on port 5432 from the container network.

## Restore a backup

Download the desired `.dump` from R2 and restore it with `pg_restore`:

```sh
pg_restore -h <host> -U <user> -d <database> --clean --if-exists latest.dump
```

## Notes

- Backups are named `<database>-<timestamp>.dump` (UTC on Linux; local time on
  Windows, where batch has no UTC clock).
- The interval resets whenever the container restarts. For wall-clock
  scheduling, run this image as a one-shot job from an external scheduler
  instead (cron, systemd timer, Windows Task Scheduler, Kubernetes CronJob).
- The R2 API token must have **Object Read & Write** permission for the target
  bucket. A read-only token authenticates but fails uploads with
  `403 AccessDenied`.
- `rclone lsd r2:` always returns `AccessDenied` because R2 does not implement
  bucket listing; use `rclone lsf r2:<bucket>` to check a bucket instead.
- Database access is read-only (`pg_dump` only); the container never writes to
  the source database.
