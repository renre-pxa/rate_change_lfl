# LFL core pipeline: how the method works

This document explains what the code does, step by step, so that someone new can read the SQL and understand the process. It covers how source rows become positions, how positions are matched as renewals from one year to the next, how layer ids are assigned, and what the published output contains.

---

## 1. What the pipeline produces

The input is one row per cedant participation in a policy. The pipeline answers three questions:

1. Which source rows belong together as one cedant position in one year?
2. Which position in year t+1 is the renewal of a position in year t?
3. Which positions, across cedants and years, sit on the same layer?

The result is a table with one row per source `policy_id`. Each row shows the position it belongs to, the layer id of that position, the renewal link to the prior and next year (if any), and, where there is no next-year link, a reason code.

## 2. Vocabulary

| Term | Meaning |
|---|---|
| Source row | One row of the base data. Identified by `policy_id` |
| Stack (`stack_hash`) | A grouping key supplied in the base data. Every comparison in this pipeline stays inside one stack |
| Cedant (`root_basic_id`) | The cedant key supplied in the base data |
| Scope | One stack, one cedant, one policy year |
| Attachment | `attachment_deductible_usd_amt` in the base data |
| Height | Attachment plus full limit: the top of the layer |
| Position | One cedant's source rows, in one scope, that have the same layer shape. Its `position_id` is the lowest `policy_id` among its rows |
| Cluster | Source rows inside a position that are duplicates of each other |
| Renewal | A 1:1 link from a position in year t to a position in year t+1, in the same stack and cedant |
| Layer | A group of positions, across cedants and years, in one stack. Its `layer_id` is the `position_id` of the position that created it |
| Rate on line (ROL) | Effective premium divided by effective client limit |

"Within x%" tests compare a gap to a percentage of a reference value. The reference is stated in each step.

## 3. Input columns used

`policy_id`, `root_basic_id`, `root_account_name`, `stack_hash`, `insured_name`, `policy_incept_year`, `attachment_deductible_usd_amt`, `full_limit_usd_amt`, `client_limit_usd_amt`, `client_premium_gross_usd_amt`. The base data is read as given.

## 4. Objects and order

| # | Object | One row per | Built from |
|---|---|---|---|
| 01 | `01_rate_change_params` (table) | the whole run | constants |
| 02 | `02_lfl_row_geo` | source row | base data |
| 03 | `03_lfl_row_cluster` | source row of a multi-row position | 02 |
| 04 | `04_lfl_position` | position | 02, 03 |
| 05 | `05_lfl_candidate` | prior/next candidate pair | 04 |
| 06 | `06_lfl_renewal` | accepted renewal | 05 |
| 07 | `07_lfl_layer_position` | position | 04, 06 |
| 08 | `08_lfl_policy_out` | source row | 02, 03, 04, 05, 06, 07 |

The three deployment files group these into phases: data preparation (01 to 06), layer assignment (07) and policy output (08). Objects 01 to 08 are tables in `Sandbox_lake`; optional reporting/QA tables 12 to 14 also target that location.

The runner submits each statement as a separate Dremio job and waits for it, so each stored table is a materialization boundary. For layer assignment it first creates table 07 empty, then repeats the INSERT once per policy year (section 11).

## 5. Parameters

All tolerances sit in one row in the `01_rate_change_params` table.

| Parameter | Value | Where it is used |
|---|---|---|
| `geo_tol` | 0.5% | Grouping source rows into positions (step 6); grouping new layers (step 11) |
| `premium_tol` | 0.5% | Finding duplicate premiums inside a position (step 7) |
| `share_tol` | 0.01% | Deciding whether added client limits exceed the full limit (steps 7, 8) |
| `renewal_tol` | 5% | Renewal candidate test and score (step 9) |
| `rol_gate` | 1.9 | Price gate on a candidate pair (step 9) |
| `scan_tol` | 5% | Layer scan against prior-year layers (step 11) |
| `max_scope_positions` | 1,000 | Size guard (steps 9, 11, 12) |
| `limit_tol` | 0.5% | Declared in the view; no step references it |

---

## 6. Step 1: positions (`02_lfl_row_geo`)

Goal: assign every source row to a position.

1. Count the rows in each scope (stack, cedant, year). Call it `scope_rows`.
2. A row alone in its scope is its own position: `position_id = policy_id`, `position_rows = 1`. These rows skip the sorting below.
3. In a scope with more than one row, rows are sorted by attachment (ties by `policy_id`). A new attachment group starts at the first row, and again whenever the attachment minus the previous row's attachment is more than `geo_tol` times the previous row's attachment.
4. Inside each attachment group, the same test runs on height, sorted by height. Each resulting group is a shape group.
5. Each shape group is a position. `position_id` is its lowest `policy_id`, and `position_rows` is the number of rows in it.

Each gap is measured against the previous row, not the first row of the group. This is called chaining. A group can therefore span more than 0.5% from end to end.

Example, attachments in one scope:

| Row | Attachment | Gap to previous | Result |
|---|---|---|---|
| 1 | 30.00M | none | starts group 1 |
| 2 | 30.10M | 0.33% | same group |
| 3 | 30.20M | 0.33% | same group |
| 4 | 35.00M | 15.9% | starts group 2 |

Rows 1 and 3 are 0.67% apart but are still in one group, because each step is within 0.5%.

Output columns: `policy_id`, `root_basic_id`, `root_account_name`, `stack_hash`, `insured_name`, `policy_year`, `next_year` (policy year plus 1), `attachment`, `full_limit`, `height`, `client_limit`, `client_premium`, `position_id`, `position_rows`.

## 7. Step 2: duplicates and shares (`03_lfl_row_cluster`)

Goal: for positions with more than one row, decide what each row contributes to the position's premium and limit. Single-row positions skip this step.

Every source row stays in the table. Rows are not deleted. Duplicates are given a counted amount of 0.

### 7.1 Clusters of duplicates

Inside a position, rows with identical attachment, full limit and client limit (the same client share) are compared on premium. They are sorted by premium. A new cluster starts at the first row, and whenever the premium minus the previous row's premium, divided by this row's premium, is more than `premium_tol`.

For each cluster:

- `cluster_rep` is the lowest `policy_id` in it.
- `cluster_premium` is the median premium of the cluster (the middle value, or the average of the two middle values).
- The representative row counts the cluster premium. The other rows count 0 and are marked `is_dup_copy = 1`.

A row with no duplicates is a cluster of one.

### 7.2 Adding clusters and testing the share

Within the position:

- `sum_limit` is the sum of the client limits of the clusters (one per cluster).
- `position_full_limit` is the median full limit across all rows of the position.
- If `sum_limit` is more than `position_full_limit` times (1 + `share_tol`), the added shares exceed 100%, and `limit_rule_max = 1`.

The counted limit of a row depends on that result:

- Not the representative of its cluster: 0.
- Added shares do not exceed 100%: the cluster's client limit.
- Added shares exceed 100%: the cluster's client limit for the largest cluster only (ties go to the lowest `cluster_rep`), and 0 for all other clusters.

The counted premium does not depend on this test. Every cluster's premium is counted either way.

### 7.3 Worked examples

Duplicates: one position, all rows with attachment 10M, full limit 5M, client limit 1M. Premiums sorted: 100,000, 100,300, 101,000.

- 100,300 is 0.30% above 100,000, so it joins the first cluster.
- 101,000 is 0.69% above 100,300, so it starts a second cluster.
- Cluster 1 has two rows, so its median is 100,150. Cluster 2 is 101,000.
- Premium counted: 100,150 on the lower row of cluster 1, 101,000 on its cluster's row, 0 on the other. Position premium is 201,150.
- Client limits are 1M per cluster, added to 2M. This is below the 5M full limit, so both clusters count their limit.

Shares above 100%: two clusters with client limits 3M and 4M, full limit 5M, premiums 150,000 and 190,000. The limits add to 7M, above 5M, so only the 4M cluster counts its limit. Both premiums count: position premium is 340,000, position client limit is 4M, ROL is 8.5%.

Output columns include `premium_cluster`, `cluster_rep`, `cluster_rows`, `n_clusters`, `is_dup_copy`, `cluster_premium`, `cluster_limit`, `sum_limit`, `position_full_limit`, `limit_rule_max`, `premium_counted`, `limit_counted`.

## 8. Step 3: effective positions (`04_lfl_position`)

Goal: one row per position with its effective geometry and amounts.

| Column | Single-row position | Multi-row position |
|---|---|---|
| `attachment`, `full_limit`, `height` | the row's values | median across all source rows of the position, including duplicate copies |
| `position_rows` | 1 | number of source rows |
| `n_clusters` | 1 | number of clusters |
| `eff_premium` | the row's premium | sum of `premium_counted` |
| `eff_client_limit` | the row's client limit | sum of `limit_counted` |

Then for every position:

- `eff_client_share` = `eff_client_limit` / `full_limit`.
- `share_over_100` = 1 when the share exceeds 1 + `share_tol`.
- `eff_rol` = `eff_premium` / `eff_client_limit`.
- `scope_positions` = the number of positions in the same stack, cedant and year. This feeds the size guard.

## 9. Step 4: renewal candidates (`05_lfl_candidate`)

Goal: list every pair (prior position in year t, next position in year t+1) that could be a renewal.

Both positions must sit in scopes of at most `max_scope_positions` (1,000). A pair is listed when:

- both positions have the same `stack_hash` and `root_basic_id`;
- the next position's policy year equals the prior position's `next_year`;
- the attachment gap is at most `renewal_tol` times the prior attachment;
- the height gap is at most `renewal_tol` times the prior height.

For each pair the table records:

- `score` = attachment gap divided by (`renewal_tol` × prior attachment), plus height gap divided by (`renewal_tol` × prior height). Each term is between 0 and 1 for a listed pair, so the score is between 0 and 2. Lower is better. Premium plays no part.
- `rol_ratio` = next `eff_rol` divided by prior `eff_rol`.
- `gate_ok` = 1 when `rol_ratio` is between 1/`rol_gate` and `rol_gate` (1/1.9 to 1.9), otherwise 0.

Pairs with `gate_ok = 0` stay in the table for audit. Only `gate_ok = 1` pairs go on to matching.

Example: prior position at attachment 10.0M, height 15.0M. A next position at attachment 10.3M, height 15.4M is listed (3% and 2.7% away). Its score is 0.3 / 0.5 + 0.4 / 0.75 = 0.60 + 0.53 = 1.13.

## 10. Step 5: one-to-one matching (`06_lfl_renewal`)

Goal: choose renewals so that each position is used at most once as a prior and at most once as a next.

The table is generated: four rounds of the same logic written out one after another. Matching starts from the `gate_ok = 1` candidates. Each round does the following:

1. Rank the open candidates of each prior position by (`score`, `prior_id`, `next_id`).
2. Rank the open candidates of each next position by the same order.
3. Accept every candidate ranked first on both sides.
4. Mark the accepted pair with the round number (1 to 4). Drop every other candidate that shares a prior or a next position with an accepted pair.
5. Carry the accepted pairs and the remaining open candidates into the next round.

After round 4, candidates that were never accepted are discarded and those positions are unmatched.

Example: two prior positions (P1, P2), two next positions (C1, C2), and each cell is a candidate pair showing its score:

| | Next C1 | Next C2 |
|---|---|---|
| Prior P1 | 0.10 | 0.20 |
| Prior P2 | 0.15 | 0.40 |

Round 1: P1–C1 is ranked first for both P1 and C1, so it is accepted. P1–C2 (shares P1) and P2–C1 (shares C1) are dropped. Round 2: P2–C2 is now the only candidate and is accepted.

Output columns: `prior_id`, `next_id`, `stack_hash`, `root_basic_id`, `prior_year`, `next_year`, `score`, `rol_ratio`, `match_round`.

## 11. Step 6: layer ids (`07_lfl_layer_position`)

Goal: give every position a `layer_id` so that positions on the same layer share it, across cedants and years.

### 11.1 How the table is filled

The table starts empty, with one row per position when full: `position_id`, `stack_hash`, `policy_year`, `attachment`, `height`, `layer_id`, `layer_assignment`. One INSERT then runs for each policy year, in order. Each INSERT works on the earliest year in `04_lfl_position` that is not yet in the table, and reads the previous year's layers from the table itself. The runner repeats the INSERT until no year remains.

### 11.2 The three routes

Every position of the year takes the first route that applies.

Route 1: renewal. If the position is the next side of an accepted renewal, and the prior position has a layer, the position takes the prior position's `layer_id`. `layer_assignment = 'renewal'`. There is no further geometric check beyond the renewal tolerance already applied in step 4.

Route 2: scan. If the position has no renewal link, it is compared with the prior year's layers in the same stack:

1. For each prior-year layer, take the median attachment and median height of the positions that sat on that layer last year.
2. A layer qualifies if the position's attachment is within `scan_tol` (5%) of the layer's median attachment, and its height is within `scan_tol` of the layer's median height. Both gaps are measured against the layer's median.
3. For each qualifying layer, score = attachment gap divided by (`scan_tol` × median attachment), plus height gap divided by (`scan_tol` × median height).
4. The position takes the qualifying layer with the lowest score (ties go to the lowest `layer_id`). `layer_assignment = 'scan'`.
5. Stacks with more than `max_scope_positions` prior-year layers are not scanned.

Route 3: new layer. The positions that got no layer from route 1 or 2 are leftovers. Leftovers are grouped with each other, within the stack and year, across all cedants:

1. Sort the stack's leftovers by attachment (ties by `position_id`). Start a new group at the first one, and whenever the attachment gap to the previous leftover is more than `geo_tol` (0.5%) of the previous attachment.
2. Within each attachment group, sort by height and split the same way.
3. Each final group is a new layer. Its `layer_id` is the lowest `position_id` in the group.
4. `layer_assignment` is `first_year` if the stack had no positions in the prior year (the first year of the data, a new stack, or a year after a gap). Otherwise it is `new`.

### 11.3 Things that follow from the design

- Leftovers are grouped only with other leftovers. They are not compared with positions that took a layer through route 1 or 2 in the same year. Example: layer 100 had median attachment 10.00M and height 20.00M last year. This year, position A renews and takes layer 100 at attachment 10.48M, height 20.96M. Position C has no renewal link and sits at 10.52M, 21.04M. C is 5.2% above the layer's median on both measures, so the scan rejects it. C becomes a leftover and gets its own new `layer_id`, even though A and C are 0.4% apart this year.
- In the first year of data there are no prior layers, so every position is a leftover and the whole year is grouped by route 3.
- The scan looks one year back only. A stack with no positions in the prior year starts again with `first_year`.
- A layer keeps its id as long as each year's positions arrive by route 1 or 2. Renewal links are limited to 5% per step, and nothing limits the drift summed over several years.
- A `layer_id` is always the `position_id` of the position that first created it.

## 12. Step 7: policy output (`08_lfl_policy_out`)

Goal: one row per source `policy_id` carrying everything above.

The table starts from `02_lfl_row_geo` and joins:

- `04_lfl_position` (position values) and `07_lfl_layer_position` (layer id and how it was assigned), on `position_id`;
- `03_lfl_row_cluster`, on `policy_id`, for the row-level counted amounts. Rows of single-row positions have no entry there;
- `06_lfl_renewal` twice: with the position as prior (the next-year link) and as next (the prior-year link);
- `04_lfl_position` again for the next position's values;
- a summary of `05_lfl_candidate` per prior position (number of candidates and number passing the gate);
- the closest gate-failed candidate per prior position, ranked by (`score`, `next_id`).

### 12.1 Row-level columns

- `row_role` describes how the row was treated:
  - `single`: the row is alone, or has no duplicates and one cluster.
  - `duplicate_copy`: a duplicate of another row's premium cluster. It counts 0.
  - `duplicate_kept`: the representative of a cluster with more than one row, in a position with one cluster.
  - `summed`: a position with several clusters, where this cluster has one row.
  - `duplicate_kept_and_summed`: a representative of a multi-row cluster in a position with several clusters.
- `premium_counted` and `limit_counted` are the row's contributions to its position. For rows with no entry in step 2, they equal the row's own premium and client limit. Summed across the position's rows, they equal `position_premium` and `position_client_limit`.

### 12.2 Position-level columns

The position's own attachment, full limit, height, row count, cluster count, premium, client limit and ROL appear on every source row of the position (`position_attachment`, `position_full_limit`, `position_height`, `position_rows`, `position_clusters`, `position_premium`, `position_client_limit`, `position_rol`). `layer_id` and `layer_assignment` come from step 6. To aggregate position-level values, keep one row per position with `policy_id = position_id`.

### 12.3 Renewal columns

- `prior_position_id`: the position it renewed from, if any.
- `next_position_id`, `next_policy_year`, and the next position's attachment, full limit, height, premium, client limit and ROL.
- `renewal_score`, `match_round`, and `rol_change_pct` (the ROL ratio minus 1).

### 12.4 `status_next`

For each position, the first condition that applies:

| Status | Condition |
|---|---|
| `renewed_same_cedant` | the position has an accepted renewal as prior |
| `last_year` | the position is in the latest policy year |
| `oversized_scope` | its scope has more than `max_scope_positions` positions |
| `no_candidate_within_tolerance` | it has no candidate in the candidate table |
| `removed_by_rol_gate` | it has candidates, and none passes the gate |
| `lost_to_better_pair` | it has candidates that pass the gate but none was accepted |

`lost_to_better_pair` covers every case where a gate-passing candidate exists but no renewal was accepted: another pair took the candidate in a matching round, or the candidate was still open after round 4.

For `removed_by_rol_gate` positions, `gate_failed_next_id` and `gate_rol_ratio` show the closest gate-failed candidate.

## 13. Tracing one policy through the pipeline

Take a source row and follow it:

1. Step 1 puts it into a position, with `position_id` the lowest `policy_id` of its shape group.
2. Step 2 sorts it into a premium cluster and decides whether its premium and limit are counted or set to 0.
3. Step 3 builds the position's effective premium, limit and ROL, with geometry medians across rows.
4. Step 4 pairs the position with next-year positions in the same stack and cedant within 5%, and applies the ROL gate.
5. Step 5 keeps at most one next position per prior position, in up to four rounds.
6. Step 6 gives the position a `layer_id`: copied from its prior-year renewal, found by the scan, or created new.
7. Step 7 writes one row for the source row with all of the above and a `status_next`.

## 14. Running and rebuilding

- `run_dremio.py --mode full` runs the three phases in order and rebuilds tables 02 to 08. It needs `--confirm-rebuild`.
- `--mode layers` re-runs only the layer INSERTs, using current tables 02 to 06 and an existing table 07.
- `--mode outputs` rebuilds only table 08, using current tables 02 to 07.
- `--dry-run` parses the SQL and submits nothing.
- A lock file prevents overlapping runs. It stays in place after a failure until it is removed by hand.
- `build_phases.py` assembles the three deployment files from the component SQL under `sql/source/`; the source SQL already names the `Sandbox_lake` paths.
- The reporting views 12 to 14 (summary, funnel, QA checks) are not run by the runner.
