## [0.1.1] - 2026-10-25

### Added
- A pack may declare a `version` (surface and domain). Absent loads as
  before; a present value must be a non-empty string (`pack.bad_pack`).
- `CelmPortAdapter.packs()` lists the supplied packs as `CelmPackInfo`
  (kind, id, version, whether the manifest uses it).
- A judged conclusion records the domain pack id and version it was made
  with (needs the matching `mcp_bundle`).
- `policy.gate_timeout_ms` (default 60000): the interlock is asked under a
  time limit, and one that has not answered is not satisfied
  (`Escalated(irreversibleGate)`).
- `CelmContextualInterlock` and `CelmGateRequest`: an interlock may receive
  the run id, goal, step, skill, resolved params and the deadline.
  `McpInterlockAdapter` implements it and sends `context`, `timeoutMs` and
  `deadline` besides its existing arguments. An interlock implementing only
  `CelmInterlockPort.satisfied` is unchanged.
- `validateObservationJson` lists how a perception tool's answer departs
  from the perception contract, as `CelmObservationIssue`.

## [0.1.0] - 2026-09-04

First release. Implements `CelmPort` (`mcp_bundle` 0.4.10).

### Added
- The guarded loop: decide, act, re-perceive, evaluate, branch on the
  band. Every evaluator result — `observed`, `judged`, `unobservable` —
  maps to one of four bands, and every place the loop reads a result has
  a destination for each. A step advances only on a passed postcondition.
- A judgment is read in three bands over its confidence: decided (verdict
  says pass or fail), leaning (retry), undecided (escalate
  `lowConfidence`). A confident `false` fails the step.
- A failed precondition takes the step's `on_fail` like a failed
  postcondition; it escalates `preconditionFailed` only with no
  alternative.
- Completion is decided after a terminal step, on that step's observation;
  the evaluation at entry is opportunistic.
- Field resolution with coverage: an absent field inside an examined
  scope at the check's `requires_depth` is `observed(false)`; one outside
  any examined scope, or below its quality floor, is `unobservable`.
- Field paths (`a.b[2].c[*]`) and a total expression language over them —
  comparison, membership, boolean, `count`, `all`/`any`, `has`,
  `basename`, `abs`, `len`. Packs are data; nothing in them executes.
- Two packs: a surface pack (skills, goals, intent map) and a domain pack
  (golden references, reasoner). A domain pack naming a skill or a goal
  is rejected. References attach to `judge` checks by name or by field
  overlap, fixed at load.
- Load-time validation of the manifest and both packs: unsourced ports,
  packs, reasoner or regime; unknown enum names; dangling steps; a goal
  with no terminal step; a skill declaring sequencing; a policy value in a
  pack; a judge reading nothing; a check requiring a depth no step
  requests; a writing skill outside the allow-list; a regime violation.
- Retries and escalations bounded apart: an attempt budget, an escalation
  ceiling, a wall clock, and a no-progress guard over the fields the
  blocked check reads. A caller's deadline narrows the wall; it cannot
  widen it.
- Escalation carries a digest — the fields the blocked check reads, the
  coverage bearing on them, the knowledge attached — never the
  descriptor. Every resolution, abandonment included, is written as a
  labelled example.
- Evidence as two types with provenance that survives storage; `explain`
  walks premises to observations; `standalone` returns observations only.
  `InMemoryCelmStore` and `KvCelmStore` over the host's key-value port.
- Reasoner backends: `RulesReasoner` (local, from the domain pack's rules)
  and `LlmReasoner` (the bootstrap; every conclusion it makes records
  `reasonerRemote`). `distilled` takes a host-supplied local model.
- Regimes: `discrete-verify-retry` and `supervisory`; an effector write
  under `supervisory` is rejected at load, and a supervisory goal may run
  until cancelled.
- Irreversible actions gated on the allow-list and an interlock port;
  confidence never enters the gate. An interlock port is required at
  construction when any loaded skill is irreversible.
- `CelmPortAdapter.fromManifest` with role-based authorization;
  `CelmToolHandler` exposing the seven `celm.*` tools; MCP adapters for
  perception, actuation and interlock over a host `McpToolCaller`.
- Pure Dart, all six platforms; no `dart:io`.
