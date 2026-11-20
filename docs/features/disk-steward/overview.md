---
type: feature
id: disk-steward
title: Disk Steward
status: implementing
owner: Boris Tsekinovsky
created: 2026-11-20
provenance: Created from the new-project intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: partial
  Data Model: known
  Notifications: unknown
  Security: partial
  Analytics: n/a
  Dependencies: partial
  Acceptance Criteria: known
schema: 1
understanding_notes:
  Problem: Нужно понимать расход места, архивировать нужные файлы и освобождать диски.
  Target Users: Личное macOS-приложение для владельца основного и дополнительных дисков.
  Primary Workflow: "Утверждены визуальный анализ, классифицированное архивирование вручную и по расписанию, подтверждаемая очистка. Описание Scope устарело: отсрочка автоматизации противоречит DEC-001, DEC-004 и REQ-005; повторный вопрос не нужен."
  Permissions: Каждое удаление требует подтверждения пользователя. Механизм доступа к папкам определит разработчик.
  Failure Scenarios: При недоступности диска назначения задание ожидает подключения. Остальные ошибки и защитные сценарии относятся к технической проработке.
  Data Model: Определены исходные папки, назначения, расписания и правила классификации по типу, имени и исходной папке.
  Notifications: "Q-006 подтверждён: пороги, интервалы повторов, уведомления об успехе, звуки и настройки приватности не утверждены. Это уточнение статуса, поэтому новых решений и требований нет. Для спецификации уже утверждённых сценариев дополнительный вопрос не нужен."
  Security: Полномочия удаления ограничены подтверждением. Проверки сохранности архивных копий ещё не описаны.
  Analytics: Продуктовая аналитика не запрошена.
  Dependencies: В репозитории только документация; существующего поведения приложения нет. Известны зависимости от macOS, подключённых дисков и работы с Docker.
  Acceptance Criteria: Все шесть требований содержат критерии приёмки. Ответ на Q-006 их не изменяет.
questions_left: 0
confirmed: 2026-11-20
---

# Disk Steward

## Idea

Build a personal macOS disk-health application with a menu bar presence and a full window for understanding storage usage, backing up selected folders, and reclaiming space across the main disk and additional storage disks.

## Problem

Files, backups, caches, and development artifacts consume space across multiple disks. The user lacks a unified visual way to understand that usage, identify cleanup opportunities, and coordinate backups with freeing space.

## Scope

Proposed first version, pending confirmation: a personal macOS application with menu bar access, monitoring of the main and additional connected disks, a treemap explorer, size/type/date analysis, on-demand backups of selected folders, and user-confirmed cleanup of files and development artifacts. Proposed deferrals: automatic backup triggers, automatic cleanup, and automatic backup retention management. The requirements below capture the stated product intent; deferred capabilities are not yet commitments for the first release.
