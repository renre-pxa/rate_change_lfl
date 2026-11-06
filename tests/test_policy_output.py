from pathlib import Path
import re
import sqlite3
import statistics
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'core'


class Median:
    def __init__(self):
        self.values = []

    def step(self, value):
        if value is not None:
            self.values.append(value)

    def finalize(self):
        return statistics.median(self.values) if self.values else None


def aggregate_sql(sql):
    sql = portable(sql).replace('CREATE OR REPLACE VIEW', 'CREATE VIEW')
    return re.sub(r'PERCENTILE_CONT\(0\.5\) WITHIN GROUP \(ORDER BY (\w+)\)', r'MEDIAN(\1)', sql)


def portable(sql):
    return re.sub(r'(?:"Sandbox_lake"|Sandbox)\.Underwriting\.Lumen\.Casualty\."Rate_Change"\."Method_Update"\."([^"]+)"', r'"\1"', sql)


class PolicyOutputTests(unittest.TestCase):
    def setUp(self):
        self.connection = sqlite3.connect(':memory:')
        self.addCleanup(self.connection.close)
        self.connection.row_factory = sqlite3.Row
        self.connection.executescript('''
CREATE TABLE "01_rate_change_params" (max_scope_positions INT, share_tol REAL);
INSERT INTO "01_rate_change_params" VALUES (1000, 0.0001);
CREATE TABLE "02_lfl_row_geo" (policy_id INT, position_id INT, stack_hash TEXT, root_basic_id INT,
root_account_name TEXT, insured_name TEXT, policy_year INT, attachment REAL, full_limit REAL, client_limit REAL, client_premium REAL);
INSERT INTO "02_lfl_row_geo" VALUES
(1,1,'stack',7,'cedant','insured',2021,100,100,20,2),
(2,1,'stack',7,'cedant','insured',2021,100,100,20,2),
(3,3,'stack',7,'cedant','insured',2022,100,100,20,3);
CREATE TABLE "03_lfl_row_cluster" (policy_id INT, is_dup_copy INT, cluster_rows INT, n_clusters INT,
premium_counted REAL, limit_counted REAL);
INSERT INTO "03_lfl_row_cluster" VALUES (1,0,2,1,2,20),(2,1,2,1,0,0);
CREATE TABLE "04_lfl_position" (position_id INT, policy_year INT, attachment REAL, full_limit REAL, height REAL,
position_rows INT, n_clusters INT, eff_premium REAL, eff_client_limit REAL, eff_rol REAL, scope_positions INT);
INSERT INTO "04_lfl_position" VALUES (1,2021,100,100,200,2,1,2,20,0.1,1),(3,2022,100,100,200,1,1,3,20,0.15,1);
CREATE TABLE "05_lfl_candidate" (prior_id INT, next_id INT, score REAL, gate_ok INT, rol_ratio REAL);
INSERT INTO "05_lfl_candidate" VALUES (1,3,0,1,1.5);
CREATE TABLE "06_lfl_renewal" (prior_id INT, next_id INT, score REAL, match_round INT, rol_ratio REAL);
INSERT INTO "06_lfl_renewal" VALUES (1,3,0,1,1.5);
CREATE TABLE "07_lfl_layer_position" (position_id INT, layer_id INT, layer_assignment TEXT);
INSERT INTO "07_lfl_layer_position" VALUES (1,1,'first_year'),(3,1,'renewal');
''')

    def build(self):
        self.connection.executescript(portable((CORE / 'sql' / '03_policy_output.sql').read_text(encoding='utf-8')))
        return self.connection.execute('SELECT * FROM "08_lfl_policy_out" ORDER BY policy_id').fetchall()

    def test_source_grain_and_contributions(self):
        rows = self.build()
        self.assertEqual([row['policy_id'] for row in rows], [1, 2, 3])
        self.assertEqual([row['row_role'] for row in rows], ['duplicate_kept', 'duplicate_copy', 'single'])
        self.assertEqual(sum(row['premium_counted'] for row in rows), 5)
        self.assertEqual(sum(row['limit_counted'] for row in rows), 40)
        self.assertEqual(rows[1]['position_premium'], 2)
        self.assertEqual(rows[0]['next_position_id'], 3)
        self.assertEqual(rows[2]['prior_position_id'], 1)
        self.assertEqual(rows[2]['status_next'], 'last_year')
        self.assertNotIn('is_dup_copy', rows[0].keys())
        self.assertNotIn('origin', rows[0].keys())

    def test_layer_inputs_deduplicate_positions(self):
        self.build()
        result = self.connection.execute('''
WITH positions AS (
SELECT DISTINCT position_id, layer_id, policy_year, position_rows, position_attachment,
position_height, position_premium, position_client_limit, next_position_id,
next_position_premium, next_position_client_limit FROM "08_lfl_policy_out"
)
SELECT COUNT(*), SUM(position_rows), SUM(position_premium), SUM(next_position_premium)
FROM positions WHERE policy_year = 2021
''').fetchone()
        self.assertEqual(tuple(result), (1, 2, 2, 3))

    def test_invalid_cluster_amount_is_not_hidden_by_source_fallback(self):
        self.connection.execute('UPDATE "03_lfl_row_cluster" SET limit_counted = NULL WHERE policy_id = 1')
        self.assertIsNone(self.build()[0]['limit_counted'])

    def test_layer_summary_recipe(self):
        self.build()
        self.connection.create_aggregate('MEDIAN', 1, Median)
        query = aggregate_sql((ROOT / 'queries' / 'layer_summary.sql').read_text())
        rows = self.connection.execute(query).fetchall()
        prior = next(row for row in rows if row['policy_year'] == 2021)
        self.assertEqual(prior['n_positions'], 1)
        self.assertEqual(prior['n_source_rows'], 2)
        self.assertEqual(prior['layer_premium'], 2)
        self.assertEqual(prior['layer_attachment_median'], 100)
        self.assertEqual(prior['n_cedants_left'], 0)
        self.assertEqual(prior['n_cedants_joined'], 0)
        self.assertAlmostEqual(prior['lfl_rol_change_pct'], 0.5)
        self.assertAlmostEqual(prior['all_cedants_rol_change_pct'], 0.5)

    def test_summary_does_not_double_count_duplicate_rows(self):
        self.build()
        self.connection.create_aggregate('MEDIAN', 1, Median)
        self.connection.create_function('CONCAT', 3, lambda first, separator, last: str(first) + separator + str(last))
        sql = aggregate_sql((CORE / 'sql' / 'source' / '06_reporting.sql').read_text())
        first_view = sql.split('-- @object 13_rate_change_funnel')[0]
        self.connection.executescript(first_view)
        rows = self.connection.execute('SELECT * FROM "12_rate_change_summary"').fetchall()
        for row in rows:
            self.assertEqual(row['renewal_pairs'], 1)
            self.assertEqual(row['premium_t'], 2)
            self.assertEqual(row['premium_t1'], 3)
            self.assertAlmostEqual(row['change_in_rol'], 0.5)

    def test_qa_detects_missing_policies_and_null_contributions(self):
        self.build()
        self.connection.executescript('''
ALTER TABLE "02_lfl_row_geo" ADD COLUMN position_rows INT;
ALTER TABLE "02_lfl_row_geo" ADD COLUMN height REAL;
UPDATE "02_lfl_row_geo" SET position_rows = CASE WHEN position_id = 1 THEN 2 ELSE 1 END, height = 200;
ALTER TABLE "04_lfl_position" ADD COLUMN share_over_100 INT DEFAULT 0;
''')
        reporting = (CORE / 'sql' / 'source' / '06_reporting.sql').read_text()
        qa_sql = reporting.split('-- @object 14_rate_change_qa_checks')[1]
        self.connection.executescript(aggregate_sql(qa_sql))
        rows = self.connection.execute('SELECT * FROM "14_rate_change_qa_checks"').fetchall()
        self.assertTrue(all(row['check_value'] == row['expected'] for row in rows if row['expected'] is not None))
        self.connection.execute('DELETE FROM "08_lfl_policy_out" WHERE policy_id = 2')
        self.connection.execute('UPDATE "08_lfl_policy_out" SET limit_counted = NULL WHERE policy_id = 1')
        checks = {row['check_name']: row['check_value'] for row in self.connection.execute('SELECT * FROM "14_rate_change_qa_checks"')}
        self.assertEqual(checks['source policies missing from output'], 1)
        self.assertEqual(checks['published counted amounts non-null'], 1)

    def test_layer_summary_cedant_movement_and_unweighted_median(self):
        self.build()
        self.connection.execute('''INSERT INTO "08_lfl_policy_out"
(policy_id, position_id, layer_id, policy_year, root_basic_id, position_rows,
position_attachment, position_height, position_premium, position_client_limit)
VALUES (4,4,1,2021,8,1,200,300,4,20), (5,5,1,2022,9,1,300,400,5,20)''')
        self.connection.create_aggregate('MEDIAN', 1, Median)
        query = aggregate_sql((ROOT / 'queries' / 'layer_summary.sql').read_text())
        prior = next(row for row in self.connection.execute(query) if row['policy_year'] == 2021)
        self.assertEqual(prior['n_cedants_left'], 1)
        self.assertEqual(prior['n_cedants_joined'], 1)
        self.assertEqual(prior['layer_attachment_median'], 150)
        self.assertEqual(prior['n_source_rows'], 3)


if __name__ == '__main__':
    unittest.main()