# Build readiness and first implementation gate

Status: final planning refinement on 2026-09-15. Ready to begin S1 contract tests;
not a claim that all APIs are frozen or any runtime slice is complete.

## Fixed direction

One optional-capability package, `use Jido.Cluster`, managed or attached core,
core topology workload definitions, Bedrock-default journal on core persistence,
shared admission, explicit federation channels, and provider-owned host lifecycle.
Keep existing public behavior until a migration is proved. No automatic lost-source
replacement, replica protocol, or durable federation enters this build.

## Resolve while writing the first contracts

| Gate | Concrete artifact | Required before |
| --- | --- | --- |
| Instance identity | Exact managed-core name, namespace rules, config precedence, and ownership-mode tests | S1 runtime wiring |
| Host protocol | Registration fields, incarnation checks, claim confirmation/inspection, disconnect/rejoin table | S1 host runtime; refine claim handling in S2 |
| Operation identity | Public request token format, scope/generation, conflicts, expiry, and lookup results | S1 facade; persistent format in S3 |
| Lifecycle | Stop/service-shutdown/crash matrix and cleanup barriers | S1 owner extraction |
| Shared claims | Conflict sets, transition claims, host-guard recovery, independent progress | S2 admission |
| Journal bounds | Numerical encoded-size/retention limits and measured model size | S3 persistent implementation |
| Federation ingress | Numerical limits, concurrent admission mechanism, inbound policy, readiness states | S4 transport implementation |
| Provider | Docker environment proof, resource identities, owned discovery and release semantics | S6 backend implementation |
| Entity mapping | Bounded core-workload/Ref design probe; explicit unsupported cases | Before S2/S3 schema is fixed; full feature S7 |

These are implementation gates with named outputs, not reasons to stop planning or
ask for blanket permission again. Write tests and record the selected values in the
owning slice. Where a core contract is missing, prove the gap in a separate package.

## First build increment

1. Snapshot the current Cluster and core revisions and run the existing relevant
   suites. The old alignment review is dated evidence, not the current baseline.
2. Write managed/attached instance contract tests with explicit development journal
   configuration. Preserve Bedrock default validation and state the interim limits.
3. Define Config and operation result values before adding distributed behavior.
4. Extract the existing owner cleanup behavior behind the instance facade.
5. Add peer registration and pending-location tests, then the S1 living examples.
6. Record actual results and remaining gaps in S1. Continue to S2 with the shared
   claim and journal identity contracts already specified.

## Final review outcomes

The [Hyper source review](../90_reference/04_hyper/README.md) adds candidate/confirmation
separation, explicit host-local ownership, restart-safe resource reconciliation,
property-based ledger tests, and correlated observations. It also identifies
patterns we do not adopt: boot-before-admission, generic fallback after an unknown
attempt, CRDT visibility as authority, and process exit as proof of remote cleanup.

The current plan uses a bounded aggregate journal initially. It remains replaceable.
Unknown numerical bounds are explicit pre-implementation gates, not invented scale
guarantees. Capability support stays separate from installed optional dependencies.

## Proof before promotion

Pass each slice's unit, peer, and example contracts. Include model-based sequences
for claims and cleanup; use real backends for backend claims. The static cumulative
example gates S5, and its real-provider variant gates S6. Check that intentional
stop remains stopped and that unrelated capacity progresses around uncertain work.

Documentation checks do not establish runtime behavior. No Hyper tests or new
Cluster runtime tests were executed as part of this design-only source review.
