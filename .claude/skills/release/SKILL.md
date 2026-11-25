---
name: release
description: Release Pladder from main through release.yml, up to the maintainer's approval and then to a checked release. Preflight, a suggested version with its notes, the dispatch, the run followed to the end, scripts/check-release.sh, and the Homebrew cask by hand if its bump failed. Use when asked to "release", "cut a release", "release 0.x.y" or "release as a draft".
---

# Releasing Pladder

Drives the Release workflow (`.github/workflows/release.yml`, INSTALL.md, "Releasing") from the request to a
checked release. The maintainer's one step is approving the `release` environment; everything around it is
here. Only when the maintainer asks for a release: a release is never part of shipping a change.

## Rules

- Run on the MacBook Air (`hostname` is `MacBookAir.fritz.box`), from the root checkout on `main`, not a
  worktree. On the code-box, say so and stop: half of `scripts/check-release.sh` needs macOS.
- The approval is the maintainer's. Never approve, reject or bypass a deployment, by any route: REST,
  GraphQL, the browser, or a change to the environment's rules. Read "waiting" from the run's status only.
  The maintainer's Claude Code settings deny the REST and GraphQL approval routes; that is a guardrail, not
  a boundary, since GitHub cannot tell this session from the maintainer: both use the same `gh` login.
- Never cancel or rerun a release run. A new attempt is a new dispatch, through the preflight again.
- Never launch, quit, update or replace a copy of Pladder on the Mac: no `brew upgrade` or `brew install`,
  no `bundle.sh --install`, no Check for Updates…, never open the DMG. The developer dictates with it
  (CLAUDE.md, "Working on this Mac while Pladder is in use"). `check-release.sh` mounts the DMG read-only and
  hidden, and that is all.
- Never read, write or print the signing secrets or keys, and never change the `release` environment.
- Never delete or edit a release or a tag. When one has to go, give the maintainer the command.

## Steps

1. **Preflight.** From the root checkout:

   ```sh
   scripts/release-preflight.sh
   ```

   `--force` only when the maintainer asked to release although nothing changed. On a `STOP`, say its line
   and stop. If it stopped on an open release run and the maintainer says to follow that run, go to step 4
   with it.

2. **Version and notes, a suggestion, not a question.** With the last tag from the preflight's `last-tag`
   line:

   ```sh
   git log --no-merges --format=%s <last tag>..HEAD
   scripts/changelog.sh <last tag> HEAD
   ```

   - A **minor**, X.(Y+1).0, when a subject outside the notes' Internals group adds something a user can
     newly do or set: a setting, a mode, a hotkey role, an engine or polish model in the picker, a managed
     policy key, a way to install or update.
   - A **patch**, X.Y.(Z+1), otherwise: fixes, speed, wording, look, Internals only.
   - Never a major unless asked: Pladder is an application with no programmatic consumers, so nothing it
     ships is a breaking change in the semver sense. A version, "minor" or "patch" in the request wins.

   Show it in a message the maintainer sees now (in T3 Code, `send_to_user`), as
   `Pladder 0.3.0 (minor): "Settings: …" adds a setting.` followed by the notes, then go on without
   waiting.

3. **Dispatch.**

   ```sh
   date -u +%FT%TZ && gh workflow run release.yml -R dinooo13/pladder --ref main -f version=<version> [-f draft=true] [-f force=true]
   ```

   `draft=true` for "as a draft", `force=true` only with the preflight's `--force`. The run id is the last
   segment of the URL it prints. If it prints none, look for up to a minute:

   ```sh
   gh run list -R dinooo13/pladder --workflow release.yml --event workflow_dispatch --limit 5 \
     --json databaseId,displayTitle,headSha,createdAt \
     --jq '[.[] | select(.displayTitle == "Release <version>")][0] // empty | "\(.databaseId) \(.headSha) \(.createdAt)"'
   ```

   The title is `Release <version> (draft)` for a draft. Any status counts, since a refused `check` ends the
   run within seconds. It is this dispatch's run only if its `createdAt` is not before the time printed
   with the dispatch and its `headSha` is the preflight's commit; otherwise look again.

4. **Until it waits.** The `check` job takes under a minute. Wait with one command in the background, and
   start it again if the harness ends it while the run is still open:

   ```sh
   until s=$(gh run view <id> -R dinooo13/pladder --json status --jq .status) &&
     { [ "$s" = waiting ] || [ "$s" = completed ]; }; do sleep 10; done; echo "$s"
   ```

   `waiting` goes on to step 5, `completed` to step 6. A run followed from the preflight may be past its
   approval already, and `in_progress` looks the same before and after it, so only these two decide.

5. **The approval.** One line the maintainer sees now:
   `Pladder <version> (<reason>) is waiting for your approval: <run URL>`. To release another version they
   reject the run on that page and say which; nothing is tagged before the approval. Then wait with one
   blocking command in the background, not a loop of `gh run view`, and start it again if the harness ends
   it while the run is still open:

   ```sh
   gh run watch <id> -R dinooo13/pladder --exit-status --interval 30
   ```

6. **When the run ends.**
   - **Success**: step 7.
   - **Rejected**: `gh api repos/dinooo13/pladder/actions/runs/<id>/approvals` shows `"state": "rejected"`
     and the reviewer's comment. Confirm nothing was tagged: `git ls-remote --tags origin refs/tags/v<version>`
     prints nothing. If the maintainer named another version, in the thread or in the rejection comment, go
     to step 1 with it. Otherwise say it was rejected and stop.
   - **The `check` job failed**: it refused the release before anyone was asked; quote its `::error::`
     line from `gh run view <id> -R dinooo13/pladder --log-failed` and stop. Nothing was tagged.
   - **A step failed**: name the step and quote its error from
     `gh run view <id> -R dinooo13/pladder --log-failed`. Then say what is left, from
     `git ls-remote --tags origin refs/tags/v<version>` and `gh release view v<version> -R dinooo13/pladder`.
     No tag and no release: the run cleaned up after itself; report and stop, and start again at step 1
     only when the maintainer asks. A tag but no release: the run's own delete failed; give the maintainer
     `git push origin --delete v<version>`. A release: its tag stays, go to step 7.
   - **Cancelled**, while waiting or later: there is no failed log. Say so with what is left, read as above,
     and stop.

7. **Check what went out.**

   ```sh
   scripts/check-release.sh <version>
   ```

   A draft skips `latest`, `cask` and `latest-download` and says so in its summary; that is a checked draft.
   Any other `FAIL` goes into the report as it stands.

8. **Cask by hand**, only for a published release whose one `FAIL` is `cask` (the Bump the Homebrew cask
   step failed, or the maintainer has since published a draft), as INSTALL.md, "Homebrew", describes:

   ```sh
   rm -rf /tmp/pladder-tap-<version> &&
     gh repo clone dinooo13/homebrew-tap /tmp/pladder-tap-<version> -- --depth 1 --quiet &&
     scripts/cask.sh <version> > /tmp/pladder-tap-<version>/Casks/pladder.rb &&   # reads the SHA-256 from the release
     git -C /tmp/pladder-tap-<version> diff
   ```

   Read the diff before going on. It may change the `version` and `sha256` lines and what
   `git diff <last tag> v<version> -- scripts/pladder.rb` changed in the template; anything else, stop and
   show it. Then, as a separate command:

   ```sh
   git -C /tmp/pladder-tap-<version> commit -qam "pladder <version>" &&
     git -C /tmp/pladder-tap-<version> push -q &&
     rm -rf /tmp/pladder-tap-<version> &&
     scripts/check-release.sh <version>
   ```

   The path is written out in every command because shell variables do not last from one command to the
   next, and a `git -C` with an empty path would commit in this checkout.

9. **Report**: the release link, the version and why, the notes, every line of `check-release.sh`, and what
   is left for a human: Check for Updates… and Install on an installed copy, and `brew upgrade` on a real
   Mac. For a draft, also that publishing it, or deleting it and its tag, is the maintainer's.
