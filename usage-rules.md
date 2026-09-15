# Jido Cluster V3 usage rules

Use `Jido.Cluster.InstanceManager` for keyed work on connected BEAM nodes.
Use compatible Jido V3 packages. This development branch uses sibling paths.

Start matching managers on worker nodes. Set a stable namespace and deployment
quorum. Use shared `Jido.Persistence.Adapter` storage for node-loss recovery.
Create the Mnesia table before starting a manager.

Send Signals through manager `call/4` or `cast/3`. Treat returned pids as temporary
observations. A cast acknowledges enqueue only. A timeout has an unknown result;
do not retry a Signal without an application policy for repeated work.

Do not use V2 `storage`, `handoff_mode`, `replication`, or lease options. The first
V3 foundation rejects these options. Files in `archive/v2` are reference code.
