# Switch 2 Pro Controller 2 on MacNativeGames — staying current

## The shape of the repo

- `upstream` = https://github.com/ly05010419/MacNativeGames.git (read only)
- `origin` = git@github.com:shiyida2077/MacNativeGames-NS2.git (your fork)
- `main` mirrors `upstream/main`, always fast-forward, never committed to
- `switch2-pro2` = `main` + a small commit stack: the controller support plus the docs/rules
  that go with it

So "latest upstream" and "our improvement" never mix inside `main`: the improvement is a
single commit that is rebased onto every new `main`.

## One command to sync

    /Volumes/PortableSSD/MacNative/MacNativeGames/tools/switch2/sync.sh

It does, in order:

    git fetch upstream --prune
    git switch main && git merge --ff-only upstream/main
    git push origin main                     # fork's main mirrors upstream
    git switch switch2-pro2 && git rebase main
    git push --force-with-lease origin switch2-pro2

If the rebase conflicts it stops and prints the fix (`git add ... && git rebase --continue`,
or `git rebase --abort`); nothing is pushed in that case.

## One command to rebuild an app from the current checkout

    /Volumes/PortableSSD/MacNative/MacNativeGames/tools/switch2/rebuild-totk.sh
    /Volumes/PortableSSD/MacNative/MacNativeGames/tools/switch2/rebuild-botw.sh

~5-10 min: build_app.py copies the checkout into the work tree, links the binary, rebuilds
the 16-20 GB bundle and signs it ad-hoc. The old app stays untouched until the build
succeeds. Both scripts write into /Volumes/PortableSSD/MacNative/output/.

## Updating the runtime of an existing app without re-packaging

The runtime is statically linked into the game's Mach-O, so a runtime-only update means
recompiling that one binary and swapping it in:

    /Volumes/PortableSSD/MacNative/MacNativeGames/tools/switch2/swap-runtime.sh \
      "/Volumes/PortableSSD/MacNative/output/Tears of the Kingdom 1.4.3.app" \
      "<work tree>/totk/build/totk-native-v143"

It replaces Contents/MacOS/<exe>, adds NSBluetoothAlwaysUsageDescription if missing, and
re-signs ad-hoc. Game data, saves and resources are untouched.

## Verify "what I run is the latest"

    cd /Volumes/PortableSSD/MacNative/MacNativeGames
    git rev-list --count main..upstream/main      # 0 = main is current
    git log --oneline -1 switch2-pro2              # our commit on top of it
    git status --short                             # only .workbuddy/ and backup/
    ls -l "/Volumes/PortableSSD/MacNative/output/Tears of the Kingdom 1.4.3.app/Contents/MacOS/TOTK"
    # TOTK's timestamp must be after the last rebuild-totk.sh run

## If rebase ever gets painful

The improvement is one commit, so replay is cheap:

    git switch main && git fetch upstream && git merge --ff-only upstream/main
    git switch -c switch2-pro2-replay
    git apply --3way /Volumes/PortableSSD/MacNative/output/sw2-pro2.patch

Regenerate the patch bundle after any change on the branch:

    git diff main..switch2-pro2 > /Volumes/PortableSSD/MacNative/output/sw2-pro2.patch

## Per-clone settings (already applied here, not global)

    git config --local user.name  "shiyida2077"
    git config --local user.email "168812181+shiyida2077@users.noreply.github.com"
    git config --local push.default current       # git push -> origin/<same branch>
    git config --local remote.pushDefault origin
    git config --local core.sshCommand "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts"
    # main tracks upstream/main for pulls; it is fast-forward only
