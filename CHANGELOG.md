## [0.2.0] - 2022-02-17

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