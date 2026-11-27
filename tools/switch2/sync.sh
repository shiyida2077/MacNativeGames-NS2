#!/bin/sh
# Bring main to upstream, then replay our one commit on top of it.
set -e
cd /Volumes/PortableSSD/MacNative/MacNativeGames
git fetch upstream --prune
git switch main
git merge --ff-only upstream/main
git push origin main
echo "main -> $(git log -1 --format='%h %s')"
git switch switch2-pro2
if ! git rebase main; then
  echo
  echo "rebase stopped on a conflict. Fix the files, then:"
  echo "  git add <files> && git rebase --continue"
  echo "or give up for now: git rebase --abort"
  exit 1
fi
echo "switch2-pro2 rebased: $(git log -1 --format='%h %s')"
git push --force-with-lease origin switch2-pro2
