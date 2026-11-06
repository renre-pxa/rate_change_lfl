# LFL Rate-Change Project

The deployable LFL calculation and run instructions are isolated in [`core/README.md`](core/README.md).

Project layout:

- `core/`: SQL logic for objects 01-08, bundle builder, Dremio runner, and core run documentation.
- `tests/`: local SQLite fixtures and mocked-runner tests.
- `docs/`: comparisons and explanatory material outside the core pipeline.
- `queries/`: optional read-only analysis queries, including the reconstructed layer summary.
- `full-refresh.log`, `outputs.log`: run logs; keep operational output outside `core/`.

To run or maintain the pipeline, open `core/README.md`. Comparison diagrams, tests and optional summaries are intentionally separate from the core logic folder.