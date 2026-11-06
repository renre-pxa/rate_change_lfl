"""Assemble the maintained SQL components into the three deployment bundles."""

import argparse
from pathlib import Path


PHASES = {
    "01_data_prep.sql": ("01_setup.sql", "02_positions.sql", "03_renewals.sql"),
    "02_layer_assignment.sql": ("04_layers.sql",),
    "03_policy_output.sql": ("05_outputs.sql",),
}
TABLE_OBJECTS = (
    "02_lfl_row_geo",
    "03_lfl_row_cluster",
    "04_lfl_position",
    "05_lfl_candidate",
    "06_lfl_renewal",
)


def lake_table_paths(sql):
    for name in TABLE_OBJECTS:
        source_path = f'Sandbox.Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."{name}"'
        lake_path = f'"Sandbox_lake".Underwriting.Lumen.Casualty."Rate_Change"."Method_Update"."{name}"'
        sql = sql.replace(source_path, lake_path)
    return sql


def build(source_dir: Path, output_dir: Path) -> None:
    bundles = {}
    for output_name, inputs in PHASES.items():
        parts = []
        for name in inputs:
            path = source_dir / name
            if not path.is_file():
                raise FileNotFoundError(f"Missing source SQL file: {path}")
            component_sql = lake_table_paths(path.read_text(encoding='utf-8-sig').rstrip())
            parts.append(f"-- Source component: {name}\n{component_sql}\n")
        bundles[output_name] = "\n".join(parts)

    output_dir.mkdir(parents=True, exist_ok=True)
    for name, content in bundles.items():
        (output_dir / name).write_text(content, encoding="utf-8", newline="\n")
        print(f"generated: {output_dir / name}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--source-dir", type=Path, default=root / "sql" / "source")
    parser.add_argument("--output-dir", type=Path, default=root / "sql")
    args = parser.parse_args(argv)
    build(args.source_dir, args.output_dir)


if __name__ == "__main__":
    main()
