---
name: develop
description: Use when planning or executing feature, module, or task development work in this repository. Use for implementation, refactoring, test updates, migrations, and scoped progress tracking across the Manifold umbrella apps.
---

# Develop

## Scope

Use this skill when a task needs planned implementation across one or more apps in
the Manifold umbrella (`apps/*`), including feature work, module refactors, and
task decomposition.

## References

- For module/feature decisions: [`module-development.md`](references/module-development.md)
- For task planning and execution: [`task-development.md`](references/task-development.md)
- For creating feature/task updates: [`feature-task-template.md`](references/feature-task-template.md)

## Core workflow

1. Confirm scope from the request, affected apps, and acceptance criteria.
2. Open the corresponding reference file first.
3. Implement the minimal change set in `lib/`, `test/`, and config/migrations as
   needed.
4. Run the scoped checks before reporting.
5. Record or update a feature file in `.agents/skills/develop/references/`.

## Maintenance rule

After each feature create or update, update the matching skill reference entry under
`.agents/skills/develop/references/{feature-name}.md` so future contributors have
current implementation guidance.
