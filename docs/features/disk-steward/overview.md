---
type: feature
id: disk-steward
title: Disk Steward
status: exploring
owner: Boris Tsekinovsky
created: 2026-11-20
provenance: Created from the new-project intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: partial
  Failure Scenarios: partial
  Data Model: known
  Notifications: unknown
  Security: partial
  Analytics: n/a
  Dependencies: partial
  Acceptance Criteria: partial
schema: 1
understanding_notes:
  Problem: Нужно понимать расход места, архивировать нужные файлы и освобождать диски.
  Target Users: Личное macOS-приложение для пользователя с основным и дополнительными дисками.
  Primary Workflow: Определены визуальный анализ, архивирование вручную и по расписанию, классификация по правилам и подтверждаемая очистка.
  Permissions: Удаление требует подтверждения; технический механизм доступа к дискам предстоит определить при реализации.
  Failure Scenarios: При недоступности диска архивирование откладывается до его подключения; обработку остальных ошибок предстоит определить при реализации.
  Data Model: Определены исходные папки, расписания, правила классификации и папки назначения; внутреннее представление остаётся реализационной задачей.
  Notifications: Требования к уведомлениям не заданы и не мешают зафиксировать основной сценарий.
  Security: Подтверждение удаления определено; остальные меры защиты данных предстоит проработать при реализации.
  Analytics: Продуктовая аналитика не запрошена.
  Dependencies: Известны платформа macOS и зависимость архивирования от доступности диска назначения; технологии не выбраны.
  Acceptance Criteria: Для архивирования зафиксированы проверяемые условия; подробные критерии остальных существующих требований ещё предстоит оформить.
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
