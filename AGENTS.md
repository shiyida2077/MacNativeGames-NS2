# AGENTS.md — working on this fork

This checkout is a fork of `ly05010419/MacNativeGames` that carries one improvement:
Switch 2 Pro Controller 2 (2nd gen) support over Bluetooth LE. These rules keep that
improvement on top of the newest upstream without letting the two drift apart.

## Repo shape

| Remote / branch | Role |
| --- | --- |
| `upstream` = https://github.com/ly05010419/MacNativeGames.git | read only, the source of truth |
| `origin` = git@github.com:shiyida2077/MacNativeGames-NS2.git | our fork |
| `main` | exact mirror of `upstream/main`; fast-forward only, never commit here |
| `switch2-pro2` | `main` + our commits; always rebased onto `main` |

Our feature lives in `switch2-pro2` as a small stack of commits (today: one). Work on
new features on that branch (or a `switch2-pro2-xxx` branch cut from it), then rebase.

## Non-negotiable rules

1. Never commit to `main`. It only ever moves by `git merge --ff-only upstream/main`.
2. Never configure git globally (`--global`). Identity and remotes are per repo:
   `user.name`, `user.email`, `push.default=current`, `remote.pushDefault=origin`,
   `core.sshCommand` (host key file in `/tmp`, the sandbox cannot write `~/.ssh`).
3. Push the feature branch with `--force-with-lease`, never bare `--force`. Rebasing
   rewrites the commit hashes.
4. After syncing, rebuild before claiming "latest": source changes do not change the
   installed app until `rebuild-totk.sh` runs. Built apps go to
   `/Volumes/PortableSSD/MacNative/output/`; the helper scripts live in `tools/switch2/` and the
   patch bundle in `output/`.
5. The work tree (`/Volumes/PortableSSD/MacNative/MacNativeGames-work/totk143/totk`) holds
   copies, not symlinks. Edit `shared/runtime` in the checkout, then copy into the work
   tree (or rerun `build_app.py`) before `make`.
6. Bluetooth pairing is expensive for the user: batch code and logging changes, then ask
   for one pairing session instead of many. Prefer key-press wake; use Sync only if that
   fails.
7. Code copied from nxnative (MIT) keeps its attribution header; `switch2_proto.h` already
   says where it came from.

## Everyday commands

```sh
# sync upstream -> main -> rebase our commits -> push fork (stops on conflict)
/Volumes/PortableSSD/MacNative/MacNativeGames/tools/switch2/sync.sh

# rebuild the TotK 1.4.3 app from the current checkout (~10 min, ad-hoc signed)
/Volumes/PortableSSD/MacNative/MacNativeGames/tools/switch2/rebuild-totk.sh
# rebuild the BotW 1.9.0 app the same way
/Volumes/PortableSSD/MacNative/MacNativeGames/tools/switch2/rebuild-botw.sh

# after a manual relink, install the binary into the app and re-sign:
#   cp build/totk-native-v143 "<app>/Contents/MacOS/TOTK"
#   codesign --force --deep -s - "<app>"
```

`sync.sh` stops on a rebase conflict and prints the fix (`git add … && git rebase
--continue`, or `git rebase --abort`); it never pushes a half-finished rebase.

## Checking that what runs is current

```sh
git rev-list --count main..upstream/main     # 0 = main is current
git log --oneline -1 switch2-pro2            # our commits on top
git status --short                            # only .workbuddy/ and backup/ may appear
ls -l "/Volumes/PortableSSD/MacNative/output/Tears of the Kingdom 1.4.3.app/Contents/MacOS/TOTK"
# the binary's timestamp must be later than the last rebuild/relink
```

## Where the feature touches the tree

New files (safe from upstream edits):

- `shared/runtime/switch2_ble.m`, `switch2_ble.h`, `switch2_proto.h`, `switch2_compat.h`
- symlinks `games/{totk,oot,acnh,eow}/runtime/switch2_*` -> `../../../shared/runtime/…`

Hooks in shared runtime (small insertions, review these first on conflicts):

- `shared/runtime/gamepad.m` — include + weak externs, first-frame start/hook, merge block
  and `gamepad_game_hid_input()` so prompts follow the controller
- `shared/runtime/gamepad_core.h` — `switch2_pad_present()` makes auto-detection say Switch
- `shared/runtime/gamepad_feedback.m` — forwards rumble to the BLE link

Build and docs (upstream moves these most often, expect conflicts here):

- `games/{totk,oot,acnh,eow}/Makefile` — `SW2_SRC`, `$(SW2_SRC)` in the clang lines,
  `SW2_LIBS` (`-framework CoreBluetooth -framework IOBluetooth`)
- `build_app.py` — `NSBluetoothAlwaysUsageDescription` in the generated Info.plist
- `docs/controls.md`, `docs/controls.zh-CN.md` — one paragraph each

## If the rebase gets painful

The feature is one commit; replay it from the patch instead:

```sh
git switch main && git fetch upstream && git merge --ff-only upstream/main
git switch -c switch2-pro2-replay
git apply --3way /Volumes/PortableSSD/MacNative/output/sw2-pro2.patch
```

Regenerate the bundle after changing the branch:

```sh
git diff main..switch2-pro2 > /Volumes/PortableSSD/MacNative/output/sw2-pro2.patch
```

## Known gaps

- The controller's Home, Capture, C and back buttons are not mapped (the runtime has no
  slots for them).
- Bluetooth pairing and permissions happen inside the game (first frame starts the scan;
  the system asks for Bluetooth access once per bundle).
- Single controller per game process, single player; no Joy-Con 2 support.
