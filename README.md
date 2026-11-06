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
| `sql/source/` | Component SQL used to build the three bundles (listed below). The builder assembles the phase bundles |
| `sql/LFL_Method_Description.md` | Method description. The runner and the bundle build ignore it |
| `tools/run_dremio.py` | Sequential Dremio runner |
| `tools/build_phases.py` | Rebuilds the three bundles from `sql/source/` |
| `tools/Runner_Steps.md` | Run instructions |
| `.gitignore`, `.gitattributes` | Keep the lock file, logs and Python cache out of git, and keep line endings consistent |

Component files in `sql/source/`:

| Component | Goes into bundle | Objects |
|---|---|---|
| `01_setup.sql` | `01_data_prep.sql` | 01 `01_rate_change_params` (table) |
| `02_positions.sql` | `01_data_prep.sql` | 02 `02_lfl_row_geo`, 03 `03_lfl_row_cluster`, 04 `04_lfl_position` |
| `03_renewals.sql` | `01_data_prep.sql` | 05 `05_lfl_candidate`, 06 `06_lfl_renewal` |
| `04_layers.sql` | `02_layer_assignment.sql` | 07 `07_lfl_layer_position` |
| `05_outputs.sql` | `03_policy_output.sql` | 08 `08_lfl_policy_out` |
| `06_reporting.sql` | none | Optional tables 12 to 14 in `Sandbox_lake`: summary, funnel, QA checks. The runner does not run them |

## Requirements

- Python 3.10 or later. The scripts use only the standard library, so there is nothing to install.
- Network or VPN access to Dremio.
- Your own personal Dremio token. The runner asks for it when it starts, with the input hidden. It is never stored or written to the log.
- Write access to the Dremio locations below.

## Dremio storage locations

- The parameter table `01_rate_change_params`, stored tables `02_lfl_row_geo` to `08_lfl_policy_out`, and optional tables `12_rate_change_summary` to `14_rate_change_qa_checks` are in `"Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"`.
- The source data is read from `MarketDataStore.Business.Lumen."RateChange_Calcs"."RateChange_Base_Data"` and is never modified.
- Deploy the generated bundles in `sql/`. The files in `sql/source/` are assembled by `build_phases.py` without changing their Dremio paths.

## How the run works

The pipeline has three phases:

1. **Data preparation** (`01_data_prep.sql`, objects 01 to 06). Creates the parameter table and rebuilds the stored tables 02 to 06.
2. **Layer assignment** (`02_layer_assignment.sql`, object 07). Recreates table 07 empty, then runs the INSERT once per policy year, earliest first, until no year remains.
3. **Policy output** (`03_policy_output.sql`, object 08). Builds the one-row-per-source-policy table.

The runner submits each marked statement as a separate Dremio job and waits for it to finish before the next one starts, so each stored table is a materialization boundary. Optional tables 12 to 14 are not run.

## Set up PowerShell

Clone the repository, open PowerShell, and move to the `core` folder of your clone. The scripts find their files relative to their own location, so the clone can be anywhere.

```powershell
cd <path to your clone>\core
$core = (Get-Location).Path
$python = 'python'          # or the full path to Python 3.10+ if python is not on your PATH
$runner = Join-Path $core 'tools\run_dremio.py'
$logs = Join-Path $core 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
```

Check the Python version with `& $python --version`.

The runner connects to `https://dremio.renre.com:9047`. To use a different address, set `$env:DREMIO_URL` before running.

When a real run starts, the runner prompts for your personal Dremio token. Paste it and press Enter. The input is hidden, and the token is held in memory for that run only. Never save the token in a project file. A dry run does not ask for a token. For an unattended run with no terminal, set `$env:DREMIO_TOKEN` in the session instead.

Logs go to `core\logs`, and the lock file goes to `core\.dremio-run.lock`. Both are ignored by git.

## Validate and run

Before a real run, check that:

- no pipeline job is active in Dremio Jobs;
- the source load is complete;
- you have your personal Dremio token ready to paste when prompted;
- network or VPN access is available;
- nobody else is running the pipeline (see "Shared use" below).

Dry run. Parses the three bundles and submits nothing:

```powershell
& $python $runner --mode full --dry-run
```

Full rebuild. Drops and rebuilds tables 02 to 08. Source data is not modified:

```powershell
& $python $runner --mode full --confirm-rebuild --log-file "$logs\full-refresh.log"
```

Layer-only resume. Needs current tables 02 to 06 and an existing table 07:

```powershell
& $python $runner --mode layers --log-file "$logs\layers.log"
```

Output-only rebuild. Needs current tables 02 to 07:

```powershell
& $python $runner --mode outputs --log-file "$logs\outputs.log"
```

Check the result with `$LASTEXITCODE` and the end of the log file. Exit code 0 means the requested jobs completed. It does not mean any QA check passed.

## Shared use

The pipeline rebuilds shared tables in Dremio, so only one run should be active at a time across the whole team.

- The lock file protects only one clone of the repository. Two people running from separate clones are not blocked by each other's lock.
- Before a run, check Dremio Jobs for active pipeline jobs, and tell the team that you are running.
- Each person uses their own Dremio token, entered at the prompt. Tokens are never stored in the repository.

## Regenerate the bundles

After editing a component in `sql/source/`, rebuild the three bundles:

```powershell
& $python "$core\tools\build_phases.py"
```

The build joins the components listed above into the three bundle files. All pipeline and optional reporting objects use the `Sandbox_lake` path. Edit the components in `sql/source/`, not the bundles, so the next build does not overwrite the change. Commit the source change and the rebuilt bundles together.

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
