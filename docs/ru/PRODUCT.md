> **Язык:** [English](../en/PRODUCT.md) · **Русский** · [Español](../es/PRODUCT.md)

# Product brief — OTRS ↔ Redmine

Один поток: эскалация или привязка из тикета → сохранить ID Redmine → заметки Redmine при смене статуса приходят в OTRS.

| Роль | Решение |
|------|---------|
| Продукт | Меню «Разное» (не очередь); DF + внутренняя статья. |
| Backend | Daemon cron + SysConfig (CE без Business Invoker). |
| Оператор | Сервисный API-ключ, видимые ошибки, идемпотентные create/link. |

Установка: [DEPLOY.md](./DEPLOY.md).
