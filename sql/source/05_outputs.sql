-- Published detail: one row per source policy_id. Objects 09-11 are no longer built.
-- Counted amounts are row-level. Position values repeat on source rows:
-- select one row per position_id before aggregating position or renewal values.
-- @object 08_lfl_policy_out
DROP TABLE IF EXISTS "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out";
CREATE TABLE "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out" AS
WITH p AS (
    SELECT * FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params"
),
maxy AS (
    SELECT MAX(policy_year) AS max_year
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"
),
cand AS (
    SELECT prior_id, COUNT(*) AS n_cand, SUM(gate_ok) AS n_ok
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."05_lfl_candidate"
    GROUP BY prior_id
),
bf0 AS (
    SELECT prior_id, next_id, rol_ratio,
           ROW_NUMBER() OVER (PARTITION BY prior_id ORDER BY score, next_id) AS candidate_rank
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."05_lfl_candidate"
    WHERE gate_ok = 0
)
SELECT
    g.policy_id,
    g.position_id,
    lp.layer_id,
    g.stack_hash,
    g.root_basic_id,
    g.root_account_name,
    g.insured_name,
    g.policy_year,
    g.attachment,
    g.full_limit,
    g.client_limit,
    g.client_premium,
    CASE WHEN c.policy_id IS NULL THEN 'single'
         WHEN c.is_dup_copy = 1 THEN 'duplicate_copy'
         WHEN c.cluster_rows > 1 AND c.n_clusters > 1 THEN 'duplicate_kept_and_summed'
         WHEN c.cluster_rows > 1 THEN 'duplicate_kept'
         WHEN c.n_clusters > 1 THEN 'summed'
         ELSE 'single' END AS row_role,
    CASE WHEN c.policy_id IS NULL THEN g.client_premium ELSE c.premium_counted END AS premium_counted,
    CASE WHEN c.policy_id IS NULL THEN g.client_limit ELSE c.limit_counted END AS limit_counted,
    pos.attachment AS position_attachment,
    pos.full_limit AS position_full_limit,
    pos.height AS position_height,
    pos.position_rows,
    pos.n_clusters AS position_clusters,
    pos.eff_premium AS position_premium,
    pos.eff_client_limit AS position_client_limit,
    pos.eff_rol AS position_rol,
    lp.layer_assignment,
    rp.prior_id AS prior_position_id,
    CASE WHEN rn.next_id IS NOT NULL THEN 'renewed_same_cedant'
         WHEN pos.policy_year = maxy.max_year THEN 'last_year'
         WHEN pos.scope_positions > p.max_scope_positions THEN 'oversized_scope'
         WHEN COALESCE(cand.n_cand, 0) = 0 THEN 'no_candidate_within_tolerance'
         WHEN cand.n_ok = 0 THEN 'removed_by_rol_gate'
         ELSE 'lost_to_better_pair' END AS status_next,
    rn.next_id AS next_position_id,
    nx.policy_year AS next_policy_year,
    nx.attachment AS next_position_attachment,
    nx.full_limit AS next_position_full_limit,
    nx.height AS next_position_height,
    nx.eff_premium AS next_position_premium,
    nx.eff_client_limit AS next_position_client_limit,
    nx.eff_rol AS next_position_rol,
    rn.score AS renewal_score,
    rn.match_round,
    rn.rol_ratio - 1 AS rol_change_pct,
    CASE WHEN cand.n_ok = 0 THEN bf.next_id END AS gate_failed_next_id,
    CASE WHEN cand.n_ok = 0 THEN bf.rol_ratio END AS gate_rol_ratio
FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo" g
INNER JOIN "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position" pos ON pos.position_id = g.position_id
INNER JOIN "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."07_lfl_layer_position" lp ON lp.position_id = g.position_id
LEFT JOIN "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."03_lfl_row_cluster" c ON c.policy_id = g.policy_id
LEFT JOIN "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal" rn ON rn.prior_id = g.position_id
LEFT JOIN "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal" rp ON rp.next_id = g.position_id
LEFT JOIN "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position" nx ON nx.position_id = rn.next_id
LEFT JOIN cand ON cand.prior_id = g.position_id
LEFT JOIN bf0 bf ON bf.prior_id = g.position_id AND bf.candidate_rank = 1
CROSS JOIN p
CROSS JOIN maxy;
