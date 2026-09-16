# Hyper: lessons for Jido Cluster

Reviewed on 2026-09-15 at commit `3ac24e1faa047ee7411380d5170d2280c8996b45` of
[harmont-dev/hyper](https://github.com/harmont-dev/hyper). This is a source review,
not an executed Hyper test run, security audit, or production reliability claim.
The repository was read in a temporary checkout. No source was copied and no
Hyper, Horde, Firecracker, or PostgreSQL dependency was added to Cluster.

## Fit and boundary

Hyper manages Firecracker VMs on prepared compute nodes. Its architecture notes
say it distributes work across available nodes rather than provisioning additional
compute nodes itself. It separates required capacity from observed load, and uses
image locality to rank eligible candidates. Its disk fork path cold-boots a guest;
it is not a transfer of a live Agent's memory or checkpoint semantics.
Source: [architecture](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/docs/cookbook/architecture.md).

Jido Cluster manages a different resource: a compatible Jido runtime hosting core
topologies. Hyper could be evaluated as a future optional host provider, but a VM
would still need Cluster registration, persistence access, and federation setup.
VM creation alone cannot establish topology readiness. Keep Docker as the planned
first local provider proof; do not expand the build to Firecracker infrastructure.

## Lessons and decisions

### 1. Separate candidate information from admission

Hyper's scheduler reads replicated budget observations, filters/ranks candidates,
and asks the selected node to confirm. Its placement loop continues on returned
errors and ultimately returns a capacity error when none succeeds. This is useful
separation, but Cluster needs richer failure classification and must not retry a
placement elsewhere after an unknown effect.
Source: [scheduler](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/lib/hyper/cluster/scheduler.ex).

Apply in S1/S2: plans explain candidates and record observation revisions. Scope
admission reserves the whole topology before activation; the host checks current
incarnation, scope, and the same claim ID before accepting activation. A refusal
with proof that nothing started can permit replanning. Timeout, partial start,
or unknown cleanup requires reconciliation, not candidate fallback.

### 2. Reserve before starting

In the inspected `try_run/3`, Hyper calls the VM start function, then performs
budget admission, stopping the VM if admission fails. Cluster's declared complete
admission contract requires the opposite order for Agent activation.
Source: [node runtime](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/lib/hyper/node.ex).

Apply in S2: scope reserve, host confirmation, core activation, observed readiness.
Use the same claim identity throughout. Host confirmation is a local guard, not an
independent placement policy or an extra capacity grant. If its state is lost,
reconcile before accepting more activations. Confirmed absence is needed before
returning a failed claim to the pool.

### 3. Separate placement ownership from process lifetime

Hyper uses a local VM supervisor rather than a distributed supervisor that could
restart a machine-specific VM elsewhere. Its hard-budget ledger monitors owner
processes and releases their reservations on exit. The latter is not sufficient
for Cluster's remote or provider resources, which may outlive a coordinator.
Sources: [local supervision](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/lib/hyper/node.ex),
[budget owner monitoring](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/lib/hyper/node/budget/hard.ex).

Apply in S1/S3/S6: process exit prompts reconciliation. It does not automatically
release remote claims or destroy a host. Keep explicit desired state, local Agent
supervision in core, and confirmed cleanup before replacement.

### 4. Reconciliation must recover resources after abrupt death

Hyper includes a pure orphan-selection planner and a periodic reaper using several
liveness observations. Its implementation comments identify reliance on process
termination cleanup as fragile and propose reconciliation as the primary cleanup
mechanism. Its repeated-observation grace is useful local protection but is not a
distributed proof of source death.
Sources: [reaper](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/lib/hyper/node/reaper.ex),
[pure cleanup plan](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/lib/hyper/node/reaper/plan.ex).

Apply in S3/S6: journal intent plus bounded provider observation drives cleanup;
termination callbacks are a fast path. Inspect owned resource identities and label
unexpected candidates. Preserve active, borrowed, uncertain, or unknown-incarnation
resources. Repeated absence from a routing cache never authorizes destruction.

### 5. Keep volatile observations out of authoritative state

Hyper uses separate replicated registries for routing and budget reports. Its
routing implementation also documents a registration-visibility race and permits
callers to tolerate delayed visibility.
Sources: [routing](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/lib/hyper/cluster/routing.ex),
[budget advertisements](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/lib/hyper/cluster/budget.ex).

Apply in S1/S2/S4: distinguish desired journal state, accepted core placement,
observed ready locations, and host measurements. Report a pending observation
rather than treating a temporary lookup miss as permission to start another Agent.
High-frequency metrics do not rewrite the journal or share its mutation queue.
This does not select CRDT registries as Cluster's authority mechanism.

### 6. Make resource state transitions explicit

Hyper's VM controller uses named boot phases with readiness deadlines. Its tests
also check that intentional resource termination is not undone by an automatic
supervisor restart.
Sources: [VM state machine](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/lib/hyper/node/fire_vmm/state.ex),
[restart tests](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/test/hyper/node/refcounted_restart_test.exs).

Apply in S1/S6: define transitions and deadlines before selecting `GenServer` or
`:gen_statem`. Add behavioral tests that stop stays stopped, resources do not
reappear, and timeout preserves unknown results. Do not mandate `:gen_statem` or
copy a child restart setting without checking the owning lifecycle.

### 7. Test laws as well as examples

Hyper has generated tests for reservation arithmetic and orphan-selection rules.
These complement its fixed scenarios; their presence is not evidence we ran them.
Sources: [budget properties](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/test/hyper/node/budget/hard_state_properties_test.exs),
[cleanup properties](https://github.com/harmont-dev/hyper/blob/3ac24e1faa047ee7411380d5170d2280c8996b45/test/hyper/node/reaper/plan_properties_test.exs).

Apply in S2/S3/S6: add model-based sequences for reserve, confirm, fail, reconcile,
and release. Check conservation of claims, idempotent request handling, retention
of uncertainty, and preservation of borrowed/live resources. Keep the existing
living examples as public demonstrations rather than replacing them with generators.

## What stays out

No Firecracker kernel preparation, disk layering, VM fork semantics, general exec
API, privileged host tools, or mandatory SQL store enters this build. Soft load and
cache affinity can inform later ranking, but cannot override hard capacity or
compatibility. Hyper's implementation is prior art, not a substitute for our own
connected ownership and failure proofs.

The applied requirements are in
[the lifecycle contracts](../../00_architecture/lifecycle-contracts.md), with
implementation gates in [build readiness](../../00_architecture/build-readiness.md).
