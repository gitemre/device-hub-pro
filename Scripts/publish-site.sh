#!/usr/bin/env bash
# Publishes site/ to the gh-pages branch, which GitHub Pages serves at
# https://gitemre.github.io/device-hub-pro/. Run it from main after a change to site/
# has been merged. It commits the tree of site/ as it is in HEAD (not the working
# folder) on top of gh-pages and pushes; nothing in the checkout changes.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
remote=${1:-origin}

if [[ "$(git rev-parse --abbrev-ref HEAD)" != main ]]; then
  echo "publish-site: run this on main (the site is published from merged changes only)" >&2
  exit 1
fi

tree=$(git rev-parse HEAD:site)
git fetch -q "$remote" gh-pages 2>/dev/null || true
parent=$(git rev-parse -q --verify "$remote/gh-pages" || true)

if [[ -n "$parent" && "$(git rev-parse "$parent^{tree}")" == "$tree" ]]; then
  echo "publish-site: gh-pages already has this site"
  exit 0
fi

message="site: $(git rev-parse --short HEAD) $(git log -1 --format=%s HEAD)"
commit=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "$message")
git push "$remote" "$commit:refs/heads/gh-pages"
echo "publish-site: pushed $commit to gh-pages"
