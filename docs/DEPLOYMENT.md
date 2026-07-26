# Deployment strategy

## Decision: Docker is runtime, not encryption

An ordinary Docker named volume is persistent storage managed by Docker and stored on the host filesystem; it is not automatically encrypted. [Docker volumes](https://docs.docker.com/engine/storage/volumes/) Docker's data directory contains volumes, containers and other daemon state, so encrypting only one application directory is not the same as encrypting every Docker artifact. [Docker daemon data](https://docs.docker.com/engine/daemon/)

For production we use:

```text
encrypted host block device (LUKS/dm-crypt)
             |
     mounted /srv/torchat-secure
             |
       Docker bind mounts
             |
  PostgreSQL / onion keys / backups
```

The host must unlock the encrypted filesystem before starting the stack. If the host is powered off or the filesystem is locked, the data is unavailable. When the filesystem is mounted and the container is running, a privileged host administrator can still access plaintext files; disk encryption protects data at rest, not a compromised running host.

## What belongs on encrypted storage

```text
/srv/torchat-secure/
├── postgres/                 # PostgreSQL data directory
├── onion/                    # onion service private key and hostname
├── backups/                  # encrypted/retained backups
└── runtime/                  # transient runtime files only; no message queue
```

The onion private key must never be committed to Git, baked into an image or passed as an environment variable. File ownership and permissions must be explicit.

## What does not belong there

- container images and source code;
- public configuration templates;
- development data;
- application logs containing secrets;
- unencrypted backup archives.

The server should store only E2EE ciphertext for message content. PostgreSQL encryption at rest is an additional layer, not a replacement for E2EE.

## Docker Compose model

Production Compose will use bind mounts rather than an automatically-created named volume:

```yaml
services:
  server:
    read_only: true
    tmpfs:
      - /tmp:size=64m,noexec,nosuid,nodev
    volumes:
      - type: bind
        source: /srv/torchat-secure/runtime
        target: /var/lib/torchat/runtime
    secrets:
      - database_password

  postgres:
    volumes:
      - type: bind
        source: /srv/torchat-secure/postgres
        target: /var/lib/postgresql/data
    secrets:
      - database_password

secrets:
  database_password:
    file: /srv/torchat-secure/secrets/database_password
```

This is a design fragment, not yet a runnable production stack. Docker Compose secrets are mounted only into services explicitly granted access and appear as files under `/run/secrets`. [Docker Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)

## Host hardening

- Dedicated Linux host or VM for production.
- Rootless Docker where compatible; Docker documents that rootless mode runs the daemon and containers without root privileges. [Docker rootless mode](https://docs.docker.com/engine/security/rootless/)
- No Docker socket mounted into application containers.
- No public PostgreSQL port.
- Onion service is the only public entry point.
- Firewall allows SSH only from an administration network and does not expose the API clearnet port.
- Automatic security updates, time synchronization and monitored disk health.
- Separate production and staging onion keys and databases.

## Backup policy

Backups must be encrypted before leaving the host and tested by restoring into an isolated environment. A backup must contain no plaintext message content, because the server should never have it. The onion private key requires a separate, access-controlled backup; losing it changes the service identity and therefore the pinned default onion.

## Development versus production

### Development on Windows/Docker Desktop

Use ordinary named volumes or bind mounts for convenience. Docker Desktop's virtual disk protection is not our production threat model, and developers must use synthetic data only.

### Production on Linux

Use an encrypted host filesystem, explicit bind mounts, restricted secrets and a separate operational account. Do not attempt to create a cryptographic block-device volume from inside the application Compose file.

## Implementation order

1. Keep the server container stateless except for runtime files.
2. Add PostgreSQL migrations and health checks.
3. Add development Compose with ordinary local storage.
4. Add production Compose using `/srv/torchat-secure` bind mounts.
5. Add onion service provisioning and secret rotation procedures.
6. Add backup/restore tests before accepting real users.
