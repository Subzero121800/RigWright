# Governed agents on the desktop: the Rigwright pattern

*Joseph C McGinty Jr. & ResilientMind AI LLC*

An AI that can change your operating system is useful for exactly as long as you can trust it. Rigwright is a
Windows utility in which a language model plans changes to the system: registry values, services, apps and
Windows features. It is designed so that a confused, wrong or manipulated model **cannot** damage the machine.
This note describes the pattern, because it applies well beyond Windows tweaking.

## The problem with "agentic" system tools

The obvious design gives the model a shell and lets it work. On a desktop that has three failure modes:

1. **Unbounded actions.** One hallucinated command (`Remove-Item`, `diskpart`, disabling an updater) does real
   damage, and the model's confidence says nothing about whether it is right.
2. **Opaque effects.** Even correct commands change state that nobody recorded, so there is nothing precise to
   roll back to.
3. **Consent theater.** "Approve this command?" over a wall of PowerShell is not informed consent. Most people
   cannot audit it, so approval becomes a reflex.

## The pattern

Rigwright separates **who proposes** from **what can happen** and **who decides**.

### 1. The model only proposes

The model never executes anything. It returns a JSON document that matches a fixed schema: tweak IDs to apply
or revert, app IDs to install, fixes, Windows features, and optionally commands. Both Ollama (`format: <schema>`)
and Claude Code (`claude -p --tools "" --json-schema`) are constrained to that schema, with **all tools
disabled**. The model has no channel through which to act.

### 2. Proposals are validated against a catalog

Every proposed action is resolved against a curated, versioned catalog of 68 tweaks, 127 apps, 28 fixes and
12 features.

- **Unknown IDs are dropped.** The model cannot invent an action.
- Each catalog item carries **declared** facts the model cannot change: its risk level, its side effects,
  whether it uses Group Policy, which OS builds it supports, and the exact registry, service and task changes
  it makes.
- What the user sees comes from the catalog, not from the model's description.

Free-form commands sit outside this boundary. They are off by default, never pre-selected, shown in full under
"Unvetted command (not from the catalog)", and filtered for known-dangerous and obfuscated patterns. Rigwright
is explicit that this filter is **not** a sandbox. The catalog is the security boundary; the filter is a
seatbelt.

### 3. A human approves a concrete, previewable plan

Approval happens on a checklist of named, risk-rated items, not on code. **Preview exact changes** renders the
real diff against the live machine (`HKLM\...\AllowTelemetry: 3 → 0`) before anything runs. Medium- and
high-risk items need explicit confirmation.

### 4. Every change is captured before it happens

Before the first change to any value, the engine records its **original state** in a journal: whether the
registry value existed and what it held, each service's start type, each scheduled task's state. A restore
point is created per batch. Protected services (Windows Update, its repair service, Defender, the Store) can
never be disabled, whatever any caller asks.

### 5. Rollback is exact

Undo restores the journaled original, not a guessed default. A value that did not exist before is deleted,
not "reset". Because the engine knows the intended state of every applied item, it also detects **drift**: when
Windows reverts a tweak during an update, Rigwright notices and offers to reapply it.

## Why it works

| Risk | Control | Where it lives |
|---|---|---|
| Model invents a harmful action | Catalog resolution; unknown IDs dropped | `Resolve-RwAiProposal` |
| Model misdescribes an action | Risk and side effects come from the catalog, not the model | `catalog/*.json` |
| Model emits a dangerous command | Off by default; parser + pattern filter; shown in full; never pre-ticked | `Get-RwCommandVerdict` |
| User approves blindly | Named checklist plus an exact live diff | Preview / plan |
| Change cannot be reversed | State-capture journal, restore point, exact undo | `Invoke-RwTweak` |
| System drifts afterwards | Live state detection against the journal | `Get-RwTweakStates` |
| Data leaves the machine silently | Per-provider disclosure, opt-in sharing for cloud models, "View what is sent" | Settings / AI page |

The model's job shrinks to what models are good at: understanding intent ("faster for gaming but keep Game
Pass working") and mapping it onto a vocabulary of known-safe actions. Everything that has to be correct is
deterministic code and data that can be reviewed, tested and versioned.

## Generalizing

The same structure fits any agent that touches real systems: infrastructure, finance or device management.

1. **Constrain output to a schema** and remove the model's ability to act directly.
2. **Resolve proposals against a governed catalog** whose entries carry declared risk and effects.
3. **Put a human on a concrete diff**, not on raw code.
4. **Capture state before mutation**, so rollback is exact and drift is detectable.
5. **Disclose data flow per provider**, and make sharing with cloud models opt-in.

Rigwright is MIT-licensed. The code that implements each step is listed in the table above, and the tests in
`tests/` exercise the catalog, the server's security boundary and the command filter.
