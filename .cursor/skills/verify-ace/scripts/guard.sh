#!/usr/bin/env bash
# Fail the PR if the diff against origin/master touches protected ACE paths.
# ace/sync-upstream prints those paths as a NOTICE and does not fail for them.
# Workflow runner rules apply on every branch, including ace/sync-upstream:
# any workflow other than .github/workflows/dat-tests.yml that contains
# self-hosted or ace-dats fails, and dat-tests.yml fails unless its only
# trigger is workflow_dispatch.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)

path_is_protected() {
  local f="$1"
  f="${f#./}"
  case "$f" in
    Source/ACE.Server/ServerBuildInfo_Dynamic.cs) return 0 ;;
    AppVeyor/dbversion.txt) return 0 ;;
    Source/ACE.Server/Network|Source/ACE.Server/Network/*) return 0 ;;
    Source/Settings.StyleCop) return 0 ;;
    .editorconfig) return 0 ;;
    docker.env) return 0 ;;
    *.dat) return 0 ;;
    Dats|Dats/*) return 0 ;;
    db-data|db-data/*) return 0 ;;
    Logs|Logs/*) return 0 ;;
    Config|Config/*) return 0 ;;
    Source/ACE.Server/Config.js) return 0 ;;
    *) return 1 ;;
  esac
}

collect_csproj_hits() {
  local base="$1"
  git -C "$REPO_ROOT" diff -U0 --no-color "${base}...HEAD" -- '*.csproj' \
    | awk '
        /^\+\+\+/ || /^---/ { next }
        /^[+-]/ {
          body = substr($0, 2)
          if (body ~ /<Nullable>/ || body ~ /<ImplicitUsings>/ || body ~ /StyleCop/) {
            print
          }
        }
      '
}

collect_new_policy_files() {
  local base="$1"
  local status path old new base_name
  while IFS=$'\t' read -r status path; do
    [[ -z "${path:-}" ]] && continue
    base_name=$(basename "$path")
    if [[ "$base_name" == "Directory.Build.props" || "$base_name" == "stylecop.json" ]]; then
      printf '%s\n' "$path"
    fi
  done < <(git -C "$REPO_ROOT" diff --name-status --diff-filter=A "${base}...HEAD")

  while IFS=$'\t' read -r status old new; do
    [[ -z "${new:-}" ]] && continue
    base_name=$(basename "$new")
    if [[ "$base_name" == "Directory.Build.props" || "$base_name" == "stylecop.json" ]]; then
      printf '%s\n' "$new"
    fi
  done < <(git -C "$REPO_ROOT" diff --name-status --diff-filter=R "${base}...HEAD")
}

# Print "path:line:text" for workflow files at HEAD, other than dat-tests.yml,
# whose contents contain self-hosted or ace-dats.
collect_workflow_runner_hits() {
  local f hits
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == ".github/workflows/dat-tests.yml" ]] && continue
    hits=$(git -C "$REPO_ROOT" show "HEAD:$f" | grep -n -F -e 'self-hosted' -e 'ace-dats' || true)
    if [[ -n "$hits" ]]; then
      local line
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf '%s:%s\n' "$f" "$line"
      done <<<"$hits"
    fi
  done < <(git -C "$REPO_ROOT" ls-tree -r --name-only HEAD -- .github/workflows)
}

# Exit 0 when dat-tests.yml is absent or its only trigger is workflow_dispatch.
# Prints one reason line either way.
dat_tests_trigger_ok() {
  if ! git -C "$REPO_ROOT" cat-file -e HEAD:.github/workflows/dat-tests.yml 2>/dev/null; then
    echo "dat-tests.yml is absent"
    return 0
  fi
  git -C "$REPO_ROOT" show HEAD:.github/workflows/dat-tests.yml | python3 -c '
import sys
import re

lines = sys.stdin.read().splitlines()
on_re = re.compile(r"^(?P<q>[\"'"'"']?)on(?P=q)\s*:\s*(?P<rest>.*?)\s*(?:#.*)?$")
on_i = None
rest = ""
for i, line in enumerate(lines):
    m = on_re.match(line)
    if m:
        on_i = i
        rest = m.group("rest").strip()
        break
if on_i is None:
    print("no top-level on: key")
    sys.exit(1)

def only(names):
    return names == ["workflow_dispatch"]

def bare(token):
    return token.split("#", 1)[0].strip().strip("\"'"'"'")

if rest:
    if bare(rest) == "workflow_dispatch":
        print("only workflow_dispatch")
        sys.exit(0)
    if rest.startswith("[") and rest.endswith("]"):
        parts = [bare(p) for p in rest[1:-1].split(",") if bare(p)]
        if only(parts):
            print("only workflow_dispatch")
            sys.exit(0)
        print("triggers: " + ",".join(parts))
        sys.exit(1)
    print("triggers: " + bare(rest))
    sys.exit(1)

def indent_of(ln):
    n = 0
    for ch in ln:
        if ch == " ":
            n += 1
        elif ch == "\t":
            n += 2
        else:
            break
    return n

content = []
for line in lines[on_i + 1:]:
    if line.strip() == "":
        continue
    if not line.startswith(" ") and not line.startswith("\t"):
        break
    if line.lstrip().startswith("#"):
        continue
    content.append(line)
if not content:
    print("on: block is empty")
    sys.exit(1)
min_indent = min(indent_of(ln) for ln in content)
names = []
for ln in content:
    if indent_of(ln) != min_indent:
        continue
    s = ln.strip()
    if s.startswith("- "):
        item = bare(s[2:])
        item = item.split(":", 1)[0].strip()
        names.append(item)
    else:
        names.append(bare(s.split(":", 1)[0]))
if only(names):
    print("only workflow_dispatch")
    sys.exit(0)
print("triggers: " + ",".join(names))
sys.exit(1)
'
}

guard_main() {
  cd "$REPO_ROOT"
  export GIT_TERMINAL_PROMPT=0

  if ! git fetch --no-tags origin master; then
    echo "guard: git fetch origin master failed" >&2
    return 1
  fi

  local base="origin/master"
  if ! git rev-parse --verify --quiet "$base" >/dev/null; then
    echo "guard: $base does not exist after fetch" >&2
    return 1
  fi

  local branch="${GUARD_HEAD_BRANCH:-}"
  if [[ -z "$branch" ]]; then
    branch=$(git rev-parse --abbrev-ref HEAD)
  fi

  local protected=()
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if path_is_protected "$path"; then
      protected+=("$path")
    fi
  done < <(git diff --name-only "${base}...HEAD")

  local csproj_hits new_policy
  csproj_hits=$(collect_csproj_hits "$base" || true)
  new_policy=$(collect_new_policy_files "$base" || true)

  local workflow_hits trigger_msg trigger_rc
  workflow_hits=$(collect_workflow_runner_hits || true)
  set +e
  trigger_msg=$(dat_tests_trigger_ok)
  trigger_rc=$?
  set -e

  local notice=0
  if [[ "$branch" == "ace/sync-upstream" ]]; then
    notice=1
  fi

  if (( notice == 1 )); then
    echo "NOTICE: head branch is ace/sync-upstream. Protected paths are listed for Charles to review by hand."
    if ((${#protected[@]})); then
      printf 'NOTICE: %s\n' "${protected[@]}"
    fi
    if [[ -n "$csproj_hits" ]]; then
      echo "NOTICE: csproj lines:"
      printf '%s\n' "$csproj_hits"
    fi
    if [[ -n "$new_policy" ]]; then
      echo "NOTICE: new policy files:"
      printf '%s\n' "$new_policy"
    fi
    if ((${#protected[@]} == 0)) && [[ -z "$csproj_hits" ]] && [[ -z "$new_policy" ]]; then
      echo "NOTICE: no protected paths in origin/master...HEAD"
    fi
  fi

  local failed=0
  if (( notice == 0 )); then
    if ((${#protected[@]})); then
      echo "guard: protected path in origin/master...HEAD:" >&2
      printf 'guard: %s\n' "${protected[@]}" >&2
      failed=1
    fi
    if [[ -n "$csproj_hits" ]]; then
      echo "guard: csproj diff adds or removes Nullable, ImplicitUsings, or StyleCop:" >&2
      printf '%s\n' "$csproj_hits" >&2
      failed=1
    fi
    if [[ -n "$new_policy" ]]; then
      echo "guard: new Directory.Build.props or stylecop.json:" >&2
      printf '%s\n' "$new_policy" >&2
      failed=1
    fi
  fi
  if [[ -n "$workflow_hits" ]]; then
    echo "guard: workflow file other than .github/workflows/dat-tests.yml contains self-hosted or ace-dats:" >&2
    printf '%s\n' "$workflow_hits" >&2
    failed=1
  fi
  if (( trigger_rc != 0 )); then
    echo "guard: .github/workflows/dat-tests.yml must use only workflow_dispatch: ${trigger_msg}" >&2
    failed=1
  fi
  if (( failed )); then
    return 1
  fi

  echo "guard: clean. origin/master...HEAD does not touch a protected path (branch ${branch}). ${trigger_msg}."
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  guard_main "$@"
fi
