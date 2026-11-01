#!/usr/bin/env bash
# One entry point for ACE verification. CI calls this same script.
# Modes: build | unit | db | boot | all
# Does not fetch, attach, or commit client DAT files. Does not run DatLoader tests.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/verify-ace"
EVIDENCE="$CACHE/evidence"
UNIT_FILTER='FullyQualifiedName~ACE.Server.Tests.SkillFormulaTests|FullyQualifiedName~ACE.Server.Tests.Physics.SphereTests'
SERVER_DLL="$REPO_ROOT/Source/ACE.Server/bin/x64/Release/net10.0/ACE.Server.dll"
WORLD_ZIP_BYTES_0_9_295=19580578

mkdir -p "$CACHE" "$EVIDENCE"
cd "$REPO_ROOT"

ensure_dotnet() {
  if ! command -v dotnet >/dev/null 2>&1; then
    if [[ -x "${HOME}/.dotnet/dotnet" ]]; then
      export DOTNET_ROOT="${HOME}/.dotnet"
      export PATH="${HOME}/.dotnet:${PATH}"
    fi
  fi
  if ! command -v dotnet >/dev/null 2>&1; then
    echo "verify-ace: dotnet is not on PATH" >&2
    return 1
  fi
  export DOTNET_CLI_TELEMETRY_OPTOUT=1
  export DOTNET_NOLOGO=1
}

pick_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
    return 0
  fi
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
    return 0
  fi
  DOCKER=()
  return 1
}

mysql_password() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["MySql"]["Authentication"]["Password"], end="")' \
    "$REPO_ROOT/AppVeyor/Config.js"
}

write_mysql_cnf() {
  local password="$1"
  local cnf="$CACHE/mysql-client.cnf"
  umask 077
  cat >"$cnf" <<EOF
[client]
host=127.0.0.1
port=3306
user=root
password=${password}
protocol=TCP
max_allowed_packet=64M
EOF
  chmod 600 "$cnf"
  printf '%s\n' "$cnf"
}

mysql_query_ok() {
  local cnf="$1"
  mysql --defaults-extra-file="$cnf" -N -e 'SELECT 1' >/dev/null 2>"$CACHE/mysql-query.err"
}

show_mysql_client_error() {
  if [[ -s "$CACHE/mysql-query.err" ]]; then
    echo "verify-ace: mysql client error:" >&2
    cat "$CACHE/mysql-query.err" >&2
  fi
}

port_3306_open() {
  timeout 2 bash -c 'echo >/dev/tcp/127.0.0.1/3306' >/dev/null 2>&1
}

ensure_mysql_client() {
  if command -v mysql >/dev/null 2>&1; then
    return 0
  fi
  echo "verify-ace: installing mysql-client" >&2
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-client
}

copy_ci_config() {
  cp "$REPO_ROOT/AppVeyor/Config.js" "$REPO_ROOT/Source/ACE.Server/Config.js"
  if git -C "$REPO_ROOT" diff --cached --name-only | grep -qx 'Source/ACE.Server/Config.js'; then
    echo "verify-ace: Source/ACE.Server/Config.js is staged. This script will not commit it." >&2
    return 1
  fi
}

require_build_output() {
  if [[ ! -f "$SERVER_DLL" ]]; then
    echo "verify-ace: missing $SERVER_DLL. Run: $0 build" >&2
    return 1
  fi
}

cmd_build() {
  ensure_dotnet || return 1
  echo "===== dotnet --info ====="
  dotnet --info
  echo "===== dotnet restore Source/ACE.sln ====="
  dotnet restore Source/ACE.sln || return 1
  echo "===== dotnet build Source/ACE.sln -c Release -p:Platform=x64 --no-restore ====="
  dotnet build Source/ACE.sln -c Release -p:Platform=x64 --no-restore || return 1
  if git -C "$REPO_ROOT" diff --name-only -- Source/ACE.Server/ServerBuildInfo_Dynamic.cs | grep -q .; then
    echo "verify-ace: build modified ServerBuildInfo_Dynamic.cs" >&2
    return 1
  fi
}

unit_passed_line() {
  local file="$1"
  local passed="$2"
  grep -E "Failed:[[:space:]]+0, Passed:[[:space:]]+${passed}, Skipped:[[:space:]]+0, Total:[[:space:]]+${passed}" "$file"
}

explain_no_tests() {
  local label="$1"
  local diag_dir="$EVIDENCE/${label}-diag"
  rm -rf "$diag_dir"
  mkdir -p "$diag_dir"
  echo "verify-ace: ${label}: dotnet test exited 0 without a passing summary. Capturing testhost diag."
  dotnet test Source/ACE.Server.Tests -c Release -p:Platform=x64 --no-build \
    --filter "$UNIT_FILTER" \
    --diag "$diag_dir/diag.log" >/dev/null 2>&1 || true
  local hit
  hit=$(grep -R -m1 -F "must have the same version" "$diag_dir" || true)
  if [[ -n "$hit" ]]; then
    echo "verify-ace: ${label} discovery error:"
    echo "$hit"
  else
    echo "verify-ace: ${label}: diag did not contain the MSTest version line. See $diag_dir"
  fi
}

cmd_unit() {
  ensure_dotnet || return 1
  require_build_output || return 1
  local log="$EVIDENCE/unit.txt"
  local starter_log="$EVIDENCE/startergear.txt"
  echo "===== unit filter ====="
  set +e
  dotnet test Source/ACE.Server.Tests -c Release -p:Platform=x64 --no-build \
    --filter "$UNIT_FILTER" \
    --logger "trx;LogFileName=unit.trx" | tee "$log"
  local unit_rc=${PIPESTATUS[0]}
  set -e
  echo "verify-ace: unit dotnet exit ${unit_rc}"
  local unit_ok=0
  if unit_passed_line "$log" 9 >/dev/null; then
    unit_ok=1
    echo "verify-ace: unit filter 9 passed, 0 failed"
  else
    echo "verify-ace: unit filter did not report 9 passed and 0 failed" >&2
    explain_no_tests unit || true
  fi

  echo "===== StarterGearTests (separate from the 9) ====="
  set +e
  dotnet test Source/ACE.Server.Tests -c Release -p:Platform=x64 --no-build \
    --filter "FullyQualifiedName~ACE.Server.Tests.StarterGearTests" \
    --logger "trx;LogFileName=startergear.trx" | tee "$starter_log"
  local starter_rc=${PIPESTATUS[0]}
  set -e
  echo "verify-ace: StarterGearTests dotnet exit ${starter_rc}"
  if unit_passed_line "$starter_log" 1 >/dev/null; then
    echo "verify-ace: StarterGearTests 1 passed, 0 failed"
  else
    echo "verify-ace: StarterGearTests did not report 1 passed and 0 failed" >&2
    if grep -q "No test is available" "$starter_log"; then
      echo "verify-ace: StarterGearTests discovery failed with the same 'No test is available' output"
    fi
  fi

  if (( unit_ok == 0 )); then
    return 1
  fi
  return 0
}

start_mysql_container() {
  local password="$1"
  pick_docker || {
    echo "verify-ace: MySQL is not accepting connections on 127.0.0.1:3306 and docker is not usable" >&2
    return 1
  }
  echo "verify-ace: starting mysql:8.0 container ace-verify-mysql" >&2
  "${DOCKER[@]}" rm -f ace-verify-mysql >/dev/null 2>&1 || true
  if ! "${DOCKER[@]}" run -d --name ace-verify-mysql \
    -e MYSQL_ROOT_PASSWORD="$password" \
    -e MYSQL_ROOT_HOST='%' \
    -p 3306:3306 \
    mysql:8.0 \
    --max-allowed-packet=67108864; then
    echo "verify-ace: docker run mysql:8.0 failed" >&2
    return 1
  fi
  printf 'ace-verify-mysql\n' >"$CACHE/mysql-container-started"
}

ensure_mysql() {
  ensure_mysql_client || return 1
  local password cnf
  password=$(mysql_password)
  cnf=$(write_mysql_cnf "$password")
  if mysql_query_ok "$cnf"; then
    echo "verify-ace: using MySQL already listening on 127.0.0.1:3306" >&2
    printf '%s\n' "$cnf"
    return 0
  fi
  if port_3306_open; then
    echo "verify-ace: 127.0.0.1:3306 is open, so this run will not start another mysql:8.0 container" >&2
    show_mysql_client_error
  else
    start_mysql_container "$password" || return 1
  fi
  local i
  for i in $(seq 1 90); do
    if mysql_query_ok "$cnf"; then
      echo "verify-ace: MySQL accepted a query after ${i} tries" >&2
      printf '%s\n' "$cnf"
      return 0
    fi
    if (( i == 1 || i == 5 )); then
      show_mysql_client_error
    fi
    sleep 2
  done
  echo "verify-ace: MySQL did not accept queries on 127.0.0.1:3306" >&2
  show_mysql_client_error
  return 1
}

apply_sql_file() {
  local cnf="$1"
  local database="$2"
  local sql="$3"
  echo "verify-ace: applying ${sql} ${database:+to }${database}"
  local log="$EVIDENCE/mysql-$(basename "$sql").log"
  if [[ -n "$database" ]]; then
    if ! mysql --defaults-extra-file="$cnf" "$database" <"$sql" >"$log" 2>&1; then
      echo "verify-ace: mysql failed on $sql" >&2
      tail -n 40 "$log" >&2
      return 1
    fi
  else
    if ! mysql --defaults-extra-file="$cnf" <"$sql" >"$log" 2>&1; then
      echo "verify-ace: mysql failed on $sql" >&2
      tail -n 40 "$log" >&2
      return 1
    fi
  fi
}

cache_world_sql() {
  local ver zip url sql_dir sql
  ver=$(tr -d '[:space:]' <"$REPO_ROOT/AppVeyor/dbversion.txt")
  if [[ -z "$ver" ]]; then
    echo "verify-ace: AppVeyor/dbversion.txt is empty" >&2
    return 1
  fi
  zip="$CACHE/ACE-World-Database-v${ver}.sql.zip"
  url="https://github.com/ACEmulator/ACE-World-16PY-Patches/releases/download/v${ver}/ACE-World-Database-v${ver}.sql.zip"
  if [[ ! -f "$zip" ]]; then
    echo "verify-ace: downloading $url" >&2
    curl -fL --retry 3 -o "${zip}.partial" "$url"
    mv "${zip}.partial" "$zip"
  else
    echo "verify-ace: using cached $zip" >&2
  fi
  if [[ "$ver" == "0.9.295" ]]; then
    local size
    size=$(stat -c '%s' "$zip")
    if [[ "$size" != "$WORLD_ZIP_BYTES_0_9_295" ]]; then
      echo "verify-ace: world zip is ${size} bytes, expected ${WORLD_ZIP_BYTES_0_9_295}" >&2
      return 1
    fi
    echo "verify-ace: world zip size ${size} matches v0.9.295" >&2
  fi
  sql_dir="$CACHE/world-v${ver}"
  sql="$sql_dir/ACE-World-Database-v${ver}.sql"
  if [[ ! -f "$sql" ]]; then
    mkdir -p "$sql_dir"
    unzip -o "$zip" -d "$sql_dir" >/dev/null
  fi
  if [[ ! -f "$sql" ]]; then
    echo "verify-ace: expected SQL file missing: $sql" >&2
    return 1
  fi
  printf '%s\n' "$sql"
}

apply_database() {
  local cnf="$1"
  apply_sql_file "$cnf" "" "$REPO_ROOT/Database/Create/create_mysql.sql" || return 1
  apply_sql_file "$cnf" "" "$REPO_ROOT/Database/Base/AuthenticationBase.sql" || return 1
  apply_sql_file "$cnf" "" "$REPO_ROOT/Database/Base/ShardBase.sql" || return 1
  apply_sql_file "$cnf" "" "$REPO_ROOT/Database/Base/WorldBase.sql" || return 1

  shopt -s nullglob
  local auth=( "$REPO_ROOT"/Database/Updates/Authentication/*.sql )
  shopt -u nullglob
  if ((${#auth[@]} == 0)); then
    echo "verify-ace: no Database/Updates/Authentication/*.sql files"
  else
    local sql
    for sql in "${auth[@]}"; do
      apply_sql_file "$cnf" ace_auth "$sql" || return 1
    done
  fi

  local shard_sql
  while IFS= read -r shard_sql; do
    [[ -z "$shard_sql" ]] && continue
    apply_sql_file "$cnf" ace_shard "$shard_sql" || return 1
  done < <(find "$REPO_ROOT/Database/Updates/Shard" -maxdepth 1 -name '*.sql' | sort)

  local world_sql
  world_sql=$(cache_world_sql) || return 1
  apply_sql_file "$cnf" "" "$world_sql" || return 1
}

report_trx() {
  local trx="$1"
  python3 - "$trx" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    tree = ET.parse(path)
except FileNotFoundError:
    print(f"verify-ace: trx missing: {path}")
    sys.exit(0)

root = tree.getroot()

def local(tag):
    return tag.split("}", 1)[-1]

rows = []
for el in root.iter():
    if local(el.tag) != "UnitTestResult":
        continue
    name = el.attrib.get("testName", "")
    outcome = el.attrib.get("outcome", "")
    message = ""
    for child in el.iter():
        if local(child.tag) == "Message" and child.text:
            message = child.text.strip()
            break
    rows.append((name, outcome, message))

if not rows:
    print(f"verify-ace: trx has no UnitTestResult rows: {path}")
    sys.exit(0)

def known_path_bug(message):
    if not message:
        return False
    has_config = "Config.js" in message and "ACE.Server" in message
    has_backslash = "\\.." in message or "..\\" in message or "\\\\" in message
    missing = "Could not find a part of the path" in message or "Could not find file" in message
    return has_config and has_backslash and missing

failed = 0
for name, outcome, message in rows:
    if outcome == "Passed":
        print(f"DB {name} PASS")
        continue
    label = "FAIL"
    if known_path_bug(message):
        label = "BLOCKED (known)"
    failed = 1
    print(f"DB {name} {label}")
    print("raw error:")
    print(message if message else "(no message in trx)")
sys.exit(failed)
PY
}

find_trx() {
  local name="$1"
  local found
  found=$(find "$REPO_ROOT" -name "$name" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
  printf '%s\n' "$found"
}

cmd_db() {
  ensure_dotnet || return 1
  require_build_output || return 1
  local cnf
  cnf=$(ensure_mysql) || return 1
  copy_ci_config || return 1
  apply_database "$cnf" || return 1

  local db_log="$EVIDENCE/db-database.txt"
  local startup_log="$EVIDENCE/db-startup.txt"
  echo "===== ACE.Database.Tests ====="
  set +e
  dotnet test Source/ACE.Database.Tests -c Release -p:Platform=x64 --no-build \
    --logger "trx;LogFileName=db-database.trx" | tee "$db_log"
  local db_rc=${PIPESTATUS[0]}
  echo "===== StartupTests ====="
  dotnet test Source/ACE.Server.Tests -c Release -p:Platform=x64 --no-build \
    --filter "FullyQualifiedName~ACE.Server.Tests.StartupTests" \
    --logger "trx;LogFileName=db-startup.trx" | tee "$startup_log"
  local startup_rc=${PIPESTATUS[0]}
  set -e
  echo "verify-ace: ACE.Database.Tests dotnet exit ${db_rc}"
  echo "verify-ace: StartupTests dotnet exit ${startup_rc}"

  local db_trx startup_trx
  db_trx=$(find_trx db-database.trx)
  startup_trx=$(find_trx db-startup.trx)
  local report_rc=0
  if [[ -n "$db_trx" ]]; then
    report_trx "$db_trx" || report_rc=$?
  else
    echo "verify-ace: no db-database.trx. Console output is the result."
    report_rc=1
  fi
  if [[ -n "$startup_trx" ]]; then
    report_trx "$startup_trx" || report_rc=$?
  else
    echo "verify-ace: no db-startup.trx. Console output is the result."
    report_rc=1
  fi

  if grep -q "No test is available" "$db_log" "$startup_log"; then
    echo "verify-ace: db tests were not discovered. This is not the Linux Config.js backslash result; the tests did not start."
    explain_no_tests db || true
    return 1
  fi
  if (( db_rc != 0 || startup_rc != 0 || report_rc != 0 )); then
    return 1
  fi
  return 0
}

kill_pid_file() {
  local pidfile="$1"
  [[ -f "$pidfile" ]] || return 0
  local pid
  pid=$(cat "$pidfile")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

cmd_boot() {
  ensure_dotnet || return 1
  require_build_output || return 1
  copy_ci_config || return 1
  local outdir
  outdir=$(dirname "$SERVER_DLL")
  cp "$REPO_ROOT/AppVeyor/Config.js" "$outdir/Config.js"

  local log="$EVIDENCE/boot-$(date -u +%Y%m%dT%H%M%SZ).log"
  local pidfile="$CACHE/boot.pid"
  echo "verify-ace: boot log $log"
  (
    cd "$outdir"
    exec dotnet "$SERVER_DLL"
  ) >"$log" 2>&1 &
  local pid=$!
  echo "$pid" >"$pidfile"

  local i
  for i in $(seq 1 120); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "verify-ace: server process ${pid} exited after ${i}s"
      break
    fi
    sleep 1
  done
  local still=0
  if kill -0 "$pid" 2>/dev/null; then
    still=1
    echo "verify-ace: server process ${pid} still running at 120s; stopping it"
  fi
  kill_pid_file "$pidfile"

  echo "===== boot log ====="
  cat "$log"
  echo "===== boot classification ====="
  if grep -F -q "ACE will not run properly without this properly configured" "$log" \
    || grep -F -q "This needs to be corrected in order for Landblocks to load" "$log"; then
    echo "BOOT: needs DATs (Charles-only)"
    echo "BOOT status: SKIPPED-NEEDS-DATS"
    echo "BOOT proving line:"
    grep -F -n "ACE will not run properly without this properly configured" "$log" || true
    grep -F -n "This needs to be corrected in order for Landblocks to load" "$log" || true
    return 0
  fi
  if (( still == 1 )) && grep -F -q "Starting ACEmulator" "$log"; then
    echo "BOOT status: started"
    grep -F -n "Starting ACEmulator" "$log" || true
    grep -F -n "Binding ConnectionListener" "$log" || true
    return 0
  fi
  echo "BOOT status: not started and not SKIPPED-NEEDS-DATS"
  echo "verify-ace: the log does not contain the DAT skip line, and the process did not stay up after 'Starting ACEmulator'"
  return 1
}

usage() {
  echo "usage: $0 [build|unit|db|boot|all]" >&2
  return 2
}

mode="${1:-}"
case "$mode" in
  build) cmd_build ;;
  unit) cmd_unit ;;
  db) cmd_db ;;
  boot) cmd_boot ;;
  all)
    set +e
    cmd_build
    build_rc=$?
    cmd_unit
    unit_rc=$?
    cmd_db
    db_rc=$?
    cmd_boot
    boot_rc=$?
    set -e
    echo "verify-ace all: build=${build_rc} unit=${unit_rc} db=${db_rc} boot=${boot_rc}"
    if (( build_rc != 0 || unit_rc != 0 || db_rc != 0 || boot_rc != 0 )); then
      exit 1
    fi
    ;;
  *) usage; exit $? ;;
esac
