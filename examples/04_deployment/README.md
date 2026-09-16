# 04 Deployment instances

Read the examples in this order:

1. [Managed instance](04_01_managed_instance/README.md): start owned core and settle remote cleanup.
2. [Attached instance](04_02_attached_instance/README.md): retain application-owned core.
3. [Request identity](04_03_request_identity/README.md): share one operation across repeated requests.

Run `mise exec -- mix test test/examples/04_deployment --include example --seed 0`.
These examples use explicit memory-only operation storage. See each example's limits.
