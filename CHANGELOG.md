## [0.5.1] - 2023-08-16

- **BUGFIX:** Starting with version 7.0.5, the behavior of ActiveRecord's `pluck` changed: when you pluck multiple values with the same aggregate function (e.g., `sum`), in PostgreSQL, the data type of the last such value is now applied to all such values, though they used to be inferred correctly. Our solution is to add an explicit alias to each result column.

## [0.5.0] - 2023-05-14

- **FEATURE:** Your `summarize` blocks won't need to accept the proc second argument as often, because `ChainableResult` methods will also resolve their arguments. E.g., `query.summarize {|q| @mult = q.sum(:a) * q.sum(:b) }` now works, where previously you would have needed to write `query.summarize {|q,with| @mult = with[q.sum(:a),q.sum(:b)] {|a,b| a * b } }`.

- **IMPROVEMENT:** The conventional name of the proc provided as an optional second argument to `summarize` blocks is now `with_resolved` instead of `with`. Interactively teaching `activerecord-summarize` to some people showed that this was an improvement in clarity. The local name of the proc has always been under your control (it's your block!), so this doesn't affect anything besides documentation and tests, but if for some reason you accessed the proc at its internal name of `ChainableResult::WITH`, that will still work, too, even though we now refer to it as `ChainableResult::WITH_RESOLVED`.

## [0.4.0] - 2023-02-27

- **FEATURE:** Support for top-level .group(:belongs_to_association), returning hash with models as keys.

  I didn't realize this until a few months ago, but in ActiveRecord, if `Foo belongs_to :bar`, you can do `Foo.group(:bar).count` and get back a hash with `Bar` records as keys and counts as values. (ActiveRecord executes two total queries to implement this, one for the counts grouped by the `bar_id` foreign key, then another to retrieve the `Bar` models.)

  Now the same behavior works with `summarize`: you can still retrieve any number of counts and/or sums about `Foo`—including some with additional filters and even sub-grouping—in a single query, and then we'll execute one additional query to retrieve the records for the `Bar` model keys.

- **IMPROVEMENT:** `bin/console` is now much more useful for developing `activerecord-summarize`

- **IMPROVEMENT:** Added some tests for queries joining HABTM associations and (of course, supporting the new feature) `belongs_to` associations. `summarize` preceded by joins is already stable and documented, but it didn't have tests before. 

## [0.3.1] - 2022-06-23

- **BUGFIX:** `with` didn't work correctly with a single argument. Embarassingly, both the time-traveling version of `with` and the trivial/fake one provided when `noop: true` is set had single argument bugs, and they were different bugs.
- **IMPROVEMENT:** Automated tests covering every `with` invocation style I can think of for both implementations and a number of new tests to confirm that `noop: true` produces the same results as (default) `noop: false`.
- **IMPROVEMENT:** After the initial release I forgot I had a CHANGELOG, and now I've back-filled it.

## [0.3.0] - 2022-06-04

- **BUGFIX:** `.sum(:foo)` of no rows or of all-null values now returns 0 instead of failing (completing partial fix from 0.2.3)
- **BREAKING:** extremely unlikely to actually break anything, but `.count("distinct id")` now raises as `.distinct.count(:id)` already did. (AFAICT, by the nature of the techniques underlying `summarize`, `distinct` counts cannot be supported.)
- **IMPROVEMENT:** Automated tests covering basic functions and past problem areas.

## [0.2.3] - 2022-05-01

- **BUGFIX:** Fix results for SQL `SUM(null)` (n.b., this turned out to be only a partial fix)
- **BUGFIX:** Support summarize with only one query (not often very useful, but it should work!)

## [0.2.2] - 2022-04-29

- **BUGFIX:** Incorrect Arel generation when using `.where(*anything).sum` inside a `summarize` block

## [0.2.1] - 2022-02-17

- Initial public release
- Wrap existing groups of related `ActiveRecord` calculations in a `summarize` block for an instant 2-5x speedup
  - Supports combining all `.count` and `.sum` called on [descendants of] the summarizing relation in a `summarize` block
  - Supports separate `.where`, `.group`, and custom scopes for any or all calculations in a `summarize` block
  - Calculation methods return placeholder objects that will be replaced with the true calculation result at the end of the block.
  - Supports chaining almost any method on the placeholder calculation results
    - Some methods of `Object` that I haven't tried yet or that are injected into `Object` by other gems may not work, as they won't trigger `method_missing`.
  - Transparently replaces calculation placeholders that have been saved to local variables in the block's scope or instance variables of the block's execution context
  - Supports `pure: true` option to skip the step of looking outside the block return value for placeholders
  - Supports `noop: true` option to disable all `summarize` functionality and just return the original relation
    - `noop: true` and `noop: false` (default) produce the same final results, just `noop: false` is usually faster
- Build even more complex queries by using `summarize` on a relation that already has `.group` applied.
  - Results are grouped just like a standard `.group(*expressions).count`, but instead of single numbers, the values are whatever set of calculations you return from the block, including further `.group(*more).calculate(:sum|:count,*args)` calculations, in whatever `Array` or `Hash` shape you arrange them.
  - N.b., `pure: true` is implied and required in this mode, and `noop: true` is not possible, since ActiveRecord has no way to do this in the general case without `summarize`.