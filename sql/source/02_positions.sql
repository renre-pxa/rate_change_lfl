-- ==============================================================================================================
-- 02_positions.sql: geometry groups, clean-up of multi-row positions, effective positions
-- Objects (stored tables): 02_lfl_row_geo, 03_lfl_row_cluster, 04_lfl_position. Reads the base data and 01_rate_change_params.
-- Base data input contract (RateChange_Base_Data, one row per cedant participation): policy_id, root_basic_id, root_account_name, stack_hash,
-- insured_name, policy_incept_year, attachment_deductible_usd_amt, full_limit_usd_amt, client_limit_usd_amt, client_premium_gross_usd_amt.
-- 02_lfl_row_geo is the heaviest statement of the stack (it sorts only the rows of stack-year-cedant scopes with more than one row).
-- ==============================================================================================================

-- @object 02_lfl_row_geo
-- Table 02_lfl_row_geo: one row per base row, with its position and position size.
-- Position = one cedant's rows (root_basic_id) of one stack (stack_hash) and policy year that form one layer shape. Only a
-- stack-year-cedant scope with more than one row can hold a multi-row position, so only those rows go through the sorts
-- (scope_rows > 1): a row alone in its scope is its own position (position_id = policy_id, position_rows = 1) and skips every window pass.
-- Layer shape (geometry group), inside a scope: rows sorted by attachment, a new group starts when the gap to the previous row exceeds
-- geo_tol of that row (chained gaps, LAG + running SUM), then the same on height inside each attachment group.
-- position_id = lowest policy_id of the position (unique, the key of every later table).
DROP TABLE IF EXISTS "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo";
CREATE TABLE "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo" AS
WITH p AS (
    SELECT * FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params"
),
b AS (
    SELECT
        policy_id,
        root_basic_id,
        root_account_name,
        stack_hash,
        insured_name,
        policy_incept_year AS policy_year,
        policy_incept_year + 1 AS next_year,
        attachment_deductible_usd_amt AS attachment,
        full_limit_usd_amt AS full_limit,
        attachment_deductible_usd_amt + full_limit_usd_amt AS height,
        client_limit_usd_amt AS client_limit,
        client_premium_gross_usd_amt AS client_premium,
        COUNT(*) OVER (PARTITION BY stack_hash, policy_incept_year, root_basic_id) AS scope_rows
    FROM MarketDataStore.Business.Lumen."RateChange_Calcs"."RateChange_Base_Data"
),
a1 AS (
    SELECT b.*, LAG(attachment) OVER (PARTITION BY stack_hash, policy_year, root_basic_id ORDER BY attachment, policy_id) AS prev_att
    FROM b
    WHERE scope_rows > 1
),
a2 AS (
    SELECT a1.*, SUM(CASE WHEN a1.prev_att IS NULL OR a1.attachment - a1.prev_att > p.geo_tol * a1.prev_att THEN 1 ELSE 0 END)
        OVER (PARTITION BY a1.stack_hash, a1.policy_year, a1.root_basic_id ORDER BY a1.attachment, a1.policy_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS g_att
    FROM a1 CROSS JOIN p
),
h1 AS (
    SELECT a2.*, LAG(height) OVER (PARTITION BY stack_hash, policy_year, root_basic_id, g_att ORDER BY height, policy_id) AS prev_h
    FROM a2
),
h2 AS (
    SELECT h1.*, SUM(CASE WHEN h1.prev_h IS NULL OR h1.height - h1.prev_h > p.geo_tol * h1.prev_h THEN 1 ELSE 0 END)
        OVER (PARTITION BY h1.stack_hash, h1.policy_year, h1.root_basic_id, h1.g_att ORDER BY h1.height, h1.policy_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS g_h
    FROM h1 CROSS JOIN p
),
multi AS (
    SELECT policy_id, root_basic_id, root_account_name, stack_hash, insured_name, policy_year, next_year,
           attachment, full_limit, height, client_limit, client_premium,
           MIN(policy_id) OVER (PARTITION BY stack_hash, policy_year, root_basic_id, g_att, g_h) AS position_id,
           COUNT(*) OVER (PARTITION BY stack_hash, policy_year, root_basic_id, g_att, g_h) AS position_rows
    FROM h2
),
single AS (
    SELECT policy_id, root_basic_id, root_account_name, stack_hash, insured_name, policy_year, next_year,
           attachment, full_limit, height, client_limit, client_premium,
           policy_id AS position_id,
           1 AS position_rows
    FROM b
    WHERE scope_rows = 1
)
SELECT policy_id, root_basic_id, root_account_name, stack_hash, insured_name, policy_year, next_year,
       attachment, full_limit, height, client_limit, client_premium, position_id, position_rows
FROM multi
UNION ALL
SELECT policy_id, root_basic_id, root_account_name, stack_hash, insured_name, policy_year, next_year,
       attachment, full_limit, height, client_limit, client_premium, position_id, position_rows
FROM single;

-- @object 03_lfl_row_cluster
-- Table 03_lfl_row_cluster: the clean-up of positions that have more than one row (single-row positions skip it).
-- Inside a position (same stack, cedant, policy year and layer shape):
--   1. duplicates: rows with the same attachment, full limit and client limit (so the same client share) whose premiums are within
--      premium_tol of the previous (rows sorted by premium) form a cluster. A cluster = duplicates: counted once, at the median premium.
--   2. every cluster is added (premium and client limit). If the added client limits exceed the position's full limit
--      (sum_limit > position_full_limit * (1 + share_tol)), the largest cluster limit is used instead (limit_rank = 1).
-- Row level: premium_counted and limit_counted are the amounts each source row contributes to the position, they add up to
-- eff_premium and eff_client_limit of 04_lfl_position. is_dup_copy = 1 on the rows whose cluster is carried by its representative
-- (lowest policy_id of the cluster).
-- One linear chain of window functions: every CTE is read exactly once (Dremio recomputes a CTE per reference). Medians are the average
-- of the middle row(s) of the sorted cluster (ROW_NUMBER and the cluster size), not PERCENTILE_CONT.
DROP TABLE IF EXISTS "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."03_lfl_row_cluster";
CREATE TABLE "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."03_lfl_row_cluster" AS
WITH p AS (
    SELECT * FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params"
),
m AS (
    SELECT policy_id, position_id, position_rows, stack_hash, root_basic_id, root_account_name, insured_name, policy_year, next_year,
           attachment, full_limit, height, client_limit, client_premium
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo"
    WHERE position_rows > 1
),
q1 AS (
    SELECT m.*, LAG(client_premium) OVER (PARTITION BY position_id, attachment, full_limit, client_limit ORDER BY client_premium, policy_id) AS prev_premium
    FROM m
),
q2 AS (
    SELECT q1.*, SUM(CASE WHEN q1.prev_premium IS NULL OR (q1.client_premium - q1.prev_premium) / q1.client_premium > p.premium_tol THEN 1 ELSE 0 END)
        OVER (PARTITION BY q1.position_id, q1.attachment, q1.full_limit, q1.client_limit ORDER BY q1.client_premium, q1.policy_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS premium_cluster
    FROM q1 CROSS JOIN p
),
c1 AS (
    SELECT q2.*,
           MIN(policy_id) OVER (PARTITION BY position_id, attachment, full_limit, client_limit, premium_cluster) AS cluster_rep,
           COUNT(*) OVER (PARTITION BY position_id, attachment, full_limit, client_limit, premium_cluster) AS cluster_rows,
           ROW_NUMBER() OVER (PARTITION BY position_id, attachment, full_limit, client_limit, premium_cluster ORDER BY client_premium, policy_id) AS rn_premium,
           ROW_NUMBER() OVER (PARTITION BY position_id ORDER BY full_limit, policy_id) AS rn_full
    FROM q2
),
c2 AS (
    SELECT c1.*,
           AVG(CASE WHEN rn_premium * 2 IN (cluster_rows, cluster_rows + 1, cluster_rows + 2) THEN client_premium END)
               OVER (PARTITION BY position_id, attachment, full_limit, client_limit, premium_cluster) AS cluster_premium,
           client_limit AS cluster_limit,
           AVG(CASE WHEN rn_full * 2 IN (position_rows, position_rows + 1, position_rows + 2) THEN full_limit END)
               OVER (PARTITION BY position_id) AS position_full_limit
    FROM c1
),
c3 AS (
    SELECT c2.*,
           SUM(CASE WHEN policy_id = cluster_rep THEN cluster_limit ELSE 0 END) OVER (PARTITION BY position_id) AS sum_limit,
           SUM(CASE WHEN policy_id = cluster_rep THEN 1 ELSE 0 END) OVER (PARTITION BY position_id) AS n_clusters,
           ROW_NUMBER() OVER (PARTITION BY position_id
                              ORDER BY CASE WHEN policy_id = cluster_rep THEN 0 ELSE 1 END, cluster_limit DESC, cluster_rep) AS limit_rank
    FROM c2
)
SELECT
    c3.policy_id,
    c3.position_id,
    c3.stack_hash,
    c3.root_basic_id,
    c3.root_account_name,
    c3.insured_name,
    c3.policy_year,
    c3.next_year,
    c3.attachment,
    c3.full_limit,
    c3.height,
    c3.client_limit,
    c3.client_premium,
    c3.premium_cluster,
    c3.cluster_rep,
    c3.cluster_rows,
    c3.n_clusters,
    CASE WHEN c3.policy_id = c3.cluster_rep THEN 0 ELSE 1 END AS is_dup_copy,
    c3.cluster_premium,
    c3.cluster_limit,
    c3.sum_limit,
    c3.position_full_limit,
    CASE WHEN c3.sum_limit > c3.position_full_limit * (1 + p.share_tol) THEN 1 ELSE 0 END AS limit_rule_max,
    CASE WHEN c3.policy_id = c3.cluster_rep THEN c3.cluster_premium ELSE 0 END AS premium_counted,
    CASE WHEN c3.policy_id <> c3.cluster_rep THEN 0
         WHEN c3.sum_limit <= c3.position_full_limit * (1 + p.share_tol) THEN c3.cluster_limit
         WHEN c3.limit_rank = 1 THEN c3.cluster_limit
         ELSE 0 END AS limit_counted
FROM c3
CROSS JOIN p;

-- @object 04_lfl_position
-- Table 04_lfl_position: one row per position = one cedant's effective policy in one layer shape (geometry group) of one stack and year.
-- eff_premium and eff_client_limit belong to the position, they are built from its source rows (03_lfl_row_cluster for positions with several rows).
-- Single-row positions pass through. eff_client_share = eff_client_limit / full_limit (the effective share of the position, after the
-- largest-limit rule), share_over_100 = 1 when it exceeds 1 + share_tol.
-- scope_positions = positions of the same stack, cedant and year (guard against oversized scopes in the matching).
DROP TABLE IF EXISTS "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position";
CREATE TABLE "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position" AS
WITH p AS (
    SELECT * FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params"
),
single AS (
    SELECT position_id, stack_hash, root_basic_id, root_account_name, insured_name, policy_year, next_year,
           attachment, full_limit, height,
           1 AS position_rows, 1 AS n_clusters,
           client_premium AS eff_premium,
           client_limit AS eff_client_limit,
           CAST(client_limit AS DOUBLE) / CAST(full_limit AS DOUBLE) AS eff_client_share
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."02_lfl_row_geo"
    WHERE position_rows = 1
),
multi AS (
    SELECT position_id,
           MIN(stack_hash) AS stack_hash,
           MIN(root_basic_id) AS root_basic_id,
           MIN(root_account_name) AS root_account_name,
           MIN(insured_name) AS insured_name,
           MIN(policy_year) AS policy_year,
           MIN(next_year) AS next_year,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY attachment) AS attachment,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY full_limit) AS full_limit,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY height) AS height,
           COUNT(*) AS position_rows,
           MIN(n_clusters) AS n_clusters,
           SUM(premium_counted) AS eff_premium,
           SUM(limit_counted) AS eff_client_limit
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."03_lfl_row_cluster"
    GROUP BY position_id
),
u AS (
    SELECT position_id, stack_hash, root_basic_id, root_account_name, insured_name, policy_year, next_year,
           attachment, full_limit, height, position_rows, n_clusters, eff_premium, eff_client_limit, eff_client_share
    FROM single
    UNION ALL
    SELECT position_id, stack_hash, root_basic_id, root_account_name, insured_name, policy_year, next_year,
           attachment, full_limit, height, position_rows, n_clusters, eff_premium, eff_client_limit,
           eff_client_limit / full_limit AS eff_client_share
    FROM multi
)
SELECT
    u.position_id, u.stack_hash, u.root_basic_id, u.root_account_name, u.insured_name, u.policy_year, u.next_year,
    u.attachment, u.full_limit, u.height, u.position_rows, u.n_clusters,
    u.eff_premium, u.eff_client_limit, u.eff_client_share,
    CASE WHEN u.eff_client_share > 1 + p.share_tol THEN 1 ELSE 0 END AS share_over_100,
    u.eff_premium / u.eff_client_limit AS eff_rol,
    COUNT(*) OVER (PARTITION BY u.stack_hash, u.root_basic_id, u.policy_year) AS scope_positions
FROM u
CROSS JOIN p;
