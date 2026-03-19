# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test

```bash
perl Makefile.PL && make        # build
make test                        # run all tests
prove -v t/03_where.t            # run a single test file with verbose output
prove -v t/                      # run all tests with verbose output
```

Requires Perl 5.10+. Zero non-core runtime dependencies; only `Test::More` for tests.

## What This Project Is

SQL::Wizard is a composable SQL query builder for Perl that fills the gap between SQL::Abstract::More and writing raw SQL. It provides expression trees, immutable queries, and zero non-core dependencies. The key insight: SQL is a tree of expressions — if the API treats everything (columns, conditions, subqueries, CASE, function calls) as composable expression objects, it can handle any SQL construct.

The design spec is at `/home/thomas/work/SQL_Wizard_Design_Spec.md` — consult it for the intended API, open design questions, and features not yet implemented (e.g., `lateral_join`, `any`/`all`, named placeholders, dialect-specific identifier quoting).

## Architecture

**Data flow:** `SQL::Wizard->method(...)` → creates `Expr::*` node → `->to_sql()` → `Renderer->render($node)` → dispatches to `_render_*` → returns `($sql, @bind)`.

Three layers:

1. **`SQL::Wizard`** (`lib/SQL/Wizard.pm`) — Entry-point factory. Creates all expression nodes and query builders. Every node gets a `_renderer` ref injected at construction. Plain strings are coerced to `Column` nodes in `func()` args and to `Value` nodes in `insert`/`update` values.

2. **`SQL::Wizard::Expr`** (`lib/SQL/Wizard/Expr.pm`) — Base class for all nodes. Provides `to_sql` (delegates to renderer), chainable methods (`as`, `asc`, `desc`, `over`), and operator overloading for arithmetic (`+`, `-`, `*`, `/`, `%`). Plain Perl numbers auto-coerce to `Value` nodes via `_coerce`.

3. **`SQL::Wizard::Renderer`** (`lib/SQL/Wizard/Renderer.pm`) — Single-class visitor (~800 lines) with a `%dispatch` table mapping node class → render method. Also implements `_render_where` providing the SQL::Abstract-compatible hashref/arrayref WHERE syntax. This is where all SQL generation lives.

**Expression nodes** (`lib/SQL/Wizard/Expr/*.pm`) are thin data holders. `Select` and `Compound` are notable: they have immutable modifier methods (`add_where`, `columns`, `order_by`, `limit`, `offset`, `union`, etc.) that `Storable::dclone` to return new objects.

**CTE flow:** `SQL::Wizard->with(...)` returns a `CTE` node. Calling `->select(...)` on it creates a `Select` node with `_cte` set, so the renderer prepends the WITH clause.

## Test Organization

Tests in `t/` are numbered by feature: `01_expr` (primitives), `02_select`, `03_where`, `04_join`, `05_case`, `06_compound` (UNION etc.), `07_cte`, `08_window`, `09_insert`, `10_update`, `11_delete`, `12_subquery`, `13_arithmetic`, `14_clone` (immutability). All use `Test::More` and assert `($sql, @bind)` output.

## Design Conventions

- All query parameters use `-key` prefix (e.g., `-columns`, `-from`, `-where`).
- Plain strings = column references in most contexts; use `$q->val(...)` for bound values, `$q->raw(...)` for literal SQL.
- `table|alias` string syntax expands to `table alias` in SQL output.
- WHERE accepts hashrefs (AND), arrayrefs (explicit AND/OR nesting), or expression objects — matching SQL::Abstract conventions.
- Bind parameters are collected depth-first during tree traversal; every `Value` node contributes `?` + its value.
