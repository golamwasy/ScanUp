# Switching the app between versions

You can go back and forth between the old and the new version of the app with two git commands, as often as you like. Nothing is ever lost, as long as your own changes are committed first.

## The versions

| Name | What it is |
|---|---|
| `before-schedules` (tag) and `backup/before-schedules` (branch) | The app as it was before the airport boards and flight search, the working version of 2026-10-21. Never changes. |
| `main` | The newest version: airport boards with earlier and later flights, and Search for a plane by flight number, callsign or registration (merged 2026-10-21). |
| `feature/schedules` | The branch the new version was built on. Same as `main` now; it can be deleted. |

A **branch** is a line of work that moves forward when you commit. A **tag** is a bookmark on one exact commit that never moves. Both are on GitHub: https://github.com/golamwasy/ScanUp

## Run the old version on your phone

1. Quit Xcode (or at least close the project), so it does not fight the switch.
2. In a terminal:
   ```sh
   cd ~/code/ScanUp
   git status                        # must say "nothing to commit, working tree clean"
   git switch backup/before-schedules
   ```
3. Open `ScanUp.xcodeproj` in Xcode and press Run on your iPhone.

## Go back to the new version

```sh
cd ~/code/ScanUp
git status
git switch main
```

Then open Xcode and Run.

## If `git status` shows changes of your own

Keep them: `git add -A && git commit -m "my change"` and then switch. Or put them aside for a moment: `git stash`, switch, and later `git stash pop`.

## Which version am I on?

```sh
git branch --show-current            # the branch you are on
git log --oneline -1                 # the last commit
```

## Match the server to the app

- The **old app** works with the **old and the new server**.
- The **new app** needs the **new server**.

So when you go back to the old app, you do not have to touch the server. When you go back to the old *server*, go back to the old app too. How to switch the server with one button: see the backend repo, `docs/switching-versions.md` (https://github.com/golamwasy/ScanUp-Backend/blob/main/docs/switching-versions.md).

## If your computer is lost or the folder is damaged

Everything is on GitHub. Get it back with:
```sh
git clone https://github.com/golamwasy/ScanUp.git
cd ScanUp
git switch backup/before-schedules   # the old version, or stay on main for the newest
```

## Make `main` itself go back to the old version (for good)

Only if you decide to drop the new work completely. This rewrites history on GitHub, so ask before doing it. The safe way, which keeps everything: `git revert` the merge commits of the new work, or just keep working on a new branch from `before-schedules`.
