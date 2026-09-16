# Host intelligence

Status: proposed on 2026-09-15. This is a companion to the
[top-level API design](design.md). No reporter, policy, API, or scale guarantee
below is implemented by this documentation change.

## Purpose and ownership

Host intelligence supplies current, bounded observations that let cluster
placement select compatible capacity and explain its decisions. Each host knows
its runtime and workload. The coordinator combines those facts with configured
requirements and admission claims.

A supervised host reporter should run inside each prepared Jido runtime. It can
use core Jido Actions and publish lifecycle Signals. It does not require a model
or an AI request session. The reporter must not create a second Agent repair loop.

| Component | Owns |
| --- | --- |
| Host reporter | Runtime identity, compatibility facts, resource samples, and observed managed-Agent counts |
| Provider | Resource identity, incarnation, boot state, pause state, and release observations |
| Placement policy | Eligibility and deterministic host selection |
| Admission authority | Capacity claims and the selected budget scope |
| Deployment owner and core Controller | Activation, movement, cleanup, and bounded repair |

Reports are evidence, not reservations or write-authority grants. Provider health,
BEAM connectivity, core readiness, and available Agent slots remain separate facts.

## Proposed report and API

Extend the existing proposed `hosts(cluster, target)` inspection with a report
summary. Add `host_report(cluster, host_id)` returning `{:ok, HostReport}` or
`{:error, Error}`. Read calls do not acquire capacity or trigger movement.

| Report field | Meaning |
| --- | --- |
| Identity | Exact namespace, host ID, provider resource identity, host incarnation, and reporter generation |
| Revision | Monotonic sample sequence within that reporter generation |
| Compatibility | Application release identity, supported Agent definitions, OTP/Elixir versions, required services, and persistence configuration identity |
| Capacity | Configured Agent slots and the admission scope; claim counts are identified separately from observed process counts |
| Workload | Aggregate managed-Agent counts, known active-work counts, and bounded load measurements |
| Resources | Available CPU information, runtime memory, memory headroom, disk, and optional provider measurements |
| Availability | Booting, eligible, unavailable, draining, or uncertain, with reasons |
| Freshness | Fresh, stale, or unknown; coordinator observation time and probe evidence |
| Provenance | Which values came from configuration, the runtime, or the provider |

Unknown measurements are explicit null or unknown values. They are never zero
usage or unlimited capacity. Do not transmit credentials, Agent state, prompts,
or conversation contents in host reports.

Keep reports aggregate and bounded. Fetch detailed Agent observations on demand
or in bounded pages, not as a complete list of Agent snapshots on every poll.
Report infrastructure processes separately from application Agent slot usage.

The reporter returns measurements. The coordinator derives eligibility from the
target policy. A host cannot grant itself extra capacity by changing a sample.

## Freshness and incarnation

Use host incarnation, reporter generation, and sequence together. Reject samples
from retired incarnations and out-of-order samples from the same generation.
A larger sequence from another generation is not comparable.

Use coordinator-local monotonic time for probe deadlines and expiry. Wall-clock
timestamps are diagnostic; do not compare monotonic clocks from different hosts.
Retained or delayed telemetry must not revive an unavailable host.

A host enters or re-enters eligibility only after a bounded direct probe. The
reporter samples after receiving that probe and echoes its nonce. The coordinator
checks identity, incarnation, nonce, sequence, compatibility, and deadline before
accepting the result. A missing or late reply leaves eligibility stale or unknown.

Periodic reports may update diagnostics between probes. Their receipt alone must
not reverse an unavailable or uncertain decision. A Sprite cold restart must
produce a verified runtime incarnation and pass compatibility checks again.
Neither a reboot claim nor a missed heartbeat authorizes replacement of an old
writer on another host.

## Placement policy

Evaluate eligibility before ranking:

1. Confirm a current host identity and bounded probe result.
2. Check namespace, release compatibility, required services, and persistence.
3. Check configured labels and provider capabilities against requirements.
4. Exclude draining hosts and hosts with unresolved ownership or cleanup.
5. Check admission claims and any required resource headroom.
6. Retain an existing eligible placement or select deterministically.

Configured slot limits are hard admission limits within their declared scope.
Load measurements guide policy; a low-CPU sample does not increase the slot limit.
If a requirement depends on a missing measurement, reject that candidate with an
explanation. Policies that require only verified compatibility and slots do not
need to invent unavailable resource data.

Start with eligibility and stable selection. Later load-aware ranking should use
bounded pressure bands, minimum sample evidence, and cooldown. A brief spike must
not repeatedly move an otherwise healthy Agent. Existing placements stay in place
until an accepted move, drain, repair, or future rebalance operation changes them.

Policy explanations should identify rejected candidates, stale facts, exhausted
claims, and the observations used. Include report and inventory revisions in
`Plan` so an operator can understand a later admission recheck.

## Multiple Agents on a host

One BEAM host can run multiple Jido AgentServers. A proposed target can declare
`agents_per_host: 50`, with an explicit budget scope. That is an admission setting,
not proof that every workload fits on a host.

Track Agent slots separately from active tool or model requests. Fifty mostly
waiting Agents and fifty CPU-heavy tools have different resource needs. A later
active-work budget must name its unit and enforcement point rather than treating
Agent count as a CPU guarantee.

Shared placement requires one admission authority and a complete claim inventory.
The host reporter can detect a discrepancy between claims and observed Agents;
it cannot resolve that discrepancy by deleting claims or stopping Agents itself.
Pause affected admission and request bounded reconciliation.

On stop, release only that deployment's claims. Keep a shared host while another
deployment uses it. A provider resource can be destroyed only after all required
Agent cleanup and release conditions are established.

## Failure and federation

Host observations should feed normal status and telemetry. Optional federation
can carry selected lifecycle events such as host pressure or availability changes.
See [Signal federation](signal-federation.md).

Federated events are notifications. Admission reads the validated host view and
claim inventory; it does not trust an arbitrary Signal payload as an authoritative
capacity update. A bridge failure is not proof of host failure. A missing report
is not proof that all Agents on that host stopped.

Reporter loss prevents new placement when the required facts expire. It does not
automatically terminate existing Agents. Provider loss, runtime loss, reporter
loss, and control-node loss need distinct status reasons and reconciliation paths.

## Test and example gates

Use injected observations and a controllable clock for policy unit tests. Use
bounded probes and explicit peer lifecycle evidence for distributed tests.

| Proof | Required observation |
| --- | --- |
| Report validation | Unknown fields, invalid counts, incompatible scope, and unsupported required measurements fail explicitly |
| Ordering | Old sequences and retired incarnations cannot replace current observations |
| Freshness | Late, replayed, or wrong-nonce reports cannot restore eligibility |
| Compatibility | A reachable host with the wrong namespace or release starts no worker |
| Claim discrepancy | Observed Agent counts do not silently create or release reservations |
| Load stability | Transient pressure does not cause repeated movement |
| Reporter loss | New admission blocks after expiry while existing activation state is reported separately |
| Shared host | Stopping one deployment retains the other deployment's Agents and provider resource |
| Host restart | New incarnation and restored workers become ready before locations are published |
| Notification loss | Dropped federation events do not change admission or writer authority |

Proposed living examples, under the existing `:example` tag:

1. **Host eligibility:** two hosts report different compatibility or freshness;
   planning explains its choice and starts nothing on the rejected host.
2. **Shared host:** two deployments occupy one host; stop one and verify retained
   workers, accurate claims, and no resource destruction.
3. **Pressure observation:** change synthetic host load and prove stable placement,
   bounded status updates, and an explicit operator move when requested.

Use 50 Agents on one host and 1,000 Agents across 20 hosts as benchmark targets.
Measure workload memory, request latency, report size, report-processing latency,
admission latency, and behavior after one host stops. These are future evidence
targets, not current package capacity claims.

## Open decisions

- Prepared-runtime identity and the minimum compatibility report.
- Probe interval, freshness deadline, and reporter-generation creation.
- Portable resource units and which measurements are available per provider.
- Shared admission authority and active-work budget enforcement.
- Operator override rules for optional measurements, without overriding required
  compatibility, ownership, or cleanup evidence.
