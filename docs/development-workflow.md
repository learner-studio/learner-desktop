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
                             CI again on main -> keeps the tested app  --->  scripts/install-latest.sh
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

```bash
scripts/install-latest.sh           # the newest green CI build of main
RUN_ID=<id> scripts/install-latest.sh   # a specific green run
```

The script:

1. Downloads the exact bundle the runner tested.
2. Checks that the bundle names the run's commit.
3. Re-signs it with this Mac's Apple Development identity, so macOS keeps its
   microphone, speech and Bluetooth grants.
4. Installs and restarts it through `build-app.sh`.

The installed commit is written to `~/.ai-aggregator/installed-build.txt`.

## Coordination

- The agent on ovh opens and merges the pull requests.
- It tells the agent on the owner's Mac when `main` has a new green build.
- The Mac's agent runs `scripts/install-latest.sh` and reports what the owner sees.
- Checks that need the owner's live accounts or hardware stay out of CI. Today that is
  screenpipe's recordings, the ChatGPT login and the Pavlok wristband. They run only by
  hand on the Mac, when the owner asks.
