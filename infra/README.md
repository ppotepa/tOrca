# Infrastructure

```text
infra/
├── tor/
│   ├── torrc.example
│   └── README.md
├── docker/
├── migrations/
├── config/
│   └── server.env.example
└── monitoring/
```

Production must expose only the v3 onion service. PostgreSQL and operational endpoints stay on private networking.

Storage and deployment policy is documented in `docs/DEPLOYMENT.md`. The production plan uses an encrypted host filesystem with Docker bind mounts; ordinary named volumes are for development only.
