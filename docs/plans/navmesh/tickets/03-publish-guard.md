# 03: Publish guard (U-c)

**What to build:** A PR labelled for publishing that touches an unpublishable package goes red before merge, and nothing can be half-published.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] `[custom] publishable = "false"` on the four packages
- [ ] The check runs in publish-checks/detect-changes, never inside the publish loop
- [ ] A mixed-package dry-run control proves no `wally publish` runs

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
