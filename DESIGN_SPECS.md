# SQL::Wizard — Design Specification

## Project Context

**Goal:** Build a comprehensive SQL query builder for Perl that fills the gap left by SQL::Abstract and SQL::Abstract::More. Neither supports UNION, CASE expressions, CTEs, window functions, or composable expression trees. The closest equivalents in other languages are Ruby's Sequel and Python's SQLAlchemy Core — nothing comparable exists on CPAN.

**Approach:** Build on top of (or as a successor to) SQL::Abstract::More by Laurent Dami. Maintain backward-compatible WHERE clause syntax (hashref/arrayref conditions) while adding a full composable expression system.

**Key Insight:** SQL is a tree of expressions. If the API treats everything — columns, conditions, subqueries, literals, CASE, function calls — as composable expression objects, it can handle any SQL construct.

---

## Core Design Principles

1. **Everything is an expression object.** A SELECT is an expression. A CASE is an expression. A function call is an expression. Anything can nest inside anything else.

2. **`->to_sql` is the only method that produces SQL.** Everything else builds the tree. This enables composition, modification, and cloning before rendering.

3. **Bind parameters by default, raw SQL opt-in.** `$q->val()` and hashref values produce `?` placeholders. Only `$q->raw()` injects literal SQL.

4. **SQL::Abstract-compatible WHERE syntax.** No reason to reinvent the hashref/arrayref condition format Perl developers already know.

5. **`table|alias` shorthand.** Avoids verbose `-as` everywhere for the common case.

6. **`$q->raw(...)` as escape hatch.** No API can anticipate every database-specific extension. Raw SQL must compose cleanly within the expression tree without breaking bind parameter handling.

---

## API Reference

### Constructor

```perl
my $q = SQL::Wizard->new(
    # Optional: database dialect for platform-specific SQL
    dialect => 'postgresql',  # or 'mysql', 'sqlite', 'oracle', etc.
);
```

---

### SELECT

```perl
my ($sql, @bind) = $q->select(
    -columns => [
        'u.id',
        'u.name',
        $q->case(
            [$q->when({status => 'active'}, 'Active')],
            [$q->when({status => 'banned'}, 'Banned')],
            $q->else('Unknown'),
        )->as('status_label'),
        $q->func(COUNT => '*')->as('total'),
        $q->func(COALESCE => 'u.nickname', $q->val('Anonymous'))->as('display_name'),
    ],
    -from => [
        'users|u',
        $q->join('orders|o', 'u.id = o.user_id'),
        $q->left_join('payments|p', 'o.id = p.order_id'),
        $q->join(
            $q->select(
                -columns => ['user_id', $q->func(MAX => 'login_date')->as('last_login')],
                -from    => 'logins',
                -group_by => 'user_id',
            )->as('ll'),
            'u.id = ll.user_id',
        ),
    ],
    -where => [
        -and => [
            { 'u.age' => { '>' => 18 } },
            { 'u.country' => { -in => ['FR', 'DE', 'IT'] } },
            -or => [
                { 'o.total' => { '>' => 100 } },
                $q->exists(
                    $q->select(
                        -columns => [1],
                        -from    => 'vip',
                        -where   => { 'vip.user_id' => $q->col('u.id') },
                    )
                ),
            ],
        ],
    ],
    -group_by => ['u.id', 'u.name'],
    -having   => { $q->func(COUNT => 'o.id') => { '>' => 5 } },
    -order_by => ['u.name', { -desc => 'total' }],
    -limit    => 50,
    -offset   => 10,
)->to_sql;
```

---

### UNION / INTERSECT / EXCEPT

Compound queries as methods that chain on select results:

```perl
my $active = $q->select(-columns => [qw/id name/], -from => 'active_users');
my $legacy = $q->select(-columns => [qw/id name/], -from => 'legacy_users');

my ($sql, @bind) = $active
    ->union($legacy)
    ->union_all(
        $q->select(-columns => [qw/id name/], -from => 'pending_users')
    )
    ->intersect(
        $q->select(-columns => [qw/id name/], -from => 'verified_users')
    )
    ->except(
        $q->select(-columns => [qw/id name/], -from => 'banned_users')
    )
    ->order_by('name')
    ->limit(100)
    ->to_sql;
```

**Generated SQL:**

```sql
(SELECT id, name FROM active_users)
UNION
(SELECT id, name FROM legacy_users)
UNION ALL
(SELECT id, name FROM pending_users)
INTERSECT
(SELECT id, name FROM verified_users)
EXCEPT
(SELECT id, name FROM banned_users)
ORDER BY name
LIMIT 100
```

---

### CTEs (WITH clauses)

```perl
my ($sql, @bind) = $q->with(
    recent_orders => $q->select(
        -columns => ['*'],
        -from    => 'orders',
        -where   => { created_at => { '>' => $q->raw("NOW() - INTERVAL '30 days'") } },
    ),
    big_spenders => $q->select(
        -columns  => ['user_id', $q->func(SUM => 'total')->as('spent')],
        -from     => 'recent_orders',    # references the CTE above
        -group_by => 'user_id',
        -having   => { $q->func(SUM => 'total') => { '>' => 1000 } },
    ),
)->select(
    -columns  => ['u.name', 'bs.spent'],
    -from     => ['users|u', $q->join('big_spenders|bs', 'u.id = bs.user_id')],
    -order_by => { -desc => 'bs.spent' },
)->to_sql;
```

**Generated SQL:**

```sql
WITH
  recent_orders AS (
    SELECT * FROM orders WHERE created_at > NOW() - INTERVAL '30 days'
  ),
  big_spenders AS (
    SELECT user_id, SUM(total) AS spent
    FROM recent_orders
    GROUP BY user_id
    HAVING SUM(total) > ?
  )
SELECT u.name, bs.spent
FROM users u
JOIN big_spenders bs ON u.id = bs.user_id
ORDER BY bs.spent DESC
```

### Recursive CTEs

```perl
my ($sql, @bind) = $q->with_recursive(
    org_tree => {
        -initial => $q->select(
            -columns => [qw/id name parent_id/, $q->val(1)->as('level')],
            -from    => 'employees',
            -where   => { parent_id => undef },    # IS NULL
        ),
        -recurse => $q->select(
            -columns => ['e.id', 'e.name', 'e.parent_id', $q->raw('t.level + 1')],
            -from    => ['employees|e', $q->join('org_tree|t', 'e.parent_id = t.id')],
        ),
    },
)->select(
    -columns => ['*'],
    -from    => 'org_tree',
    -order_by => 'level',
)->to_sql;
```

---

### CASE Expressions

```perl
# Simple CASE
my $status = $q->case(
    [$q->when({status => 'active'}, 'Active')],
    [$q->when({status => 'suspended'}, 'Suspended')],
    $q->else('Unknown'),
)->as('status_label');

# Searched CASE with complex conditions
my $tier = $q->case(
    [$q->when({ total => { '>'  => 10000 } }, 'Platinum')],
    [$q->when({ total => { '>'  => 5000  } }, 'Gold')],
    [$q->when({ total => { '>'  => 1000  } }, 'Silver')],
    $q->else('Bronze'),
)->as('tier');

# CASE on a specific expression
my $switch = $q->case_on(
    $q->col('u.role'),
    [$q->when($q->val('admin'), 'Full Access')],
    [$q->when($q->val('editor'), 'Edit Access')],
    $q->else('Read Only'),
)->as('access_level');

# Used in a column list
$q->select(
    -columns => ['u.name', $status, $tier],
    -from    => 'users|u',
);
```

---

### Window Functions

```perl
# ROW_NUMBER
$q->func(ROW_NUMBER => ())->over(
    -partition_by => 'department',
    -order_by     => { -desc => 'salary' },
)->as('rank')

# Running total
$q->func(SUM => 'amount')->over(
    -partition_by => 'account_id',
    -order_by     => 'transaction_date',
    -frame        => 'ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW',
)->as('running_total')

# LAG / LEAD
$q->func(LAG => 'salary', 1)->over(
    -partition_by => 'department',
    -order_by     => 'hire_date',
)->as('prev_salary')

# Named windows (reuse window definitions)
$q->select(
    -columns => [
        'name',
        'department',
        'salary',
        $q->func(RANK => ())->over('dept_window')->as('dept_rank'),
        $q->func(DENSE_RANK => ())->over('dept_window')->as('dept_dense_rank'),
    ],
    -from    => 'employees',
    -window  => {
        dept_window => {
            -partition_by => 'department',
            -order_by     => { -desc => 'salary' },
        },
    },
)
```

---

### JOIN Variants

```perl
# All join types
$q->join('orders|o', 'u.id = o.user_id')           # INNER JOIN
$q->left_join('payments|p', 'o.id = p.order_id')    # LEFT JOIN
$q->right_join('returns|r', 'o.id = r.order_id')    # RIGHT JOIN
$q->full_join('archive|a', 'u.id = a.user_id')      # FULL OUTER JOIN
$q->cross_join('multiplier')                         # CROSS JOIN

# Complex ON conditions (hashref)
$q->left_join('orders|o', {
    'u.id'     => $q->col('o.user_id'),
    'o.status' => 'completed',
    'o.year'   => { '>' => 2020 },
})

# Join on subquery
$q->join(
    $q->select(
        -columns  => ['user_id', $q->func(MAX => 'login_date')->as('last_login')],
        -from     => 'logins',
        -group_by => 'user_id',
    )->as('ll'),
    'u.id = ll.user_id',
)

# LATERAL join (PostgreSQL)
$q->lateral_join(
    $q->select(
        -columns => ['*'],
        -from    => 'orders',
        -where   => { user_id => $q->col('u.id') },
        -order_by => { -desc => 'created_at' },
        -limit    => 3,
    )->as('recent_orders'),
    $q->raw('true'),    # ON true
)
```

---

### INSERT

```perl
# Simple insert
$q->insert(
    -into   => 'users',
    -values => { name => 'Alice', email => 'alice@example.com', status => 'active' },
)->to_sql;

# Multi-row insert
$q->insert(
    -into    => 'users',
    -columns => [qw/name email/],
    -values  => [
        ['Alice', 'alice@example.com'],
        ['Bob', 'bob@example.com'],
    ],
)->to_sql;

# Insert from SELECT
$q->insert(
    -into    => 'archive_users',
    -columns => [qw/id name/],
    -select  => $q->select(
        -columns => [qw/id name/],
        -from    => 'users',
        -where   => { status => 'deleted' },
    ),
)->to_sql;

# Upsert (PostgreSQL ON CONFLICT)
$q->insert(
    -into    => 'counters',
    -values  => { key => 'hits', value => 1 },
    -on_conflict => {
        -target => 'key',
        -update => { value => $q->raw('counters.value + EXCLUDED.value') },
    },
)->to_sql;

# Upsert (MySQL ON DUPLICATE KEY)
$q->insert(
    -into    => 'counters',
    -values  => { key => 'hits', value => 1 },
    -on_duplicate => {
        value => $q->raw('value + VALUES(value)'),
    },
)->to_sql;

# INSERT ... RETURNING (PostgreSQL)
$q->insert(
    -into      => 'users',
    -values    => { name => 'Alice' },
    -returning => ['id', 'created_at'],
)->to_sql;
```

---

### UPDATE

```perl
# Simple update
$q->update(
    -table => 'users',
    -set   => { status => 'inactive', updated_at => $q->raw('NOW()') },
    -where => { last_login => { '<' => '2023-01-01' } },
)->to_sql;

# Update with join (MySQL style)
$q->update(
    -table => ['users|u', $q->join('orders|o', 'u.id = o.user_id')],
    -set   => { 'u.last_order' => $q->col('o.created_at') },
    -where => { 'o.status' => 'completed' },
)->to_sql;

# Update from subquery (PostgreSQL style)
$q->update(
    -table => 'users',
    -set   => { score => $q->col('s.new_score') },
    -from  => [
        $q->select(
            -columns  => ['user_id', $q->func(AVG => 'points')->as('new_score')],
            -from     => 'scores',
            -group_by => 'user_id',
        )->as('s'),
    ],
    -where => { 'users.id' => $q->col('s.user_id') },
)->to_sql;

# UPDATE ... RETURNING
$q->update(
    -table     => 'users',
    -set       => { status => 'active' },
    -where     => { id => 42 },
    -returning => ['id', 'status'],
)->to_sql;
```

---

### DELETE

```perl
# Simple delete
$q->delete(
    -from  => 'users',
    -where => { status => 'deleted', last_login => { '<' => '2020-01-01' } },
)->to_sql;

# Delete with subquery
$q->delete(
    -from  => 'users',
    -where => {
        id => { -not_in => $q->select(
            -columns => ['user_id'],
            -from    => 'active_sessions',
        )},
    },
)->to_sql;

# Delete with USING (PostgreSQL)
$q->delete(
    -from  => 'orders',
    -using => 'users',
    -where => {
        'orders.user_id' => $q->col('users.id'),
        'users.status'   => 'banned',
    },
)->to_sql;

# DELETE ... RETURNING
$q->delete(
    -from      => 'users',
    -where     => { status => 'deleted' },
    -returning => ['id', 'email'],
)->to_sql;
```

---

### Expression Primitives

These are the building blocks that make everything composable:

```perl
$q->col('u.name')                  # Column reference (avoids ambiguity with string values)
$q->val('literal string')          # Bound parameter value (always produces ?)
$q->raw('NOW() + INTERVAL 1 DAY') # Raw SQL escape hatch (use sparingly)
$q->func(NAME => @args)            # SQL function call: NAME(arg1, arg2, ...)
$q->case(...)                      # CASE expression (see above)
$q->case_on($expr, ...)            # CASE expr WHEN ... (see above)
$q->exists($subselect)             # EXISTS(subquery)
$q->not_exists($subselect)         # NOT EXISTS(subquery)
$q->any($subselect)                # ANY(subquery)
$q->all($subselect)                # ALL(subquery)
$q->between($col, $lo, $hi)        # col BETWEEN ? AND ?
$q->not_between($col, $lo, $hi)    # col NOT BETWEEN ? AND ?
$q->cast($expr, 'INTEGER')         # CAST(expr AS type)
$q->coalesce(@exprs)               # Shorthand for $q->func(COALESCE => @exprs)
$q->greatest(@exprs)               # GREATEST(a, b, ...)
$q->least(@exprs)                  # LEAST(a, b, ...)

# Boolean operators for composing conditions
$q->and(\%cond1, \%cond2)          # cond1 AND cond2
$q->or(\%cond1, \%cond2)           # cond1 OR cond2
$q->not(\%cond)                    # NOT(cond)

# Every expression supports:
->as('alias')                      # Aliasing: expr AS alias
->asc                              # ORDER BY expr ASC
->desc                             # ORDER BY expr DESC
->asc_nulls_first                  # ORDER BY expr ASC NULLS FIRST
->desc_nulls_last                  # ORDER BY expr DESC NULLS LAST
```

---

### Arithmetic & Comparison Expressions

```perl
# Arithmetic on expressions
$q->col('price') * $q->col('quantity')             # price * quantity
$q->func(SUM => 'amount') / $q->func(COUNT => '*') # SUM(amount) / COUNT(*)

# Could use operator overloading on expression objects:
my $total = $q->col('price') * $q->col('qty');
my $tax   = $total * $q->val(0.2);
my $final = $total + $tax;

$q->select(
    -columns => [$total->as('subtotal'), $tax->as('tax'), $final->as('total')],
    -from    => 'line_items',
);
```

---

### Query Modification / Cloning

Queries should be immutable — modification methods return new objects:

```perl
my $base = $q->select(
    -columns => ['*'],
    -from    => 'users',
    -where   => { status => 'active' },
);

# Build on the base without modifying it
my $admins  = $base->add_where({ role => 'admin' });
my $sorted  = $admins->order_by('name');
my $page2   = $sorted->limit(20)->offset(20);
my $counted = $base->columns([$q->func(COUNT => '*')->as('total')]);

# Each is independent:
$base->to_sql;     # SELECT * FROM users WHERE status = ?
$admins->to_sql;   # SELECT * FROM users WHERE status = ? AND role = ?
$page2->to_sql;    # ... ORDER BY name LIMIT 20 OFFSET 20
$counted->to_sql;  # SELECT COUNT(*) AS total FROM users WHERE status = ?
```

---

### Subqueries in Various Positions

```perl
# Subquery as column
$q->select(
    -columns => [
        'u.name',
        $q->select(
            -columns => [$q->func(COUNT => '*')],
            -from    => 'orders',
            -where   => { user_id => $q->col('u.id') },
        )->as('order_count'),
    ],
    -from => 'users|u',
);

# Subquery in FROM
$q->select(
    -columns => ['sub.name', 'sub.total'],
    -from    => [
        $q->select(
            -columns  => ['name', $q->func(SUM => 'amount')->as('total')],
            -from     => 'transactions',
            -group_by => 'name',
        )->as('sub'),
    ],
    -where => { 'sub.total' => { '>' => 1000 } },
);

# Subquery in WHERE (various forms)
-where => { id    => { -in     => $q->select(...) } }
-where => { id    => { -not_in => $q->select(...) } }
-where => { price => { '>'     => $q->select(...) } }  # scalar subquery
-where => { $q->exists($q->select(...)) }
```

---

### Database Dialect Handling

```perl
# The dialect affects SQL generation:
my $pg    = SQL::Wizard->new(dialect => 'postgresql');
my $mysql = SQL::Wizard->new(dialect => 'mysql');

# LIMIT/OFFSET differences, quoting, type names, etc.
# are handled internally based on dialect.

# Example: identifier quoting
# PostgreSQL: "users"."name"
# MySQL:      `users`.`name`
# SQLite:     "users"."name"
# Oracle:     "USERS"."NAME"
```

---

## Internal Architecture Notes

### Expression AST

All API calls build a tree of expression nodes internally. Suggested node types:

```
Expr::Column      — column reference
Expr::Value       — bound parameter
Expr::Raw         — raw SQL literal
Expr::Func        — function call with args
Expr::Case        — CASE/WHEN/THEN/ELSE
Expr::Alias       — expr AS name
Expr::BinaryOp    — arithmetic/comparison operators
Expr::Select      — full SELECT statement (is itself an expression)
Expr::Join        — join specification
Expr::Window      — window specification (OVER ...)
Expr::Compound    — UNION/INTERSECT/EXCEPT wrapper
Expr::CTE         — WITH clause
Expr::Insert      — INSERT statement
Expr::Update      — UPDATE statement
Expr::Delete      — DELETE statement
Expr::Order       — order direction + nulls handling
```

### Rendering Pipeline

```
API calls → build AST → to_sql() → walk tree → dialect-specific renderer → ($sql, @bind)
```

Each dialect provides a renderer that knows how to emit SQL for each node type. The default renderer produces ANSI SQL.

### Bind Parameter Collection

Bind parameters are collected depth-first as the tree is walked during rendering. Every `Expr::Value` node contributes a `?` placeholder and appends its value to the bind list.

---

## Existing Perl Modules — Relationship

| Module | What it does | Gap |
|--------|-------------|-----|
| SQL::Abstract | Hash → WHERE clause + basic CRUD | No joins, no expressions, no compounds |
| SQL::Abstract::More | Adds joins, limit, -columns syntax | No UNION, CTE, CASE, window functions |
| SQL::Maker | Alternative hash → SQL | Similar limitations |
| DBIx::Class | Full ORM with ResultSet chaining | Tied to ORM; can't use standalone for raw SQL building |

**This module fills the gap between SQL::Abstract::More and writing raw SQL strings.**

---

## Testing Strategy

Every expression type should have tests verifying:

1. Correct SQL output (string comparison)
2. Correct bind parameter order and values
3. Composability (nesting inside other expressions)
4. Dialect-specific rendering where applicable
5. Immutability (modifications return new objects)

---

## Open Design Questions

1. **Subclass SQL::Abstract::More or standalone?** Subclassing gives backward compat but may constrain internal architecture. Wrapping (delegation) may be cleaner.

2. **Operator overloading?** `$q->col('a') + $q->col('b')` is elegant but can be surprising. Could be opt-in via `use SQL::Wizard ':overload'`.

3. **String vs expression ambiguity:** When is `'name'` a column name vs a literal string? Convention: bare strings in `-columns` and `-from` are columns; in `-values` and `-where` values they're literals. Use `$q->col()` and `$q->val()` to be explicit anywhere.

4. **Method chaining vs hashref args?** The API above mixes both (hashref args for `select()`, chaining for `union()`, `order_by()`). This seems natural but should be consistent.

5. **Named placeholders?** Support `$q->val('Alice', ':name')` for producing `:name` instead of `?` for databases/drivers that prefer named placeholders.
