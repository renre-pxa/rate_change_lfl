import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core"
SPEC = importlib.util.spec_from_file_location("run_dremio", CORE / "tools" / "run_dremio.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
BUILD_SPEC = importlib.util.spec_from_file_location("build_phases", CORE / "tools" / "build_phases.py")
builder = importlib.util.module_from_spec(BUILD_SPEC)
BUILD_SPEC.loader.exec_module(builder)


class RunnerTests(unittest.TestCase):
    def test_split_handles_comments_and_quoted_semicolons(self):
        self.assertEqual(len(runner.split_sql("-- comment;\nSELECT 'a;b'; SELECT 2; -- trailing\n")), 2)

    def test_missing_terminator_rejected(self):
        with self.assertRaises(ValueError):
            runner.split_sql("SELECT 1")

    def test_layers_advance_and_stop_at_null(self):
        client = Mock()
        client.execute.side_effect = [[{"yr": 2023}], [], [{"yr": 2025}], [], [{"yr": None}]]
        runner.fill_layers(client, "YEAR", "INSERT", 10)
        self.assertEqual([call.args[0] for call in client.execute.call_args_list],
                         ["YEAR", "INSERT", "YEAR", "INSERT", "YEAR"])

    def test_layers_stop_on_no_progress(self):
        client = Mock()
        client.execute.side_effect = [[{"yr": 2023}], [], [{"yr": 2023}]]
        with self.assertRaisesRegex(RuntimeError, "did not advance"):
            runner.fill_layers(client, "YEAR", "INSERT", 10)
        self.assertEqual(client.execute.call_count, 3)

    def test_empty_layers_does_not_insert(self):
        client = Mock()
        client.execute.return_value = [{"yr": None}]
        runner.fill_layers(client, "YEAR", "INSERT", 10)
        client.execute.assert_called_once_with("YEAR", results=True)

    def test_year_bound_prevents_more_inserts(self):
        client = Mock()
        client.execute.side_effect = [[{"yr": 2023}], [], [{"yr": 2024}]]
        with self.assertRaisesRegex(RuntimeError, "max-years"):
            runner.fill_layers(client, "YEAR", "INSERT", 1)

    def test_api_polls_before_fetching_results(self):
        client = runner.Dremio("https://dremio.example", "test-token")
        client.request = Mock(side_effect=[{"id": "job-1"}, {"jobState": "RUNNING"},
                                          {"jobState": "COMPLETED"}, {"rows": [{"yr": 2023}]}])
        with patch.object(runner.time, "sleep"):
            self.assertEqual(client.execute("SELECT 1", results=True), [{"yr": 2023}])
        self.assertEqual(client.request.call_args.args[1], "/job/job-1/results?offset=0&limit=500")

    def test_failed_job_is_not_resubmitted(self):
        client = runner.Dremio("https://dremio.example", "test-token")
        client.request = Mock(side_effect=[{"id": "job-1"}, {"jobState": "FAILED", "errorMessage": "bad SQL"}])
        with self.assertRaisesRegex(RuntimeError, "bad SQL"):
            client.execute("INSERT")
        self.assertEqual(client.request.call_count, 2)

    def test_timeout_does_not_resubmit(self):
        client = runner.Dremio("https://dremio.example", "test-token")
        client.request = Mock(side_effect=[{"id": "job-1"}, {"jobState": "RUNNING"}])
        with patch.object(runner.time, "monotonic", side_effect=[0, 20000]):
            with self.assertRaisesRegex(RuntimeError, "may still be running"):
                client.execute("INSERT")

    def test_rebuild_requires_confirmation(self):
        with self.assertRaises(SystemExit) as result:
            runner.main(["--mode", "full"])
        self.assertEqual(result.exception.code, 2)

    def test_layer_cte_extraction(self):
        insert = "INSERT INTO layers\nWITH y AS (\nSELECT MIN(policy_year) AS yr FROM positions\n),\npos AS (SELECT 1) SELECT * FROM pos;"
        query, extracted = runner.layer_queries([("insert", "07_lfl_layer_position", [insert])])
        self.assertEqual(query, "SELECT MIN(policy_year) AS yr FROM positions")
        self.assertEqual(extracted, insert)

    def test_run_sections_skips_insert(self):
        client = Mock()
        runner.run_sections(client, [("object", "layers", ["DROP", "CREATE"]), ("insert", "layers", ["INSERT"])])
        self.assertEqual([call.args[0] for call in client.execute.call_args_list], ["DROP", "CREATE"])

    def test_outputs_needs_no_reporting_file_and_submits_no_qa(self):
        root = CORE
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            (temporary / '03_policy_output.sql').write_text((root / 'sql' / '03_policy_output.sql').read_text(), encoding='utf-8')
            args = ["--mode", "outputs", "--sql-dir", directory,
                    "--lock-file", str(temporary / "run.lock")]
            with patch.dict(runner.os.environ, {"DREMIO_URL": "https://example.test", "DREMIO_TOKEN": "test"}), \
                    patch.object(runner, "Dremio") as client_class:
                self.assertEqual(runner.main(args), 0)
                sql = [call.args[0] for call in client_class.return_value.execute.call_args_list]
                self.assertEqual(len(sql), 2)
                self.assertTrue(all('08_lfl_policy_out' in statement for statement in sql))
                self.assertTrue(all('14_rate_change_qa_checks' not in statement for statement in sql))
                self.assertFalse((temporary / "run.lock").exists())

    def test_full_excludes_reporting_file(self):
        self.assertEqual(runner.FILES, (
            '01_data_prep.sql', '02_layer_assignment.sql', '03_policy_output.sql'
        ))

    def test_phase_builder_bundles_preserved_components(self):
        root = CORE
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            builder.build(root / 'sql' / 'source', output)
            self.assertEqual(set(path.name for path in output.glob('*.sql')), set(builder.PHASES))
            data_prep = (output / '01_data_prep.sql').read_text(encoding='utf-8')
            self.assertIn('-- Source component: 01_setup.sql', data_prep)
            self.assertIn('-- Source component: 02_positions.sql', data_prep)
            self.assertIn('-- Source component: 03_renewals.sql', data_prep)
            self.assertNotIn('06_reporting.sql', data_prep)

    def test_phase_builder_places_stored_tables_02_to_06_in_sandbox_lake(self):
        root = CORE
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            builder.build(root / 'sql' / 'source', output)
            sql = '\n'.join(path.read_text(encoding='utf-8') for path in output.glob('*.sql'))
            for name in builder.TABLE_OBJECTS:
                self.assertIn(f'"Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."{name}"', sql)
                self.assertNotIn(f'Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."{name}"', sql)
            self.assertIn('Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."01_rate_change_params"', sql)

    def test_outputs_needs_only_output_bundle_and_submits_no_reporting(self):
        root = CORE
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            (temporary / '03_policy_output.sql').write_text(
                (root / 'sql' / '03_policy_output.sql').read_text(encoding='utf-8'), encoding='utf-8'
            )
            args = ['--mode', 'outputs', '--sql-dir', directory,
                    '--lock-file', str(temporary / 'run.lock')]
            with patch.dict(runner.os.environ, {'DREMIO_URL': 'https://example.test', 'DREMIO_TOKEN': 'test'}), \
                    patch.object(runner, 'Dremio') as client_class:
                self.assertEqual(runner.main(args), 0)
                statements = [call.args[0] for call in client_class.return_value.execute.call_args_list]
                self.assertEqual(len(statements), 2)
                self.assertTrue(all('08_lfl_policy_out' in statement for statement in statements))
                self.assertFalse((temporary / 'run.lock').exists())

    def test_full_mode_runs_three_phases_in_dependency_order(self):
        statements = {
            "01_data_prep.sql": "-- @object 01_params\nCREATE VIEW params AS SELECT 1;\n"
                                 "-- @object 02_geo\nCREATE TABLE geo AS SELECT 1;\n"
                                 "-- @object 03_cluster\nCREATE TABLE cluster AS SELECT 1;\n"
                                 "-- @object 04_position\nCREATE TABLE position AS SELECT 1;\n"
                                 "-- @object 05_candidate\nCREATE TABLE candidate AS SELECT 1;\n"
                                 "-- @object 06_renewal\nCREATE TABLE renewal AS SELECT 1;",
            "02_layer_assignment.sql": "-- @object 07_lfl_layer_position\nDROP TABLE layers;\nCREATE TABLE layers AS SELECT 1;\n"
                                       "-- @insert 07_lfl_layer_position\nINSERT INTO layers WITH y AS (\n"
                                       "SELECT MIN(policy_year) AS yr FROM positions\n),\n"
                                       "pos AS (SELECT 1) SELECT * FROM pos;",
            "03_policy_output.sql": "-- @object 08_lfl_policy_out\nCREATE TABLE output AS SELECT 1;",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, sql in statements.items():
                (root / name).write_text(sql, encoding="utf-8")
            args = ["--mode", "full", "--confirm-rebuild", "--sql-dir", directory,
                    "--lock-file", str(root / "run.lock")]
            with patch.dict(runner.os.environ, {"DREMIO_URL": "https://example.test", "DREMIO_TOKEN": "test"}), \
                    patch.object(runner, "Dremio") as client_class:
                client = client_class.return_value
                client.execute.side_effect = lambda sql, results=False: ([{"yr": None}] if results else [])
                self.assertEqual(runner.main(args), 0)
                submitted = [call.args[0] for call in client.execute.call_args_list]
                self.assertEqual(submitted, [
                    "CREATE VIEW params AS SELECT 1;",
                    "CREATE TABLE geo AS SELECT 1;",
                    "CREATE TABLE cluster AS SELECT 1;",
                    "CREATE TABLE position AS SELECT 1;",
                    "CREATE TABLE candidate AS SELECT 1;",
                    "CREATE TABLE renewal AS SELECT 1;",
                    "DROP TABLE layers;",
                    "CREATE TABLE layers AS SELECT 1;",
                    "SELECT MIN(policy_year) AS yr FROM positions",
                    "CREATE TABLE output AS SELECT 1;",
                ])

    def test_lock_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "02_layer_assignment.sql").write_text(
                "-- @object 07_lfl_layer_position\nCREATE TABLE layers AS SELECT 1;\n"
                "-- @insert 07_lfl_layer_position\nINSERT INTO layers\nWITH y AS (\n"
                "SELECT MIN(policy_year) AS yr FROM positions\n),\npos AS (SELECT 1) SELECT * FROM pos;",
                encoding="utf-8",
            )
            lock = root / "runner.lock"
            args = ["--sql-dir", directory, "--lock-file", str(lock)]
            with patch.dict(runner.os.environ, {"DREMIO_URL": "https://example.test", "DREMIO_TOKEN": "test"}), \
                    patch.object(runner, "Dremio") as client_class:
                client = client_class.return_value
                client.execute.return_value = [{"yr": None}]
                self.assertEqual(runner.main(args), 0)
                self.assertFalse(lock.exists())
                client.execute.side_effect = RuntimeError("network failure")
                self.assertEqual(runner.main(args), 1)
                self.assertTrue(lock.exists())
                client.execute.reset_mock()
                self.assertEqual(runner.main(args), 1)
                client.execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()