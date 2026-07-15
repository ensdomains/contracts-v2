# HCA design summary

The HCA is registration execution infrastructure; the user's wallet remains
the name owner and long-term authority. This branch contains a standalone HCA
and local contract tests, but the manager still creates the legacy HCA and the
production security and routing work is incomplete.

Use the document for the work at hand:

- [`HCA-DESIGN.md`](./HCA-DESIGN.md) — current contract model, security
  boundaries, and open production decisions.
- [`HCA-HANDOFF-FRONTEND.md`](./HCA-HANDOFF-FRONTEND.md) — frontend integration
  boundary and current blockers.
- [`HCA-HANDOFF-PROTOCOL.md`](./HCA-HANDOFF-PROTOCOL.md) — protocol-owned work
  and acceptance criteria.
- [`HCA-HANDOFF-RHINESTONE.md`](./HCA-HANDOFF-RHINESTONE.md) — routing and SDK
  requirements owned with Rhinestone.

The checked-in mockestrator sidecar is transport infrastructure only, not a
working standalone-HCA frontend integration.
