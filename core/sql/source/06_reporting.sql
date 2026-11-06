-- ==============================================================================================================
-- 06_reporting.sql: rate change, data volume by step, checks (views, nothing is computed)
-- Objects (views): 12_rate_change_summary, 13_rate_change_funnel, 14_rate_change_qa_checks. They always show the latest stored tables.
-- ==============================================================================================================

-- @object 12_rate_change_summary
-- View 12_rate_change_summary: rate on line change of like-for-like renewals by year pair, plus the total.
-- rate on line = premium / client limit. change_in_rol = (total premium t+1 / total limit t+1) / (total premium t / total limit t) - 1.
-- Raw: not adjusted for exposure or layer height, and mixes primary and excess. Select one representative per position before slicing pairs.
CREATE OR REPLACE VIEW Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."12_rate_change_summary" AS
WITH pairs AS (
    SELECT CONCAT(CAST(policy_year AS VARCHAR), '-', CAST(next_policy_year AS VARCHAR)) AS year_pair,
           position_premium AS premium_t, next_position_premium AS premium_t1,
           position_client_limit AS client_limit_t, next_position_client_limit AS client_limit_t1,
           rol_change_pct,
           CASE WHEN position_client_limit / NULLIF(position_full_limit, 0) > 1.0001
                  OR next_position_client_limit / NULLIF(next_position_full_limit, 0) > 1.0001
                THEN 1 ELSE 0 END AS either_share_over_100
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out"
    WHERE policy_id = position_id AND next_position_id IS NOT NULL
)
SELECT
    year_pair,
    COUNT(*) AS renewal_pairs,
    SUM(premium_t) AS premium_t,
    SUM(premium_t1) AS premium_t1,
    SUM(client_limit_t) AS client_limit_t,
    SUM(client_limit_t1) AS client_limit_t1,
    SUM(premium_t) / SUM(client_limit_t) AS rol_t,
    SUM(premium_t1) / SUM(client_limit_t1) AS rol_t1,
    (SUM(premium_t1) / SUM(client_limit_t1)) / (SUM(premium_t) / SUM(client_limit_t)) - 1 AS change_in_rol,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rol_change_pct) AS median_pair_change,
    SUM(either_share_over_100) AS pairs_share_over_100
FROM pairs
GROUP BY year_pair
UNION ALL
SELECT
    'All' AS year_pair,
    COUNT(*),
    SUM(premium_t),
    SUM(premium_t1),
    SUM(client_limit_t),
    SUM(client_limit_t1),
    SUM(premium_t) / SUM(client_limit_t),
    SUM(premium_t1) / SUM(client_limit_t1),
    (SUM(premium_t1) / SUM(client_limit_t1)) / (SUM(premium_t) / SUM(client_limit_t)) - 1,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rol_change_pct),
    SUM(either_share_over_100)
FROM pairs;

-- @object 13_rate_change_funnel
-- View 13_rate_change_funnel: data volume by high-level step (rows, positions, candidates, renewals, layers) with premium and client limit.
CREATE OR REPLACE VIEW Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."13_rate_change_funnel" AS
SELECT 1 AS step_no, 'Source rows (policy_id)' AS what, COUNT(*) AS n_out,
       SUM(client_premium) AS premium, SUM(client_limit) AS client_limit
FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo"
UNION ALL
SELECT 2, 'After removing duplicate copies (same share, same premium)',
       (SELECT COUNT(*) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo")
         - (SELECT COALESCE(SUM(is_dup_copy), 0) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."03_lfl_row_cluster"),
       (SELECT SUM(eff_premium) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"),
       (SELECT SUM(client_limit) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo" WHERE position_rows = 1)
         + (SELECT COALESCE(SUM(cluster_limit), 0) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."03_lfl_row_cluster" WHERE is_dup_copy = 0)
UNION ALL
SELECT 3, 'Cedant positions (rows consolidated, largest limit where added shares exceed 100%)', COUNT(*),
       SUM(eff_premium), SUM(eff_client_limit)
FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"
UNION ALL
SELECT 4, 'Renewal candidates within tolerance (same stack and cedant, t to t+1)', COUNT(*), NULL, NULL
FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."05_lfl_candidate"
UNION ALL
SELECT 5, 'Candidates after the rate-on-line gate', COUNT(*), NULL, NULL
FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."05_lfl_candidate" WHERE gate_ok = 1
UNION ALL
SELECT 6, 'Like-for-like renewals (1:1), premium and limit are the year t side', COUNT(*), SUM(position_premium), SUM(position_client_limit)
FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out"
WHERE policy_id = position_id AND next_position_id IS NOT NULL
UNION ALL
SELECT 7, 'Layers across cedants (distinct layer_id)', COUNT(DISTINCT layer_id), NULL, NULL
FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."07_lfl_layer_position";

-- @object 14_rate_change_qa_checks
-- View 14_rate_change_qa_checks: one row per check, check_value should equal expected (docs/03_TECHNICAL_REFERENCE.md section 9).
CREATE OR REPLACE VIEW Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."14_rate_change_qa_checks" AS
SELECT 'position_id unique' AS check_name,
       (SELECT COUNT(*) - COUNT(DISTINCT position_id) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position") AS check_value, 0 AS expected
UNION ALL
SELECT 'every row traced to a position (rows - sum of position_rows)',
       (SELECT COUNT(*) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo") - (SELECT SUM(position_rows) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"), 0
UNION ALL
SELECT 'premium tie-out (premium_counted - eff_premium, rounded)',
      ROUND((SELECT SUM(premium_counted) FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out") - (SELECT SUM(eff_premium) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"), 2), 0
UNION ALL
SELECT 'client limit tie-out (limit_counted - eff_client_limit, rounded)',
      ROUND((SELECT SUM(limit_counted) FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out") - (SELECT SUM(eff_client_limit) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"), 2), 0
UNION ALL
SELECT 'every position has one layer',
       (SELECT COUNT(*) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position") - (SELECT COUNT(*) FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."07_lfl_layer_position"), 0
UNION ALL
SELECT 'renewal is 1:1 (prior positions used more than once)',
       (SELECT COUNT(*) FROM (SELECT prior_id FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal" GROUP BY prior_id HAVING COUNT(*) > 1) x), 0
UNION ALL
SELECT 'renewal is 1:1 (next positions used more than once)',
       (SELECT COUNT(*) FROM (SELECT next_id FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal" GROUP BY next_id HAVING COUNT(*) > 1) x), 0
UNION ALL
SELECT 'candidates still open after the last matching round (raise --rounds if > 0)',
       (SELECT COUNT(*) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."05_lfl_candidate" c
        LEFT JOIN Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal" r1 ON r1.prior_id = c.prior_id
        LEFT JOIN Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal" r2 ON r2.next_id = c.next_id
        WHERE c.gate_ok = 1 AND r1.prior_id IS NULL AND r2.next_id IS NULL), 0
UNION ALL
SELECT 'renewal pairs equal distinct renewed positions in policy output',
       (SELECT COUNT(*) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal") - (SELECT COUNT(DISTINCT position_id) FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out" WHERE next_position_id IS NOT NULL), 0
UNION ALL
SELECT 'published policy_id unique',
       (SELECT COUNT(*) - COUNT(DISTINCT policy_id) FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out"), 0
UNION ALL
SELECT 'source policies missing from output',
       (SELECT COUNT(*) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo" source_rows
  LEFT JOIN "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out" published ON published.policy_id = source_rows.policy_id
  WHERE published.policy_id IS NULL), 0
UNION ALL
SELECT 'unexpected policies in output',
       (SELECT COUNT(*) FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out" published
  LEFT JOIN Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo" source_rows ON source_rows.policy_id = published.policy_id
  WHERE source_rows.policy_id IS NULL), 0
UNION ALL
SELECT 'published counted amounts non-null',
       (SELECT COUNT(*) FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."08_lfl_policy_out"
  WHERE premium_counted IS NULL OR limit_counted IS NULL), 0
UNION ALL
SELECT 'DIAGNOSTIC multi-row positions spanning more than 1% on attachment or height (chain drift - review if large)',
       (SELECT COUNT(*) FROM (SELECT position_id FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo"
                              WHERE position_rows > 1
                              GROUP BY position_id
                              HAVING MAX(attachment) > MIN(attachment) * 1.01 OR MAX(height) > MIN(height) * 1.01) x), NULL
UNION ALL
SELECT 'DIAGNOSTIC positions with effective client share above 100%',
       (SELECT COUNT(*) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position" WHERE share_over_100 = 1), NULL
UNION ALL
SELECT 'DIAGNOSTIC positions in oversized scopes (not matched, see max_scope_positions)',
       (SELECT COUNT(*) FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position" pos CROSS JOIN Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params" p WHERE pos.scope_positions > p.max_scope_positions), NULL;
