-- Source component: 04_layers.sql
-- ==============================================================================================================
-- 04_layers.sql: layer ids across cedants, tracked over time
-- Objects: 07_lfl_layer_position (one table, filled by INSERT, in the Sandbox_lake source: the only one that accepts INSERT). Reads 04_lfl_position, 06_lfl_renewal and 01_rate_change_params.
-- Run order: the first statement (re)creates the EMPTY table, the second (an INSERT) is run once per policy year, in order, until no
-- policy year remains. It needs no edit when a new policy year arrives: it always processes the earliest year not yet in the table.
-- ==============================================================================================================

-- @object 07_lfl_layer_position
-- Table 07_lfl_layer_position: layer ids across cedants. One row per position, with the layer it sits on (layer_id) and how it got it.
-- This statement only creates the table, empty (same column types as 04_lfl_position). Run the INSERT below to fill it.
DROP TABLE IF EXISTS "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."07_lfl_layer_position";
CREATE TABLE "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."07_lfl_layer_position" AS
SELECT position_id, stack_hash, policy_year, attachment, height, position_id AS layer_id, CAST('x' AS VARCHAR) AS layer_assignment
FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"
WHERE 1 = 0;

-- @insert 07_lfl_layer_position
-- Layer ids of ONE policy year: the earliest year of 04_lfl_position that is not in 07_lfl_layer_position yet. Run it once per policy year,
-- in order (the runner repeats it until no policy year remains, running it again later is harmless). It reads last year's layers from the table itself.
-- 1) renewal: a position that is the renewal of a prior-year position (same cedant, from 06_lfl_renewal) takes that position's layer_id.
-- 2) scan: any other position takes the prior-year layer of its stack whose MEDIAN attachment and height are within scan_tol
--    (lowest score, ties by layer_id). Stacks with more than max_scope_positions layers in the prior year are not scanned.
-- 3) new: the rest are grouped among themselves (chained gaps on attachment, then height, geo_tol), layer_id = lowest position_id of the group.
--    layer_assignment is first_year when the stack has no positions in the prior year (first year of the data, new stack, gap year), else new.
INSERT INTO "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."07_lfl_layer_position"
WITH p AS (
    SELECT * FROM Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params"
),
y AS (
    SELECT MIN(policy_year) AS yr
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position"
    WHERE policy_year > COALESCE((SELECT MAX(policy_year) FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."07_lfl_layer_position"), 0)
),
pos AS (
    SELECT s.position_id, s.stack_hash, s.attachment, s.height, y.yr AS policy_year
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."04_lfl_position" s
    CROSS JOIN y
    WHERE s.policy_year = y.yr
),
prior AS (
    SELECT l.position_id, l.stack_hash, l.attachment, l.height, l.layer_id
    FROM "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."07_lfl_layer_position" l
    CROSS JOIN y
    WHERE l.policy_year = y.yr - 1
),
inh AS (
    SELECT pos.position_id, pos.stack_hash, pr.layer_id, 'renewal' AS layer_assignment
    FROM pos
    INNER JOIN "Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."06_lfl_renewal" r ON r.next_id = pos.position_id
    INNER JOIN prior pr ON pr.position_id = r.prior_id
),
prior_med AS (
    SELECT stack_hash, layer_id,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY attachment) AS med_att,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY height) AS med_h
    FROM prior
    GROUP BY stack_hash, layer_id
),
prior_med2 AS (
    SELECT prior_med.*, COUNT(*) OVER (PARTITION BY stack_hash) AS stack_layers
    FROM prior_med
),
todo AS (
    SELECT pos.position_id, pos.stack_hash, pos.attachment, pos.height
    FROM pos
    LEFT JOIN inh ON inh.position_id = pos.position_id
    WHERE inh.position_id IS NULL
),
sc AS (
    SELECT t.position_id, m.layer_id,
           ABS(t.attachment - m.med_att) / (p.scan_tol * m.med_att) + ABS(t.height - m.med_h) / (p.scan_tol * m.med_h) AS score
    FROM todo t
    INNER JOIN prior_med2 m ON t.stack_hash = m.stack_hash
    CROSS JOIN p
    WHERE m.stack_layers <= p.max_scope_positions
      AND ABS(t.attachment - m.med_att) <= p.scan_tol * m.med_att
      AND ABS(t.height - m.med_h) <= p.scan_tol * m.med_h
),
sc1 AS (
    SELECT sc.*, ROW_NUMBER() OVER (PARTITION BY position_id ORDER BY score, layer_id) AS rn
    FROM sc
),
scan AS (
    SELECT t.position_id, t.stack_hash, s.layer_id, 'scan' AS layer_assignment
    FROM todo t
    INNER JOIN sc1 s ON s.position_id = t.position_id AND s.rn = 1
),
left_over AS (
    SELECT t.position_id, t.stack_hash, t.attachment, t.height
    FROM todo t
    LEFT JOIN sc1 s ON s.position_id = t.position_id AND s.rn = 1
    WHERE s.position_id IS NULL
),
n1 AS (
    SELECT left_over.*, LAG(attachment) OVER (PARTITION BY stack_hash ORDER BY attachment, position_id) AS prev_att
    FROM left_over
),
n2 AS (
    SELECT n1.*, SUM(CASE WHEN n1.prev_att IS NULL OR n1.attachment - n1.prev_att > p.geo_tol * n1.prev_att THEN 1 ELSE 0 END)
        OVER (PARTITION BY n1.stack_hash ORDER BY n1.attachment, n1.position_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS g_att
    FROM n1 CROSS JOIN p
),
n3 AS (
    SELECT n2.*, LAG(height) OVER (PARTITION BY stack_hash, g_att ORDER BY height, position_id) AS prev_h
    FROM n2
),
n4 AS (
    SELECT n3.*, SUM(CASE WHEN n3.prev_h IS NULL OR n3.height - n3.prev_h > p.geo_tol * n3.prev_h THEN 1 ELSE 0 END)
        OVER (PARTITION BY n3.stack_hash, n3.g_att ORDER BY n3.height, n3.position_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS g_h
    FROM n3 CROSS JOIN p
),
stacks_prior AS (
    SELECT DISTINCT stack_hash FROM prior_med
),
newg AS (
    SELECT n4.position_id, n4.stack_hash,
           MIN(n4.position_id) OVER (PARTITION BY n4.stack_hash, n4.g_att, n4.g_h) AS layer_id,
           CASE WHEN sp.stack_hash IS NULL THEN 'first_year' ELSE 'new' END AS layer_assignment
    FROM n4
    LEFT JOIN stacks_prior sp ON sp.stack_hash = n4.stack_hash
),
x AS (
    SELECT position_id, stack_hash, layer_id, layer_assignment FROM inh
    UNION ALL
    SELECT position_id, stack_hash, layer_id, layer_assignment FROM scan
    UNION ALL
    SELECT position_id, stack_hash, layer_id, layer_assignment FROM newg
)
SELECT x.position_id, x.stack_hash, pos.policy_year, pos.attachment, pos.height, x.layer_id, x.layer_assignment
FROM x
INNER JOIN pos ON pos.position_id = x.position_id;
