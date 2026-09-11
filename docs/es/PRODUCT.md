> **Idioma:** [English](../en/PRODUCT.md) · [Русский](../ru/PRODUCT.md) · **Español**

# Brief del producto — OTRS ↔ Redmine

Un flujo: escalar o vincular desde el ticket → guardar el ID de Redmine → sincronizar en ambos sentidos.

| Rol | Decisión |
|-----|----------|
| Producto | Menú Varios (no una cola); DF + artículo interno. |
| Backend | Ticket Event + SysConfig (CE sin Business Invoker). |
| Operador | Clave API de servicio, errores visibles, create/link idempotente. |

Instalación: [DEPLOY.md](./DEPLOY.md).
