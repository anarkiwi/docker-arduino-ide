# Releasing

The pinned upstream release is the two `ARG` lines at the top of `Dockerfile`:

    ARG ARDUINO_IDE_VERSION=2.3.10
    ARG ARDUINO_IDE_SHA256=cc8a0b01...

`ARDUINO_IDE_VERSION` is the single source of truth for the image release version and names
the upstream release tag, which carries no `v` prefix. The Linux zip is verified against its
`SHA256` at build time. The zip rather than the AppImage: it is the same Electron tree
without a FUSE image around it, so it needs no extraction at runtime.

## Workflows

| Workflow | Trigger | Action |
| --- | --- | --- |
| `ci` | pull request, push to main | hadolint, shellcheck, actionlint, build, `tests/smoke.sh` |
| `release` | push to main touching `Dockerfile` or `entrypoint.sh`, manual | build, smoke test, push images, create GitHub release |
| `upstream-bump` | daily 04:41 UTC, manual | open a PR bumping the pin to the latest Arduino IDE release |

`upstream-bump` reads the release asset digest from the GitHub API, so it does not download
the 200MB zip. It uses `releases/latest`, which skips prereleases, so the nightly and RC
builds upstream also publishes are ignored. It builds and smoke tests the new pin before
opening the PR, because pull requests opened with `GITHUB_TOKEN` do not start workflow runs;
the PR body links the run that tested it. Dependabot covers the Debian base image and the
actions used here; it cannot track upstream GitHub releases, which is what `upstream-bump`
exists for.

Merging a bump PR publishes `X.Y.Z` and `latest`, and creates the matching GitHub release.
Re-running `release` for an existing version refreshes the images (for example after a base
image update or an `entrypoint.sh` change) and leaves the existing GitHub release alone.

## Secrets and variables

| Name | Kind | Required | Purpose |
| --- | --- | --- | --- |
| `GITHUB_TOKEN` | built in | yes | GHCR push, release creation |
| `DOCKERHUB_USERNAME` | secret | no | Docker Hub push |
| `DOCKERHUB_TOKEN` | secret | no | Docker Hub access token; absent disables Docker Hub push |
| `DOCKERHUB_IMAGE` | variable | no | Docker Hub repository, default `anarkiwi/arduino-ide` |

No personal access token is needed. Until `DOCKERHUB_TOKEN` is set, `release` pushes to GHCR
only and skips the Docker Hub login and tags.

## Manual release

Edit the `ARG` lines and merge to main, or run the `release` workflow by hand
(`workflow_dispatch`) to rebuild the currently pinned version.
