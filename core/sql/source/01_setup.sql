-- ==============================================================================================================
-- 01_setup.sql: parameters (a view, nothing is computed)
-- Run the statements of this file, then 02 to 06 in order. Every statement is executable as it stands.
-- Object: 01_rate_change_params (view). Location of every object: Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update" (tools/names.py).
-- Names start with the run order number, lfl = an object of the like-for-like calculation, rate_change = generic (parameters, reporting).
-- The base data is taken as given and is read directly by 02_lfl_row_geo from MarketDataStore.Business.Lumen."RateChange_Calcs"."RateChange_Base_Data".
-- Docs: docs/02_DEPLOYMENT.md (run order), docs/03_TECHNICAL_REFERENCE.md (rules and columns).
-- ==============================================================================================================

-- @object 01_rate_change_params
-- View 01_rate_change_params: every tolerance and threshold of the stack, one row (docs/03_TECHNICAL_REFERENCE.md section 1).
CREATE OR REPLACE VIEW Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params" AS
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
