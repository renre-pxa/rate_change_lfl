# Run the LFL Core Pipeline

Open PowerShell, move to the `core` folder of your clone of the repository, and set the paths. The clone can be anywhere, because the scripts find their files relative to their own location.

```powershell
cd <path to your clone>\core
$core = (Get-Location).Path
$python = 'python'          # or the full path to Python 3.10+ if python is not on your PATH
$runner = Join-Path $core 'tools\run_dremio.py'
$logs = Join-Path $core 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
```

The runner connects to `https://dremio.renre.com:9047`. To use a different address, set `$env:DREMIO_URL` before running.

## Your Dremio token

When a real run starts, the runner asks for your personal Dremio token. Paste it and press Enter. The input is hidden, the token is held in memory for that run only, and it is never written to the log. Never share the token or save it in project files.

A dry run does not ask for a token. For an unattended run with no terminal, set `$env:DREMIO_TOKEN` in the session instead.

## 1. Dry run

```powershell
& $python $runner --mode full --dry-run
```

This parses the three core SQL bundles and submits no jobs.

## 2. Check prerequisites

In Dremio Jobs, verify that no pipeline job is running. Confirm the source load is complete. The lock file only protects your own clone, so make sure nobody else on the team is running the pipeline.

## 3. Run a full rebuild

```powershell
& $python $runner --mode full --confirm-rebuild --log-file "$logs\full-refresh.log"
```

Paste your token when prompted.

The runner executes these phases in order:

1. `sql/01_data_prep.sql`: creates parameter view 01 and rebuilds stored tables 02-06.
2. `sql/02_layer_assignment.sql`: recreates table 07 and inserts one policy year per iteration until none remain.
3. `sql/03_policy_output.sql`: builds the one-row-per-source-policy output table 08.

Each marked SQL statement is submitted as a separate Dremio job and awaited before the next statement. The parameter view 01 and tables 02-08 are stored in `Sandbox_lake`. A full rebuild replaces calculated tables but does not modify the source base data. Optional reporting and QA views 12-14 also target `Sandbox_lake`, but are not run by the runner.

## 4. Check completion

```powershell
$LASTEXITCODE
Get-Content "$logs\full-refresh.log" -Tail 30
```

Exit code 0 means the requested jobs completed, not that reporting or QA checks passed. On failure, check Dremio Jobs before retrying. The lock file (`core\.dremio-run.lock`) is retained on failure; remove it only after confirming no job is still running and investigating partial results.

## Other run modes

Resume only layer assignment when data-prep tables are current and table 07 exists:

```powershell
& $python $runner --mode layers --log-file "$logs\layers.log"
```

Rebuild only table 08 when data-prep tables and table 07 are current:

```powershell
& $python $runner --mode outputs --log-file "$logs\outputs.log"
```

To regenerate deployment bundles after editing a source component under `sql/source/`:

```powershell
& $python "$core\tools\build_phases.py"
```

Commit the source change and the rebuilt bundles together.
