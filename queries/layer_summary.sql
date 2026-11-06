-- Read-only replacement for former output 09. Not executed by the runner.
WITH positions AS (
    SELECT * FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out"
    WHERE policy_id = position_id
),
agg AS (
    SELECT layer_id, policy_year,
           MIN(stack_hash) AS stack_hash, MIN(insured_name) AS insured_name,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY position_attachment) AS layer_attachment_median,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY position_height) AS layer_height_median,
           COUNT(DISTINCT root_basic_id) AS n_cedants, COUNT(*) AS n_positions,
           SUM(position_rows) AS n_source_rows,
           SUM(position_premium) AS layer_premium, SUM(position_client_limit) AS layer_client_limit,
           COUNT(DISTINCT CASE WHEN next_position_id IS NOT NULL THEN root_basic_id END) AS n_cedants_renewed,
           SUM(CASE WHEN next_position_id IS NOT NULL THEN 1 ELSE 0 END) AS n_renewed_positions,
           SUM(CASE WHEN next_position_id IS NOT NULL THEN position_premium ELSE 0 END) AS lfl_premium_t,
           SUM(CASE WHEN next_position_id IS NOT NULL THEN next_position_premium ELSE 0 END) AS lfl_premium_t1,
           SUM(CASE WHEN next_position_id IS NOT NULL THEN position_client_limit ELSE 0 END) AS lfl_client_limit_t,
           SUM(CASE WHEN next_position_id IS NOT NULL THEN next_position_client_limit ELSE 0 END) AS lfl_client_limit_t1
    FROM positions GROUP BY layer_id, policy_year
),
cedants AS (SELECT DISTINCT layer_id, policy_year, root_basic_id FROM positions),
left_n AS (
    SELECT prior.layer_id, prior.policy_year,
           SUM(CASE WHEN following.root_basic_id IS NULL THEN 1 ELSE 0 END) AS n_cedants_left
    FROM cedants prior
    INNER JOIN agg later ON later.layer_id = prior.layer_id AND later.policy_year = prior.policy_year + 1
    LEFT JOIN cedants following ON following.layer_id = prior.layer_id AND following.policy_year = prior.policy_year + 1 AND following.root_basic_id = prior.root_basic_id
    GROUP BY prior.layer_id, prior.policy_year
),
joined_n AS (
    SELECT following.layer_id, following.policy_year - 1 AS policy_year,
           SUM(CASE WHEN prior.root_basic_id IS NULL THEN 1 ELSE 0 END) AS n_cedants_joined
    FROM cedants following
    INNER JOIN agg earlier ON earlier.layer_id = following.layer_id AND earlier.policy_year = following.policy_year - 1
    LEFT JOIN cedants prior ON prior.layer_id = following.layer_id AND prior.policy_year = following.policy_year - 1 AND prior.root_basic_id = following.root_basic_id
    GROUP BY following.layer_id, following.policy_year
)
SELECT
    current_layer.layer_id, current_layer.stack_hash, current_layer.insured_name, current_layer.policy_year,
    current_layer.layer_attachment_median,
    current_layer.layer_height_median - current_layer.layer_attachment_median AS layer_limit_median,
    current_layer.n_cedants, current_layer.n_positions, current_layer.n_source_rows,
    current_layer.layer_premium, current_layer.layer_client_limit,
    current_layer.layer_client_limit / NULLIF(current_layer.layer_height_median - current_layer.layer_attachment_median, 0) AS layer_total_share,
    CASE WHEN current_layer.layer_client_limit / NULLIF(current_layer.layer_height_median - current_layer.layer_attachment_median, 0) > 1.0001 THEN 1 ELSE 0 END AS share_over_100,
    current_layer.layer_premium / NULLIF(current_layer.layer_client_limit, 0) AS layer_rol,
    CASE WHEN next_layer.layer_id IS NULL THEN 0 ELSE 1 END AS layer_in_next_year,
    current_layer.n_cedants_renewed,
    COALESCE(left_n.n_cedants_left, 0) AS n_cedants_left,
    COALESCE(joined_n.n_cedants_joined, 0) AS n_cedants_joined,
    current_layer.n_renewed_positions,
    current_layer.lfl_premium_t, current_layer.lfl_premium_t1,
    current_layer.lfl_client_limit_t, current_layer.lfl_client_limit_t1,
    (current_layer.lfl_premium_t1 / NULLIF(current_layer.lfl_client_limit_t1, 0))
        / NULLIF(current_layer.lfl_premium_t / NULLIF(current_layer.lfl_client_limit_t, 0), 0) - 1 AS lfl_rol_change_pct,
    (next_layer.layer_premium / NULLIF(next_layer.layer_client_limit, 0))
        / NULLIF(current_layer.layer_premium / NULLIF(current_layer.layer_client_limit, 0), 0) - 1 AS all_cedants_rol_change_pct
FROM agg current_layer
LEFT JOIN agg next_layer ON next_layer.layer_id = current_layer.layer_id AND next_layer.policy_year = current_layer.policy_year + 1
LEFT JOIN left_n ON left_n.layer_id = current_layer.layer_id AND left_n.policy_year = current_layer.policy_year
LEFT JOIN joined_n ON joined_n.layer_id = current_layer.layer_id AND joined_n.policy_year = current_layer.policy_year;