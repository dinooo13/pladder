#!/usr/bin/env bash
# Says whether main can be released: this is a Mac, the checkout is on main
# and level with origin/main, CI, Docs and Scripts are green on its commit, no
# Release run is open, the last tag is on origin, and something the build
# reads changed since it. release.yml refuses a release on its own terms too;
# this stops before anyone is asked to approve one.
#
# Usage: scripts/release-preflight.sh [--force]
#   --force   go on although nothing the build reads changed since the last tag
#
# Read only, apart from fetching main and the tags. One line per check, PASS
# or STOP; the first STOP ends it. Exit 0 when main can be released, 1 when a
# check stopped it, 2 on bad usage or a missing tool.
set -euo pipefail
for arg in "$@"; do
	case "$arg" in -h | --help) sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;; esac
done

REPO=dinooo13/pladder
WORKFLOWS=(CI Docs Scripts)

force=false
case "$*" in
"") ;;
--force) force=true ;;
*)
	echo "usage: scripts/release-preflight.sh [--force]" >&2
	exit 2
	;;
esac
for tool in git gh awk sed; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "release-preflight.sh: $tool is missing" >&2
		exit 2
	fi
done
cd "$(dirname "$0")/.."

line() { printf '%s  %-11s  %s\n' "$1" "$2" "$3"; }
pass() { line PASS "$1" "$2"; }
stop() {
	line STOP "$1" "$2"
	exit 1
}

# mac
if [[ "$(uname -s)" != Darwin ]]; then
	stop mac "this is $(uname -s); scripts/check-release.sh needs macOS for half its checks"
fi
pass mac "$(sw_vers -productVersion 2>/dev/null || uname -r)"

# branch
branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != main ]]; then
	stop branch "on $branch; a release starts from main"
fi
pass branch main

# up-to-date
# --tags: the workflow tags a commit this checkout may already have, and the
# last tag below must be the remote's.
if ! git fetch --quiet --tags origin main; then
	stop up-to-date "git fetch origin main failed"
fi
head=$(git rev-parse HEAD)
remote=$(git rev-parse FETCH_HEAD)
if [[ "$head" != "$remote" ]]; then
	ahead=$(git rev-list --count FETCH_HEAD..HEAD)
	behind=$(git rev-list --count HEAD..FETCH_HEAD)
	stop up-to-date "main is $ahead ahead of and $behind behind origin/main; pull or push first"
fi
pass up-to-date "${head:0:7} is origin/main"

# checks
if ! runs=$(gh run list -R "$REPO" --commit "$head" --limit 100 --json workflowName,status,conclusion,url \
	--jq '.[] | "\(.workflowName)\t\(.status)\t\(.url)\t\(.conclusion)"'); then
	stop checks "gh run list failed"
fi
for workflow in "${WORKFLOWS[@]}"; do
	# gh lists the newest run first; a rerun's result is the one that counts.
	run=$(awk -F '\t' -v w="$workflow" '$1 == w { print; exit }' <<<"$runs")
	if [[ -z "$run" ]]; then
		stop checks "$workflow has no run on ${head:0:7}"
	fi
	# conclusion is empty until a run completes, and read folds an empty field
	# between tabs, so it comes last.
	IFS=$'\t' read -r _ status url conclusion <<<"$run"
	if [[ "$status" != completed ]]; then
		stop checks "$workflow is $status on ${head:0:7}: $url"
	fi
	if [[ "$conclusion" != success ]]; then
		stop checks "$workflow ended $conclusion on ${head:0:7}: $url"
	fi
done
pass checks "$(printf '%s, ' "${WORKFLOWS[@]}" | sed 's/, $//') green on ${head:0:7}"

# no-open-run
if ! open=$(gh run list -R "$REPO" --workflow release.yml --limit 20 --json status,displayTitle,url \
	--jq '.[] | select(.status != "completed") | "\(.displayTitle), \(.status): \(.url)"'); then
	stop no-open-run "gh run list failed"
fi
if [[ -n "$open" ]]; then
	stop no-open-run "$(head -n 1 <<<"$open")"
fi
pass no-open-run "no Release run is open"

# last-tag
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)
if [[ -z "$last" ]]; then
	stop last-tag "no v* tag reaches ${head:0:7}"
fi
if [[ -z "$(git ls-remote --tags origin "refs/tags/$last")" ]]; then
	stop last-tag "$last is a local tag origin does not have; delete it with git tag -d $last"
fi
if ! last_draft=$(gh release view "$last" -R "$REPO" --json isDraft --jq .isDraft 2>&1); then
	if [[ "$last_draft" == *"release not found"* ]]; then
		stop last-tag "$last has no release; a run that failed left its tag, which is the maintainer's to delete"
	fi
	stop last-tag "gh release view $last failed: $last_draft"
fi
if [[ "$last_draft" == true ]]; then
	stop last-tag "$last is an unpublished draft; publishing it, or deleting it and its tag, is the maintainer's"
fi
if [[ "$last_draft" != false ]]; then
	stop last-tag "gh release view $last returned: $last_draft"
fi
pass last-tag "$last"

# changes
# The list release.yml's own check reads, from the commit being released, so
# the two can never disagree.
paths=()
while IFS= read -r path; do paths+=("$path"); done < <(git show HEAD:.github/workflows/release.yml | awk '
	/git diff --quiet "\$last" HEAD -- \\$/ { on = 1; next }
	on { line = $0; done = (line !~ /\\$/); sub(/; then$/, "", line); sub(/[ \t]*\\$/, "", line); print line; if (done) exit }
' | tr -s ' \t' '\n' | sed '/^$/d')
if [[ ${#paths[@]} -eq 0 ]]; then
	stop changes "cannot read the source paths from .github/workflows/release.yml"
fi
if git diff --quiet "$last" HEAD -- "${paths[@]}"; then
	if [[ "$force" != true ]]; then
		stop changes "nothing the build reads changed since $last; --force releases anyway"
	fi
	pass changes "nothing the build reads changed since $last, forced"
else
	pass changes "$(git diff --name-only "$last" HEAD -- "${paths[@]}" | wc -l | tr -d ' ') files the build reads changed since $last"
fi

echo
echo "Ready: ${head:0:7}, last tag $last."
