# Run the LFL Core Pipeline

Open PowerShell at the project root and set the paths:

```powershell
$python = 'C:\Users\pxa\AppData\Local\Programs\Python\Python312\python.exe'
$project = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'lfl_layer_tracking'
$core = Join-Path $project 'core'
$runner = Join-Path $core 'tools\run_dremio.py'
$env:DREMIO_URL = 'https://dremio.renre.com:9047'
```

If needed, copy the Dremio token, then type this command manually so the command does not overwrite the clipboard:

```powershell
$env:DREMIO_TOKEN = (Get-Clipboard -Raw).Trim()
```

Check it without displaying the token:

```powershell
(-not [string]::IsNullOrWhiteSpace($env:DREMIO_TOKEN)) -and ($env:DREMIO_TOKEN -notmatch '\s|\p{Cc}|\p{Cf}')
```

Run only if that check returns `True`. Never share or store the token in project files.

## 1. Dry run

```powershell
& $python $runner --mode full --dry-run
```

This parses the three core SQL bundles and submits no jobs.

## 2. Check prerequisites

In Dremio Jobs, verify that no pipeline job is running. Confirm the source load is complete and there is no other runner active.

## 3. Run a full rebuild

```powershell
& $python $runner --mode full --confirm-rebuild --log-file "$project\full-refresh.log"
```

The runner executes these phases in order:

1. `core/sql/01_data_prep.sql`: creates parameter view 01 and rebuilds stored tables 02-06.
2. `core/sql/02_layer_assignment.sql`: recreates table 07 and inserts one policy year per iteration until none remain.
3. `core/sql/03_policy_output.sql`: builds the one-row-per-source-policy output table 08.

Each marked SQL statement is submitted as a separate Dremio job and awaited before the next statement. Tables 02-08 are stored in `Sandbox_lake`; parameter view 01 remains in `Sandbox`. A full rebuild replaces calculated tables but does not modify the source base data. Reporting and QA steps 12-14 are not run.

## 4. Check completion

```powershell
$LASTEXITCODE
Get-Content "$project\full-refresh.log" -Tail 30
```

Exit code 0 means the requested jobs completed, not that reporting or QA checks passed. On failure, check Dremio Jobs before retrying. The lock file is retained on failure; remove it only after confirming no job is still running and investigating partial results.

## Other run modes

Resume only layer assignment when data-prep tables are current and table 07 exists:

```powershell
& $python $runner --mode layers --log-file "$project\layers.log"
```

Rebuild only table 08 when data-prep tables and table 07 are current:

```powershell
& $python $runner --mode outputs --log-file "$project\outputs.log"
```

To regenerate deployment bundles after editing a source component under `core/sql/source/`:

```powershell
& $python "$core\tools\build_phases.py"
```