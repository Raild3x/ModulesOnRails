# 03: Publish guard (U-c)

**What to build:** A PR labelled for publishing that touches an unpublishable package goes red before merge, and nothing can be half-published.

**Blocked by:** None (can start immediately)

**Status:** done

- [x] `[custom] publishable = "false"` on the four packages
- [x] The check runs in publish-checks/detect-changes, never inside the publish loop
- [x] A mixed-package dry-run control proves no `wally publish` runs

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **Check:** `validate_publish_setup.py --check publishable --version-change <v> --changed-packages-file <f>`.
  - It fails when the version change is not `none` and any changed package has
    `[custom] publishable = "false"`.
  - With no label (`none`) it passes, because nothing publishes.
- **Where it runs:**
  - `publish-checks.yml` (`validate-preview` job) runs it on every PR, so a labelled PR goes red
    before merge.
  - `publish.yml` runs it again as a separate step before the `publish-packages` action (last
    guard). It is not inside the action's per-package loop, so a refusal can't strand earlier
    publishes.
- **Packages:** the four navmesh packages carry `publishable = "false"`. `unreleased = true`
  keeps its README-beta meaning.
- **Dry-run control** (scratch script, 8/8 pass):
  - `component` + `navmesh` with a `patch` label: exit 1, and only navmesh is named.
  - All four packages with `major`: exit 1.
  - The mixed set with no label: exit 0.
  - `component` + `graphutil` with `minor`: exit 0 (negative control).
  - A missing changed-packages file: exit 0.
  - In `publish.yml`, the guard step comes before the publish action, and the publish step has
    no `always()`/`failure()`/`continue-on-error` override. So a failed guard means no
    `wally publish` runs.
  - `action.yml` has no in-loop refusal.
- **Regression:** `--check packages`, `action-inputs` and `workflow-inputs` are green, and
  navmesh is 2/2.
- **Unpublishing later:** when the navmesh packages are ready to publish (the D2 publishing
  ticket), delete the `publishable` line along with the sibling → `[dependencies]` rewrite.
