# S8 — Sandbox hosts

Status: proposed; no Fly or Sprites host adapter is implemented.

This slice puts prepared BEAM nodes inside Fly Machines or Sprites and admits
them through the existing Cluster host lifecycle. A sandbox is the remote
machine or Sprite boundary. The BEAM provides process isolation inside it;
Cluster does not claim that a BEAM process alone is a security sandbox.

Depends on: the S6 host provider contract, S3 journal recovery, S2 admission,
and a core persistence store shared by the control and worker nodes.

The first public proof is a demo controlled from a laptop browser in the `eboss`
Fly organization. A small Phoenix LiveView and the Cluster control node run on
Fly. This keeps FLAME's parent node alive when the laptop disconnects. The
workers run one trusted `Jido.AI.Agent` from a Linux release. The UI shows host
state, Agent placement, a completed model and tool request on each host, and a
planned drain. The demo app owns request results. Cluster owns host claims,
topology intent, and movement.

FLAME can keep Fly runners alive for long-running Agents. `sprites_ex` can
control a prepared Sprite that runs the same release. Keep the release on a
persistent Sprite before the demo; its live path starts the worker without
installing Mix, Elixir, or Erlang. The Sprite must stay active while it carries
a BEAM node. Model credentials and the Erlang cookie enter the worker at run
time. Neither integration alone proves that a resource is a compatible Cluster
host. Read the [plan](plan.md) for the ownership and identity seams, required
code, and proof gates before adding dependencies or making provider API calls.

Live probe evidence on 2026-09-16: two disposable Sprites ran Erlang nodes that
connected over Fly's private network through WireGuard. Both Sprites and their
WireGuard peers were removed. This proves the network path between Sprites. It
does not prove a Fly worker to Sprite connection or a Jido AI request.

Target proof: a prepared worker connects with the expected node and host
identity; it completes a model and tool request; a planned drain keeps Agent
identity and committed conversation state; acquisition after a lost reply finds
the same resource; release deletes only the recorded owned resource; an
unreachable source remains uncertain.
