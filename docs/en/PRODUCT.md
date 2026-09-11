> **Language:** **English** · [Русский](../ru/PRODUCT.md) · [Español](../es/PRODUCT.md)

# Product brief — OTRS ↔ Redmine

One flow: escalate or link from the ticket → store the Redmine ID → Redmine status notes sync back.

| Role | Decision |
|------|----------|
| Product | Miscellaneous menu (not a queue); DF + internal article. |
| Backend | Daemon cron + SysConfig (CE without Business Invoker). |
| Operator | Service API key, visible errors, idempotent create/link. |

See [DEPLOY.md](./DEPLOY.md) for install.
