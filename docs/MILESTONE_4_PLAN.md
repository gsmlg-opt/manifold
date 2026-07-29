# Manifold Milestone 4 Implementation Plan

**Status:** Completed

## Scope

Milestone 4 adds explicit inbound security evaluation and abuse policy:

1. Persist SPF, DKIM, DMARC, malware, and spam results without trusting message
   headers as evidence.
2. Run evaluation asynchronously after raw archival, independently of mailbox projection.
3. Create accepted mailbox entries hidden until policy explicitly releases them.
4. Keep quarantine idempotent and recoverable across crashes.
5. Add bounded per-peer SMTP connection and transaction controls.
6. Expose assessment and quarantine state through the local Phoenix operations
   interface.

This milestone does not implement an Internet recursive DNS resolver, bundle a
malware daemon, train a spam model, reject content after SMTP acceptance, or
send backscatter. Production DNS, malware, and spam engines remain replaceable
adapters.

## Application Boundary

Add:

```text
manifold_security
  -> manifold_core + manifold_data + manifold_mail + manifold_storage

manifold_ingest
  -> manifold_security

manifold_web
  -> public APIs from manifold_security
```

`manifold_ingest` owns the durable orchestration job because it can load private
transport state and construct a public security input. `manifold_security` owns
evaluation, policy, assessment persistence, events, and quarantine decisions.
It never queries ingest schemas.

## Persistent Model

`SecurityAssessment` is one current, versioned assessment per inbound delivery:

- Authentication results for SPF, DKIM, and DMARC.
- Malware verdict and scanner metadata.
- Spam verdict, score, and classifier metadata.
- Policy action: `allow`, `quarantine`, or `released`.
- Evaluation state, adapter versions, classified error, and timestamps.

`SecurityEvent` is append-only local audit history. Re-evaluation updates the
current assessment while preserving events.

Allowed authentication results are:

```text
pass fail softfail neutral none temperror permerror not_evaluated
```

Disabled or unavailable adapters return `not_evaluated`; they never fabricate
`pass`.

## Evaluation Flow

1. SMTP acceptance creates mailbox entries with quarantine visibility enforced.
2. The archival state transaction inserts one unique security-evaluation Oban job.
3. The job loads trusted transport metadata and the archived raw object through
   an ingest public input projection.
4. Security adapters evaluate authentication, malware, and spam.
5. One transaction upserts the assessment and appends an evaluation event.
6. Policy is applied through the public mail quarantine API.
7. The assessment records applied policy only after mailbox visibility is
   updated.

Retry repeats the same evaluation version and repairs an assessment/presentation
split. A missing, failed, or incomplete assessment remains hidden. PubSub may
refresh views only after committed state.

## Initial Policy

- A positive malware verdict quarantines.
- A positive spam verdict quarantines when the configured threshold is met.
- Authentication failure is recorded but does not quarantine by itself in the
  initial local policy.
- `not_evaluated` never implies safe or unsafe.
- Adapter failures persist classified failed assessments and remain hidden while
  Oban retries.
- Quarantine hides bodies, attachments, searches, conversations, and reply
  sources through the existing mailbox scope.
- Manual release is audited and does not delete the assessment.

## SMTP Abuse Controls

`manifold_smtp` owns a small supervised rate-limit process because it owns
ephemeral connection resources:

- Per-peer active connection cap.
- Per-peer fixed-window `MAIL FROM` transaction cap.
- Monitors clean up connection leases after session crashes.
- Restart resets only abuse counters; PostgreSQL remains the business source of
  truth.
- Limit rejection is temporary and emits Telemetry.

Existing message size, recipient count, spool capacity, and global Ranch
connection limits remain authoritative.

## Crash Boundaries

Tests cover:

1. Archival commit before security job execution.
2. Adapter temporary failure before assessment commit.
3. Assessment commit before quarantine application.
4. Quarantine application before final assessment policy-state update.
5. Repeated evaluation and repeated manual release.
6. SMTP session crash before explicit connection release.

## Verification

- Fresh migrations.
- Security policy and adapter-contract tests.
- Assessment persistence, retry, and crash-boundary tests.
- SMTP TCP tests for per-peer connection and transaction limits.
- Web tests for security visibility and quarantine release.
- Full format, warnings-as-errors compile, test, assets, and responsive browser
  checks.
