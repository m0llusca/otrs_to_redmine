> **Idioma:** [English](../en/PRODUCT.md) · [Русский](../ru/PRODUCT.md) · **Español**

# Brief del producto — OTRS ↔ Redmine

Un flujo: escalar o vincular desde el ticket → guardar el ID de Redmine → las notas de estado de Redmine vuelven a OTRS.

| Rol | Decisión |
|-----|----------|
| Producto | Menú Varios (no una cola); DF + artículo interno. |
| Backend | Daemon cron + SysConfig (CE sin Business Invoker). |
| Operador | Clave API de servicio, errores visibles, create/link idempotente. |

## Qué se sincroniza

| Dirección | Qué ocurre |
|-----------|------------|
| OTRS → Redmine | **Crear** una incidencia nueva o **vincular** a una existente. No se escribe comentario en el diario de Redmine. Adjuntos opcionales en create/link. |
| OTRS → Redmine | El correo, las notas del agente y la correspondencia posterior **no** se copian. |
| Redmine → OTRS | Estado (y nota opcional) solo con `Redmine::StatusSync`. Los comentarios normales de Redmine no se copian. |
| Redmine → OTRS | Un comentario se importa solo si ese cambio de estado lleva `|note` (p. ej. `Проверка решения = open\|note`). Cambio de estado + comentario = **una** nota interna en OTRS. |
| N tickets → 1 incidencia | Estado / `|note` se replican a todos los tickets vinculados. Nada de un ticket OTRS se copia a los hermanos. |

Instalación y StatusSync: [DEPLOY.md](./DEPLOY.md).
