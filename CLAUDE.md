# Learner Desktop: notes for agents

- **Workflow:**
  - Follow [docs/development-workflow.md](docs/development-workflow.md).
  - Work on a branch and open a pull request into `main`; never push to `main`.
  - CI on a GitHub macOS runner does all building and testing. The pull request merges itself when CI is green.
- **This repository is public:**
  - Never commit secrets, logins, personal data or real names.
  - Never print any of them in test output, because Actions logs and artifacts are public too.
- **Test environment:**
  - `LEARNER_TEST_ENV=runner` on CI (`TestEnvironment.current` in tests); otherwise the owner's Mac.
  - A test that needs the owner's live machine must skip on the runner and name the reason.
- **Installing:** on the owner's Mac, install only CI-tested builds, with `scripts/install-latest.sh`.
