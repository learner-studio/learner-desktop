# Development workflow

Learner Desktop is developed off the owner's Mac. Normally that happens on the ovh
machine, by an agent working there. The owner's Mac only runs final builds. GitHub's
macOS runners build and test every change.

```
ovh (agent)                  GitHub                                     owner's Mac (agent)
-----------                  ------                                     -------------------
branch, edit, commit  --->   pull request into main
push the branch              CI on a clean macOS runner:
                               install, mic end to end, light/medium/
                               heavy lanes, uninstall (live step by step)
                             green -> auto-merge into main
                             CI again on main -> keeps the tested app  --->  updater installs it (not mid-call)
```

## Rules

- **Pull requests only.** `main` takes changes only through a pull request whose `CI / mac`
  check passed. Branch protection enforces this, for admins too. Never push to `main`.
- **No tests on the owner's Mac.**
  - The hooks only run the secret scan (gitleaks). The repo is public, and a pushed secret
    cannot be taken back.
  - The lanes still run anywhere by hand, as `scripts/test.sh light|medium|heavy`.
- **The runner is a test environment of its own.**
  - `scripts/ci.sh` sets `LEARNER_TEST_ENV=runner`. Every lane prints `TEST ENVIRONMENT: runner ...`.
  - Tests read it as `TestEnvironment.current` / `TestEnvironment.isRunner`.
  - A suite that needs the owner's live machine skips there, and names the reason.
- **Nothing of the owner's goes to CI.**
  - No secrets, no logins and no personal data, in the repo, in workflow logs or in artifacts.
  - The repo, its Actions logs and its artifacts are public.

## On ovh (or any machine with git and `gh`)

The app needs macOS to build, so ovh only edits code. CI does every build and every test.

```bash
git switch -c fix/short-name origin/main
# ... edit, commit (the pre-commit hook scans for secrets) ...
git push -u origin fix/short-name
gh pr create --fill --base main
gh pr merge --auto --squash         # merges by itself once CI is green
gh pr checks --watch                # every phase as it finishes
```

If CI fails:

1. Read the run's summary page, or `gh run view --log-failed`.
2. Download the logs if needed: `gh run download <run> -n ci-out`. They include the app's
   `menubar.log` and one log per phase.
3. Push a fix to the same branch. CI runs again and the PR merges when it is green.

The runner has the full Xcode toolchain (Swift 6.3, `lldb`, the sanitizers, `xctrace`).
Debugging there is scripted: add a step or a phase, or download the artifacts. There is no
interactive session on the runner.

## On the owner's Mac

New builds install themselves. `scripts/install-updater.sh` (once) adds a LaunchAgent,
`com.benpollack.learner-desktop-updater`. It runs `auto-update.sh` every 5 minutes and at
login. Each run, when `main` has a newer CI run that passed every phase, it:

1. Waits if a call is on, so the app is never restarted mid-call. It checks the coach's
   saved session, which names the call app.
2. Downloads the exact bundle the runner tested and checks that it names the run's commit.
3. Installs it with the build's own install kit: the `build-app.sh` from that commit,
   re-signing the bundle with this Mac's Apple Development identity so macOS keeps its
   microphone, speech and Bluetooth grants.
4. Checks that the app comes back up.
5. Posts a notification: "Updated to <commit>", or "Update failed" with the reason.
6. Updates itself from the same kit.

Log: `~/.ai-aggregator/logs/updater.log`. Installed commit: `~/.ai-aggregator/installed-build.txt`.

```bash
scripts/install-updater.sh              # turn automatic updates on (or refresh the updater)
scripts/install-updater.sh --remove     # turn them off
touch "$HOME/Library/Application Support/Learner Desktop/updater/PAUSED"   # pause; rm to resume
scripts/install-latest.sh               # install the newest green build now (even during a call)
RUN_ID=<id> scripts/install-latest.sh   # a specific green run
```

`scripts/uninstall-app.sh` removes the updater too, so it cannot reinstall the app.

## Coordination

- The agent on ovh opens and merges the pull requests.
- The updater installs each new green build of `main` by itself, within about 5 minutes,
  or after the call ends.
- To check what is running on the Mac, read `~/.ai-aggregator/installed-build.txt` and the
  updater's log.
- Checks that need the owner's live accounts or hardware stay out of CI. Today that is
  screenpipe's recordings, the ChatGPT login and the Pavlok wristband. They run only by
  hand on the Mac, when the owner asks.
