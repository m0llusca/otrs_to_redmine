> **Language:** **English** · [Русский](../ru/PRODUCT.md) · [Español](../es/PRODUCT.md)

# Product brief — OTRS ↔ Redmine

One flow: escalate or link from the ticket → store the Redmine ID → Redmine status notes sync back.

| Role | Decision |
|------|----------|
| Product | Miscellaneous menu (not a queue); DF + internal article. |
| Backend | Daemon cron + SysConfig (CE without Business Invoker). |
| Operator | Service API key, visible errors, idempotent create/link. |

## What goes where

| Direction | What happens |
|-----------|----------------|
| OTRS → Redmine | **Create** a new issue or **link** to an existing one. No journal comment is written in Redmine. Optional attachments on create/link. |
| OTRS → Redmine | Ticket mail, agent notes, and later correspondence are **not** copied. |
| Redmine → OTRS | Status (and optionally a note) only via `Redmine::StatusSync`. Ordinary Redmine comments are not copied. |
| Redmine → OTRS | A comment is imported only when that status change has `|note` (e.g. `Проверка решения = open\|note`). Status change + comment become **one** internal OTRS note. |
| N tickets → 1 issue | Status / `|note` fan out to every linked ticket. Nothing from one OTRS ticket is copied onto sibling tickets. |

Install and StatusSync: [DEPLOY.md](./DEPLOY.md).
