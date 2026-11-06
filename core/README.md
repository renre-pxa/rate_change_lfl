# LFL Core Pipeline

This folder holds the like-for-like (LFL) logic, the runner that deploys it to Dremio, and the instructions for running it.

- For how the logic works, read [`sql/LFL_Method_Description.md`](sql/LFL_Method_Description.md).
- For step-by-step run commands, see [`tools/Runner_Steps.md`](tools/Runner_Steps.md).

## What is in the folder

| Path | Purpose |
|---|---|
| `sql/01_data_prep.sql` | Deployment bundle for objects 01 to 06: parameters, positions, duplicate clean-up, effective positions, renewal candidates, renewal matching |
| `sql/02_layer_assignment.sql` | Deployment bundle for object 07: layer ids, filled one policy year at a time |
| `sql/03_policy_output.sql` | Deployment bundle for object 08: one row per source policy |
| `sql/source/` | Component SQL used to build the three bundles (listed below). Not deployable directly: table paths are mapped when the bundles are built |
| `tools/run_dremio.py` | Sequential Dremio runner |
| `tools/build_phases.py` | Rebuilds the three bundles from `sql/source/` |
| `tools/Runner_Steps.md` | Run instructions |
| `sql/LFL_Method_Description.md` | Method description. The runner and the bundle build ignore it |

Component files in `sql/source/`:

| Component | Goes into bundle | Objects |
|---|---|---|
| `01_setup.sql` | `01_data_prep.sql` | 01 `01_rate_change_params` (view) |
| `02_positions.sql` | `01_data_prep.sql` | 02 `02_lfl_row_geo`, 03 `03_lfl_row_cluster`, 04 `04_lfl_position` |
| `03_renewals.sql` | `01_data_prep.sql` | 05 `05_lfl_candidate`, 06 `06_lfl_renewal` |
| `04_layers.sql` | `02_layer_assignment.sql` | 07 `07_lfl_layer_position` |
| `05_outputs.sql` | `03_policy_output.sql` | 08 `08_lfl_policy_out` |
| `06_reporting.sql` | none | Optional views 12 to 14: summary, funnel, QA checks. The runner does not run them |

## Dremio storage locations

- The parameter view `01_rate_change_params` is in `Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"`.
- The stored tables `02_lfl_row_geo` to `08_lfl_policy_out` are in `"Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"`.
- The source data is read from `MarketDataStore.Business.Lumen."RateChange_Calcs"."RateChange_Base_Data"` and is never modified.
- Deploy the generated bundles in `sql/`. The files in `sql/source/` need their path mapping applied first, which `build_phases.py` does.

## How the run works

The pipeline has three phases:

1. **Data preparation** (`01_data_prep.sql`, objects 01 to 06). Creates the parameter view and rebuilds the stored tables 02 to 06.
2. **Layer assignment** (`02_layer_assignment.sql`, object 07). Recreates table 07 empty, then runs the INSERT once per policy year, earliest first, until no year remains.
3. **Policy output** (`03_policy_output.sql`, object 08). Builds the one-row-per-source-policy table.

The runner submits each marked statement as a separate Dremio job and waits for it to finish before the next one starts, so each stored table is a materialization boundary. Views 12 to 14 are not run.

## Set up PowerShell

Run from the project root and set:

```powershell
$python = 'C:\Users\pxa\AppData\Local\Programs\Python\Python312\python.exe'
$project = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'lfl_layer_tracking'
$core = Join-Path $project 'core'
$runner = Join-Path $core 'tools\run_dremio.py'
$env:DREMIO_URL = 'https://dremio.renre.com:9047'
```

The runner needs `DREMIO_URL` and `DREMIO_TOKEN` in its environment. [`tools/Runner_Steps.md`](tools/Runner_Steps.md) shows how to set the token without displaying or storing it. Never save the token in a project file.

The runner reads the bundles from `$core\sql` by default. Keep logs and other run files at the project root, outside `core/`.

## Validate and run

Before a real run, check that:

- no pipeline job is active in Dremio Jobs;
- the source load is complete;
- the Dremio token is set in the PowerShell session;
- network or VPN access is available;
- no other copy of the runner is running.

Dry run. Parses the three bundles and submits nothing:

```powershell
& $python $runner --mode full --dry-run
```

Full rebuild. Drops and rebuilds tables 02 to 08. Source data is not modified:

```powershell
& $python $runner --mode full --confirm-rebuild --log-file "$project\full-refresh.log"
```

Layer-only resume. Needs current tables 02 to 06 and an existing table 07:

```powershell
& $python $runner --mode layers --log-file "$project\layers.log"
```

Output-only rebuild. Needs current tables 02 to 07:

```powershell
& $python $runner --mode outputs --log-file "$project\outputs.log"
```

Check the result with `$LASTEXITCODE` and the end of the log file. Exit code 0 means the requested jobs completed. It does not mean any QA check passed.

## Regenerate the bundles

After editing a component in `sql/source/`, rebuild the three bundles:

```powershell
& $python "$core\tools\build_phases.py"
```

The build joins the components listed above into the three bundle files and maps tables 02 to 06 to the `Sandbox_lake` path. Parameter view 01 stays in `Sandbox`. Edit the components in `sql/source/`, not the bundles, so the next build does not overwrite the change.

## Reading the output

`08_lfl_policy_out` has one row per source `policy_id`.

- `premium_counted` and `limit_counted` add across source rows.
- Position-level and next-position measures repeat on every source row of the position. Select `policy_id = position_id` on the complete output before aggregating them.
- Do not use `SUM(DISTINCT amount)` to remove repeats.
- `status_next` gives the reason a position has no next-year renewal. The method description lists each value.

## If a run fails or is interrupted

1. Check Dremio Jobs before retrying. A job may still be running.
2. The file `.dremio-run.lock` stays in place after a failure. Remove it only after you have confirmed that no job is running and you have looked at any partial results.
3. Do not run multiple copies of the runner at the same time.
