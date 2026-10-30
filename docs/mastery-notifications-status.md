# Mastery notifications MVP: learner-desktop status

Brief: [mastery-notifications.md](mastery-notifications.md). States: todo / building / review / accepted / blocked.

Contract pinned: none yet (learner-server's status file says "not yet pushed", checked 2026-10-30). Output shapes the desktop assumes were sent to learner server on 2026-10-30; D2–D6 are built against them behind a stand-in.

| AC | State | Evidence | Last updated |
|----|-------|----------|--------------|
| D1 Contract pinned | todo | | 2026-10-30 |
| D2 Feed job | review | `menu-bar-app/Mastery.swift` MasteryFeed (Job "Mastery", 300 s; cursor, seen run ids and pending toasts in UserDefaults); light MasteryFeedTests pass against a stand-in | 2026-10-30 |
| D3 Toast | review | MasteryToastController (the coach panel's build: non-activating, HUD, 340×90, radius 18, sharingType none; Open / Nice / Not right; 8 s → ignored); feedback queued in UserDefaults and sent by the job | 2026-10-30 |
| D4 Call hold and summaries | review | MasteryPresenter.plan; MasteryPresenterTests (call hold, one summary after a call, more than two is one summary) | 2026-10-30 |
| D5 Tray | review | 🎓 Mastery section after the learner-server lines, coach baseline line under Speaking Coach, offline line, Settings › Mastery: Hold While I'm in a Call; TrayMenuClickTests updated | 2026-10-30 |
| D6 Positive only | review | MasteryNotification.gain drops a drop or no change; test noWordingForADrop | 2026-10-30 |
| D7 Tests | building | light MasteryTests, TrayMenuClickTests, tray UI test `testTheMasterySectionShows` (not run yet: needs the Mac free) | 2026-10-30 |
| D8 Live | todo | | 2026-10-30 |
| J1 Contract parity | todo | | 2026-10-30 |
| J2 Live end to end | todo | | 2026-10-30 |
| J3 Adversarial review | todo | | 2026-10-30 |
| J4 Status files accepted | todo | | 2026-10-30 |

## Log

- 2026-10-30: brief saved, status file created, loop started. D2–D6 built against a stand-in; adversarial review running.
