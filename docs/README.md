# Documentation index

Start with [Development progress and remaining work](PROGRESS.md) for the current
implementation snapshot, recorded acceptance gaps, and suggested next tasks.

## Current guidance

| Document | Purpose |
| --- | --- |
| [Progress](PROGRESS.md) | Implemented capabilities, pending verification, engineering follow-ups and optional extensions |
| [Product and architecture](DESIGN.md) | Application boundaries, durable mail contracts and product scope |
| [Web UI design](../DESIGN.md) | DuskMoon tokens, themes and app chrome conventions |
| [OAuth setup](OAUTH_SETUP.md) | Microsoft device-code login and Google redirect/pasted-URL completion |
| [iCloud setup](ICLOUD.md) | Account-owned Contacts/Calendar, bidirectional sync, conflicts and migration |
| [TLS backends](TLS_BACKENDS.md) | Default OTP TLS and the explicit ex_ssl consumer boundary |
| [Crash boundaries](CRASH_BOUNDARIES.md) | Persistence, retry and recovery invariants |
| [API guide](../apps/manifold_api/README.md) | REST, GraphQL and deployment access boundary |
| [Feature maintenance notes](../.agents/skills/develop/SKILL.md) | Module ownership, implementation constraints and feature-specific validation |

## Original milestones

These plans record completed milestone scopes. Later features can supersede
their initial models or limits; use the current guidance above for present-day
behavior. Historical test counts are evidence for their recorded revisions.

| Milestone | Plan | Recorded status |
| --- | --- | --- |
| 0–1: architecture and durable inbound | [Implementation plan](IMPLEMENTATION_PLAN.md) | Completed |
| 2: mailbox projection | [Milestone 2](MILESTONE_2_PLAN.md) | Completed |
| 3: managed outbound | [Milestone 3](MILESTONE_3_PLAN.md) | Completed |
| 4: security and policy framework | [Milestone 4](MILESTONE_4_PLAN.md) | Completed; production engines are deployment integrations |
| 5: cloud ingress edge | [Milestone 5](MILESTONE_5_PLAN.md) | Completed |
| 6: external connectors | [Milestone 6](MILESTONE_6_PLAN.md) | Implemented |

## Feature plans and evidence

- [Feature plan/specification index](superpowers/README.md): historical designs,
  implementation plans and their corresponding maintenance records.
- [iCloud acceptance](ICLOUD_ACCEPTANCE.md): dated implementation, real-account
  read, browser and release checkpoints; some older limits are superseded.
- [Architecture decisions](adr/): ADRs 0001–0011. Read later superseding decisions
  alongside the original decision.

## Keeping progress current

Update `PROGRESS.md` and the matching develop reference when a capability or
acceptance boundary changes. Link dated evidence and identify the tested revision
when available. Preserve earlier results and label superseded assumptions rather
than rewriting historical tests as current results. An unchecked step in an old
plan is not sufficient evidence that its feature is still unimplemented.
