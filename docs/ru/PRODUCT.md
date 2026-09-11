> **Язык:** [English](../en/PRODUCT.md) · **Русский** · [Español](../es/PRODUCT.md)

# Product brief — OTRS ↔ Redmine

Один поток: эскалация или привязка из тикета → сохранить ID Redmine → синк в обе стороны.

| Роль | Решение |
|------|---------|
| Продукт | Меню «Разное» (не очередь); DF + внутренняя статья. |
| Backend | Ticket Event + SysConfig (CE без Business Invoker). |
| Оператор | Сервисный API-ключ, видимые ошибки, идемпотентные create/link. |

Установка: [DEPLOY.md](./DEPLOY.md).
