# mcp_celm

CeLM — Cerebellar Local Model. **A guarded local execution loop over
structured state, built to take load off the planning LLM.**

It sits between a planner that says *what* and the I/O tools that do
*how*: decide the next action from the current state, do it, observe the
result, and either advance or stop. One invariant holds throughout — **a
step that has not been verified does not advance.**

Implements `CelmPort` from `mcp_bundle`.

## How the load comes off

| Tier | Answers | Costs |
|---|---|---|
| **Observation** | Facts — a window is frontmost, an indicator is red | Nothing. A predicate over descriptor fields. |
| **Local reasoner** | Judgments within the domain | A small local model, or a rule table |
| **The planner** | What is new, ambiguous, or out of distribution | An LLM call. The tail, not the loop. |

Structure is declared, not asked for: a goal is a step graph, and the
reasoner is consulted only for `judge` checks and declared branches. What
reaches a planner on escalation is a **digest** — the fields the blocked
check read, what was and was not examined, and the knowledge attached to
it — never a screen.

## Two packs, one runtime

| Pack | Holds | Changes when |
|---|---|---|
| **Surface** | Skills, goals, intent map | The way you act and look changes — a desktop, a bench, an instrument bus |
| **Domain** | Golden references, reasoner rules or model | The subject changes |

A domain pack names descriptor fields only, never a skill. The same
knowledge can be pointed at a camera or at an instrument bus, and the
authoring cost stays the sum of surfaces and domains, not the product.

## Usage

```dart
import 'package:mcp_celm/mcp_celm.dart';

final port = CelmPortAdapter.fromManifest(
  manifestJson,
  surfacePacks: {'desktop-hid': CelmSurfacePack.fromJson(surfaceJson)},
  domainPacks: {'lab-panel': CelmDomainPack.fromJson(domainJson)},
  perception: myPerceptionPort,          // or McpPerceptionAdapter(...)
  actuators: {'hid': myActuatorPort},    // or McpActuatorAdapter(...)
  interlock: myInterlock,                // required if any skill is irreversible
);

final handle = await port.execute(
  const CelmGoalRef(id: 'open_document', params: {'path': '/tmp/notes.txt'}),
);
final outcome = await handle.outcome;   // Completed | Escalated | Cancelled | Refused
```

`example/main.dart` runs a goal end to end over in-memory ports and prints
the evidence.

## What arrives, and what leaves

- **Perception** hands back a descriptor with per-field quality (a leaf
  written as `{ "value": v, "quality": q }`) and a **coverage** statement
  — which scopes were examined, to what depth. An absent field inside an
  examined scope is `false`; one nobody looked for is `unobservable` and
  escalates. The adapter never infers coverage from content.
- **Actuation** is a verb on a tool the manifest names. Permission —
  allow-list, regime, read-only — is decided before an action reaches an
  adapter.
- **Escalation** carries a digest, and a planner needing more asks
  through `observe`.
- **Evidence** is two types: `ObservedConclusion` (no confidence) and
  `JudgedConclusion` (confidence, reasoner, premises). Provenance survives
  storage: a judged record cannot be read back as an observation.

## MCP

Seven tools, one per port method: `celm.execute` · `celm.cancel` ·
`celm.observe` · `celm.progress` · `celm.explain` · `celm.resume` ·
`celm.standalone`. `CelmToolHandler` maps a tool call to the port and
back; a host's MCP server registers the tool list and routes calls to it.
Downward, `McpPerceptionAdapter`, `McpActuatorAdapter` and
`McpInterlockAdapter` turn manifest port names into tool calls over the
host's `McpToolCaller`.

## Design

The design set — PRD, SRS, SDD, nine module designs and the test plan —
is in `../docs/`. The decisions that fix the shape of this package are PRD
§4; the loop is SDD §4.0; the field-resolution rule that keeps the loop
usable is SDD §3.1.1.
