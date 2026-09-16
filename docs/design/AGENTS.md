# Design documentation instructions

These instructions apply to all files in `docs/design`.

Adapted from core `jido/docs/design/AGENTS.md` at revision `01863527`. Review and
EARS conventions are shared. Dependency order and document layout follow Cluster's
user-requested slice plans. No skill is required by these instructions.

## Review status

The **Document review status** table in `README.md` is the source of truth for
user approval. Design maturity labels such as `Proposal`, `Locked for Jido
core`, or `Proposed decision` do not mean that the user approved a document.

Use only these review values:

- `Pending approval`
- `Approved`

When an agent changes a design document, the agent must set that document's
row to `Pending approval` before it finishes the task. This rule applies to all
changes, including small editorial changes.

When an agent adds a design document, the agent must add it to the table with
`Pending approval`.

An agent must not set a document to `Approved` unless the user explicitly
names that document as approved. Do not infer approval from general positive
feedback or from a request to continue.

Changing only the review-status table does not reset the review status of
`README.md`. Any other agent change to `README.md` resets its row to `Pending
approval`.

## EARS requirements

Use EARS, the Easy Approach to Requirements Syntax, when a design document
specifies required behavior. This rule applies to target contracts, alignment
plans, acceptance matrices, migration gates, and approved invariants.

Use one of these forms:

```text
<SEAM>-REQ-<number>: The <owner> shall <required response>.
<SEAM>-REQ-<number>: When <trigger>, the <owner> shall <required response>.
<SEAM>-REQ-<number>: While <state>, the <owner> shall <required response>.
<SEAM>-REQ-<number>: If <unwanted condition>, then the <owner> shall <required response>.
<SEAM>-REQ-<number>: Where <feature is enabled>, the <owner> shall <required response>.
<SEAM>-REQ-<number>: Where <feature>, while <state>, when <trigger>, the <owner> shall <required response>.
```

Use the combined form only when a simple form cannot state the requirement.

Follow these rules:

1. Give each requirement one stable and unique identifier.
2. Use one observable behavior in each requirement.
3. Name the Jido component that owns the response.
4. Use `shall` only for required target behavior.
5. Keep current facts, recommendations, and approved requirements separate.
6. Define vague terms with measurable limits or remove them.
7. Link each requirement to current evidence or a required acceptance test.
8. Keep requirement identifiers stable when wording changes. Retire an
   identifier instead of assigning it to a different behavior.

These examples show syntax only. They are not approved decisions:

```text
AGT-REQ-001: The Agent shall include Plugin-owned state in its complete state map.
TURN-REQ-001: When Turn evaluation selects an executable, the Turn evaluator shall use that executable for the complete Turn.
PERS-REQ-001: If a compare-and-swap result is indeterminate, then the Agent Server shall stop further persistent writes.
```

EARS syntax does not grant approval. Apply the review-status rules in this
file.

## Slice dependency order

Use [the delivery plan](00_architecture/delivery-plan.md). Plan in S1–S7 order:
instance/deployment, admission/drain, journal/recovery, federation,
federation lifecycle, host providers, then entity capabilities.

Finalize prerequisite contracts before dependent implementation. Record unresolved
prerequisites as assumptions or blockers in the plan. A slice may refer to a later
slice but must not silently decide that slice's owned contract.

Read current code and executable evidence before claiming alignment. Preserve
public behavior unless a migration is explicit. Map each planned change to tests.

## Slice document pattern

Cluster keeps its user-requested slice layout:

- `README.md` is the short scope, dependency, and review entry point.
- `plan.md` contains implementation steps, contracts, failure handling, example
  scenarios, migration decisions, and completion evidence.
- Add `design.md` or `alignment.md` only when a large contract or evidence review
  needs its own document. Link it from the slice README and avoid duplicate facts.

Use [the planning template](PLAN_TEMPLATE.md). Preserve the existing plans and
scenario matrices. Do not require a skill or a new approval workflow to continue
work already authorized by the user. The review table records approval state; it
is not an instruction to stop an authorized documentation task for confirmation.

Apply EARS when adding or refining required target behavior. Existing prose plans
remain proposals until refined; importing these instructions does not convert
recommendations to approved requirements or require rewriting history at once.
Use a Cluster prefix such as `CL-INSTANCE`, `CL-ADMISSION`, `CL-JOURNAL`,
`CL-FEDERATION`, `CL-BINDING`, `CL-HOST`, or `CL-ENTITY` for stable requirement IDs.

Keep current facts, recommendations, and approved decisions distinct. Record
runtime evidence separately from review status. Earlier documents under
`90_reference` are retained context, not the current delivery order. Any changed
or added design document must be represented in the review table.
