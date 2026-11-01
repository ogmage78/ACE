# Agents working on ogmage78/ACE

Scope is this fork only. The project is educational and non-commercial, official client only, AGPL-3.0.

## Branches

Use `ace/<slug>` off `master`. One writer per PR. Never commit to `master` or `old`. No force-push. No master reset. Only Charles merges.

## Merge packet

Before any merge request, run pstack interrogate and send only findings a run proved.
ACE Lead prepares a merge packet for Charles before every merge.

## Do not commit or edit

Never commit client DATs, `db-data/`, `Logs/`, live `Source/ACE.Server/Config.js`, or `docker.env` secrets. Never edit `Source/ACE.Server/ServerBuildInfo_Dynamic.cs` or `AppVeyor/dbversion.txt`. Do not modernize Nullable, ImplicitUsings, StyleCop, or `Source/ACE.Server/Network/` serialization.

Do not add a workflow that contains `self-hosted` or `ace-dats` except `.github/workflows/dat-tests.yml`. If that file exists, its only trigger is `workflow_dispatch`. This PR does not add it.

## Verify

Run `.cursor/skills/verify-ace/scripts/verify.sh` with `build`, `unit`, `db`, `boot`, or `all` before opening or updating a PR, and quote its output. DAT files, DatLoader tests, and client login smoke are Charles-only. Agents never fetch, attach, or commit DATs.

The `db` job in `.github/workflows/build-test.yml` is `continue-on-error: true` until the database tests run on Linux. It is not a required check. A `dotnet test` exit code of 0 with `No test is available` is not a pass.

## Usage soft cap

Before any cloud agent launch, check the ACE share (ACE Lead + ACE Engineer) of this week's Grok Bot usage. At 30% or more, launch nothing new and wait for Charles. A share under 30% does not mean the run is free. Cloud agent runs bill as Cursor usage, which that report does not show.
