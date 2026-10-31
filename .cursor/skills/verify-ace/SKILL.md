---
name: verify-ace
description: "Drive ogmage78/ACE on Linux: build ACE.sln, run the pure server unit tests, load the public CI MySQL database, and boot ACE.Server headless with no client DATs. Use before opening or updating an ACE pull request, and quote the script output."
---

# Verify ACE

This skill proves the server emulator from a Linux checkout. The only entry point is `scripts/verify.sh`. GitHub Actions calls that same script. Do not fetch, attach, or commit client DAT files. Do not run `ACE.DatLoader.Tests`.

Repo root is four directories above `scripts/`. Run every command from the repo root. The script `cd`s there itself.

## Launch

Build once, then start MySQL and the server only through the script:

```bash
.cursor/skills/verify-ace/scripts/verify.sh build
.cursor/skills/verify-ace/scripts/verify.sh db
.cursor/skills/verify-ace/scripts/verify.sh boot
```

`build` prints `dotnet --info`, then runs `dotnet restore Source/ACE.sln` and `dotnet build Source/ACE.sln -c Release -p:Platform=x64 --no-restore`. It does not edit `Source/ACE.Server/ServerBuildInfo_Dynamic.cs`.

`db` uses MySQL already listening on `127.0.0.1:3306` when a query works with the root password in `AppVeyor/Config.js`. Otherwise it runs `mysql:8.0` as container `ace-verify-mysql`. It copies `AppVeyor/Config.js` to `Source/ACE.Server/Config.js` inside the workspace and never `git add`s that file. It applies `Database/Create/create_mysql.sql`, `Database/Base/{Authentication,Shard,World}Base.sql`, `Database/Updates/Authentication/*.sql`, `Database/Updates/Shard/*.sql` in name order, then the world release zip for the version in `AppVeyor/dbversion.txt`. The zip is cached under `${XDG_CACHE_HOME:-$HOME/.cache}/verify-ace/`. For `0.9.295` the zip must be `19580578` bytes from `https://github.com/ACEmulator/ACE-World-16PY-Patches/releases/download/v0.9.295/ACE-World-Database-v0.9.295.sql.zip`.

`boot` starts `dotnet` on `Source/ACE.Server/bin/x64/Release/net10.0/ACE.Server.dll` with that same CI `Config.js` copied next to the dll. It waits up to 120 seconds, copies the log to the evidence directory, stops the process it started, and prints one status:

- `BOOT status: started` when the process is still up at 120 seconds and the log contains `Starting ACEmulator` and does not contain a DAT failure line.
- `BOOT: needs DATs (Charles-only)` and `BOOT status: SKIPPED-NEEDS-DATS` when the log contains `ACE will not run properly without this properly configured` or `This needs to be corrected in order for Landblocks to load`. Exit code is 0. Quote the proving line.
- `BOOT status: not started and not SKIPPED-NEEDS-DATS` for any other outcome, including a crash before those lines. Exit code is non-zero. Quote the log. Do not relabel it.

Ready for `boot` means the Release dll exists and MySQL from `db` is still up. A database ping by itself is not a ready server.

## Doctor

Run this when a result looks wrong. It is read-only except for the diag file under the cache.

```bash
dotnet --info
git diff --name-only -- Source/ACE.Server/ServerBuildInfo_Dynamic.cs AppVeyor/dbversion.txt
git diff --cached --name-only -- Source/ACE.Server/Config.js
test -f Source/ACE.Server/bin/x64/Release/net10.0/ACE.Server.dll && echo build-present
```

`dotnet test` can exit 0 after printing `No test is available`. That is not a pass. On this tree `Source/ACE.Server.Tests/ACE.Server.Tests.csproj` and `Source/ACE.Database.Tests/ACE.Database.Tests.csproj` reference `MSTest.TestAdapter` `4.4.0` and `MSTest.TestFramework` `4.4.1`. The adapter refuses to load when those versions differ, so discovery finds nothing. `verify.sh unit` exits non-zero unless the filter summary is exactly 9 passed and 0 failed. Do not report a pass from an exit code alone. Do not bump those packages in a PR whose file list does not include the csproj files.

A unit run that passed the filter and a StarterGear run are separate. StarterGear is not one of the 9.

## Drive

```bash
.cursor/skills/verify-ace/scripts/verify.sh build
.cursor/skills/verify-ace/scripts/verify.sh unit
.cursor/skills/verify-ace/scripts/verify.sh db
.cursor/skills/verify-ace/scripts/verify.sh boot
.cursor/skills/verify-ace/scripts/verify.sh all
```

`unit` runs, with `--no-build`:

```bash
dotnet test Source/ACE.Server.Tests -c Release -p:Platform=x64 --no-build \
  --filter "FullyQualifiedName~ACE.Server.Tests.SkillFormulaTests|FullyQualifiedName~ACE.Server.Tests.Physics.SphereTests" \
  --logger "trx;LogFileName=unit.trx"
```

Then the same command with filter `FullyQualifiedName~ACE.Server.Tests.StarterGearTests` and `startergear.trx`. Quote both.

`db` runs `ACE.Database.Tests` and `FullyQualifiedName~ACE.Server.Tests.StartupTests`. It prints one line per trx result: `PASS`, `FAIL`, or `BLOCKED (known)` plus the raw message. `BLOCKED (known)` is only the Linux backslash copy of `ACE.Server\Config.js` (`Could not find a part of the path` or `Could not find file`, with `Config.js`, `ACE.Server`, and a backslash in the path). The db step exits non-zero when any test fails, is blocked, or is not discovered. CI marks that job `continue-on-error: true`. It is not a required check.

The one-time `Source/test.runsettings` proof, not the CI unit command, is the unit filter plus `--settings Source/test.runsettings`, once before the `net10.0` edit and once after. Quote both outputs.

Each GitHub Actions job has its own disk. The `unit` and `db` jobs call `verify.sh build` on that runner before `verify.sh unit` or `verify.sh db`, because those modes pass `--no-build`.

`scripts/guard.sh` is the protected-path check. It is not a `verify.sh` mode. It runs `git diff --name-only origin/master...HEAD` after `git fetch origin master`. On a pull request the workflow sets `GUARD_HEAD_BRANCH` from `github.head_ref`. When that branch is exactly `ace/sync-upstream`, the script prints each protected path as `NOTICE` and does not fail for those paths. Any other branch exits non-zero if the diff touches:

- `Source/ACE.Server/ServerBuildInfo_Dynamic.cs`
- `AppVeyor/dbversion.txt`
- `Source/ACE.Server/Network/**`
- `Source/Settings.StyleCop` or `.editorconfig`
- `docker.env`
- a `*.dat` file, or anything under `Dats/`, `db-data/`, `Logs/`, or `Config/`
- `Source/ACE.Server/Config.js` (a name ending in `.example` or `.docker` is not this file)
- an added or removed line in a `*.csproj` diff that contains `<Nullable>`, `<ImplicitUsings>`, or `StyleCop`
- a new `Directory.Build.props` or `stylecop.json`

On every branch, including `ace/sync-upstream`, the guard also reads `.github/workflows/` at `HEAD`:

- It fails if any workflow file other than `.github/workflows/dat-tests.yml` contains `self-hosted` or `ace-dats`.
- If `.github/workflows/dat-tests.yml` exists, it fails unless the only trigger is `workflow_dispatch`.

Do not add `dat-tests.yml` in this PR. Do not put `self-hosted` or `ace-dats` in `.github/workflows/build-test.yml`. Charles's Windows laptop is the runner those rules protect.

## Evidence

Proof lives in `${XDG_CACHE_HOME:-$HOME/.cache}/verify-ace/evidence/` (boot logs, mysql import logs, unit text, trx copies via the test logger under `TestResults/`, which git already ignores). Quote stdout from the script. A green `dotnet` exit code is not proof if the summary is missing. For boot, quote `BOOT status` and the log line that justified it.

## Cleanup

Stop only the process the script recorded:

```bash
# boot writes this pid and kills it before returning
cat "${XDG_CACHE_HOME:-$HOME/.cache}/verify-ace/boot.pid"
```

If this run started the container, remove that container and nothing else:

```bash
docker rm -f ace-verify-mysql
```

Do not delete the evidence directory. Do not `git add` `Source/ACE.Server/Config.js`, `db-data/`, `Logs/`, `*.dat`, or `AppVeyor/dbversion.txt`. `git clean` is not cleanup.

## Helpers

Both scripts are executable.

- `.cursor/skills/verify-ace/scripts/verify.sh [build|unit|db|boot|all]`
- `.cursor/skills/verify-ace/scripts/guard.sh`

`/maintain-verification-skill` is the upkeep loop when these commands or the test split change.

## Charles-only

Client DAT files (`client_cell_1.dat`, `client_portal.dat`, `client_highres.dat`, `client_local_English.dat`), `ACE.DatLoader.Tests` (the path is hard-coded to `C:\Turbine\Asheron's Call\`), and a client login smoke (official client to `127.0.0.1:9000`, an account, a character, one admin command). Agents never fetch, attach, or commit DATs. `boot` does not download them. If the log says they are required, the status stays `SKIPPED-NEEDS-DATS`.
