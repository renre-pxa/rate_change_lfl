-- Source component: 01_setup.sql
-- ==============================================================================================================
-- 01_setup.sql: parameters (a view, nothing is computed)
-- Run the statements of this file, then 02 to 06 in order. Every statement is executable as it stands.
-- Object: 01_rate_change_params (view). Location of every object: "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update".
-- Names start with the run order number, lfl = an object of the like-for-like calculation, rate_change = generic (parameters, reporting).
-- The base data is taken as given and is read directly by 02_lfl_row_geo from MarketDataStore.Business.Lumen."RateChange_Calcs"."RateChange_Base_Data".
-- Docs: README.md (run order and deployment), sql/LFL_Method_Description.md (rules and columns).
-- ==============================================================================================================

-- @object 01_rate_change_params
-- View 01_rate_change_params: every tolerance and threshold of the stack, one row (sql/LFL_Method_Description.md section 5).
CREATE OR REPLACE VIEW "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params" AS
SELECT
    CAST(0.005 AS DOUBLE) AS geo_tol,        -- within a stack-year: attachment, then height, chained gap tolerance (same layer shape)
    CAST(0.005 AS DOUBLE) AS limit_tol,      -- inside a position: client limits within this are the same client share
    CAST(0.005 AS DOUBLE) AS premium_tol,    -- inside a share group: premiums within this are duplicates (counted once, median)
    CAST(0.0001 AS DOUBLE) AS share_tol,     -- added client shares above 1 + share_tol are flagged (and the largest limit is used)
    CAST(0.05 AS DOUBLE) AS renewal_tol,     -- year to year: attachment and height tolerance of a renewal candidate
    CAST(1.9 AS DOUBLE) AS rol_gate,         -- year to year: rate on line ratio must be within [1/rol_gate, rol_gate]
    CAST(0.05 AS DOUBLE) AS scan_tol,        -- layer scan: attachment and height tolerance against last year's layer medians
    1000 AS max_scope_positions              -- guard: stack-cedant-year (renewal) and stack-year (scan) scopes larger than this are not matched
;

-- Source component: 02_positions.sql
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

-- Source component: 03_renewals.sql
-- ==============================================================================================================
-- 03_renewals.sql: renewal candidates, premium gate, 1:1 matching
-- Objects (stored tables): 05_lfl_candidate, 06_lfl_renewal. 06_lfl_renewal is the same matching round written out four times (m1 to m4). Changing the number of rounds means editing this file directly.
-- ==============================================================================================================

-- @object 05_lfl_candidate
-- Table 05_lfl_candidate: renewal candidate pairs between positions of the same stack and cedant, year t to t+1.
-- A pair is listed when attachment AND height are each within renewal_tol of the prior position's value.
-- score = attachment gap / tolerance + height gap / tolerance (lower is better, premium is not in the score).
-- rol_ratio = rate on line next / prior, gate_ok = 1 when it is within [1/rol_gate, rol_gate] (the premium gate).
-- Pairs that fail the gate are kept here (gate_ok = 0) for audit, only gate_ok = 1 enters the matching (06_lfl_renewal).
-- Joins are on plain columns (stack_hash, root_basic_id, next_year = policy_year) so Dremio plans hash joins.
DROP TABLE IF EXISTS "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."05_lfl_candidate";
CREATE TABLE "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."05_lfl_candidate" AS
WITH p AS (
    SELECT * FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params"
),
a AS (
    SELECT position_id, stack_hash, root_basic_id, policy_year, next_year, attachment, height, eff_rol
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"
    CROSS JOIN p
    WHERE scope_positions <= p.max_scope_positions
),
b AS (
    SELECT position_id, stack_hash, root_basic_id, policy_year, attachment, height, eff_rol
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"
    CROSS JOIN p
    WHERE scope_positions <= p.max_scope_positions
)
SELECT
    a.position_id AS prior_id,
    b.position_id AS next_id,
    a.stack_hash,
    a.root_basic_id,
    a.policy_year AS prior_year,
    ABS(b.attachment - a.attachment) / (p.renewal_tol * a.attachment)
        + ABS(b.height - a.height) / (p.renewal_tol * a.height) AS score,
    b.eff_rol / a.eff_rol AS rol_ratio,
    CASE WHEN b.eff_rol / a.eff_rol BETWEEN 1 / p.rol_gate AND p.rol_gate THEN 1 ELSE 0 END AS gate_ok
FROM a
INNER JOIN b ON a.stack_hash = b.stack_hash AND a.root_basic_id = b.root_basic_id AND a.next_year = b.policy_year
CROSS JOIN p
WHERE ABS(b.attachment - a.attachment) <= p.renewal_tol * a.attachment
  AND ABS(b.height - a.height) <= p.renewal_tol * a.height;

-- BEGIN renewal matching rounds
-- @object 06_lfl_renewal
-- Table 06_lfl_renewal: accepted like-for-like renewals (position t -> position t+1, same stack and cedant), 1:1.
-- Candidates that passed the rate-on-line gate are ranked by (score, prior_id, next_id). A round accepts every candidate
-- that is the best remaining candidate of BOTH its prior and its next position, then drops the other candidates that
-- touch an accepted position. 4 rounds are written out one after another, candidates still
-- open after the last round stay unmatched (checked in view 14_rate_change_qa_checks, see sql/LFL_Method_Description.md section 10).
DROP TABLE IF EXISTS "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal";
CREATE TABLE "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal" AS
WITH cand AS (
    SELECT prior_id, next_id, stack_hash, root_basic_id, prior_year, score, rol_ratio
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."05_lfl_candidate"
    WHERE gate_ok = 1
),
m0 AS (SELECT c.*, CAST(NULL AS INTEGER) AS match_round FROM cand c),
m1r AS (SELECT c.*,
        ROW_NUMBER() OVER (PARTITION BY c.prior_id ORDER BY c.score, c.prior_id, c.next_id) AS rp,
        ROW_NUMBER() OVER (PARTITION BY c.next_id ORDER BY c.score, c.prior_id, c.next_id) AS rc
    FROM m0 c),
m1t AS (SELECT r.*, CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 1 ELSE 0 END AS acc,
        MAX(CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY r.prior_id) AS hit_p,
        MAX(CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY r.next_id) AS hit_c
    FROM m1r r),
m1 AS (SELECT prior_id, next_id, stack_hash, root_basic_id, prior_year, score, rol_ratio, CASE WHEN acc = 1 THEN 1 ELSE match_round END AS match_round
    FROM m1t WHERE match_round IS NOT NULL OR acc = 1 OR (hit_p = 0 AND hit_c = 0)),
m2r AS (SELECT c.*,
        ROW_NUMBER() OVER (PARTITION BY c.prior_id ORDER BY c.score, c.prior_id, c.next_id) AS rp,
        ROW_NUMBER() OVER (PARTITION BY c.next_id ORDER BY c.score, c.prior_id, c.next_id) AS rc
    FROM m1 c),
m2t AS (SELECT r.*, CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 1 ELSE 0 END AS acc,
        MAX(CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY r.prior_id) AS hit_p,
        MAX(CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY r.next_id) AS hit_c
    FROM m2r r),
m2 AS (SELECT prior_id, next_id, stack_hash, root_basic_id, prior_year, score, rol_ratio, CASE WHEN acc = 1 THEN 2 ELSE match_round END AS match_round
    FROM m2t WHERE match_round IS NOT NULL OR acc = 1 OR (hit_p = 0 AND hit_c = 0)),
m3r AS (SELECT c.*,
        ROW_NUMBER() OVER (PARTITION BY c.prior_id ORDER BY c.score, c.prior_id, c.next_id) AS rp,
        ROW_NUMBER() OVER (PARTITION BY c.next_id ORDER BY c.score, c.prior_id, c.next_id) AS rc
    FROM m2 c),
m3t AS (SELECT r.*, CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 1 ELSE 0 END AS acc,
        MAX(CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY r.prior_id) AS hit_p,
        MAX(CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 1 ELSE 0 END) OVER (PARTITION BY r.next_id) AS hit_c
    FROM m3r r),
m3 AS (SELECT prior_id, next_id, stack_hash, root_basic_id, prior_year, score, rol_ratio, CASE WHEN acc = 1 THEN 3 ELSE match_round END AS match_round
    FROM m3t WHERE match_round IS NOT NULL OR acc = 1 OR (hit_p = 0 AND hit_c = 0)),
m4r AS (SELECT c.*,
        ROW_NUMBER() OVER (PARTITION BY c.prior_id ORDER BY c.score, c.prior_id, c.next_id) AS rp,
        ROW_NUMBER() OVER (PARTITION BY c.next_id ORDER BY c.score, c.prior_id, c.next_id) AS rc
    FROM m3 c),
m4 AS (SELECT r.*, CASE WHEN r.match_round IS NULL AND r.rp = 1 AND r.rc = 1 THEN 4 ELSE r.match_round END AS final_round
    FROM m4r r)
SELECT prior_id, next_id, stack_hash, root_basic_id, prior_year, prior_year + 1 AS next_year, score, rol_ratio,
       final_round AS match_round
FROM m4
WHERE final_round IS NOT NULL;

-- END renewal matching rounds
