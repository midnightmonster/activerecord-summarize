# ActiveRecord::Summarize

## Why `summarize`?

1. Make existing groups of related `ActiveRecord` calculations twice as fast (or more) with minimal code alteration. It's like a `go_faster` block.
2. For more complex grouped reporting requirements, use `summarize` for legible, performant code that you couldn't have been done before without unacceptable performance or lengthy custom SQL and data-wrangling.

## Installation

Add this line to your Rails application's Gemfile:

```ruby
gem 'activerecord-summarize'
```

And then execute:

    $ bundle install

## Usage

```ruby
# Suppose a controller method looks like this:
purchases = Purchase.complete
promotions = purchases.where.not(promotion_id: nil)
@promotion_sales = promotions.count
@promotion_revenue = promotions.sum(:amount)
@by_region = purchases.group(:region_id).count

# Make it this instead:
Purchase.complete.summarize do |purchases|
  promotions = purchases.where.not(promotion_id: nil)
  @promotion_sales = promotions.count
  @promotion_revenue = promotions.sum(:amount)
  @by_region = purchases.group(:region_id).count
end
# ...and you'll have exactly the same instance variables set,
# but only one SQL query will have been executed.
```

You can run as many calculations in a `summarize` block as it makes sense to run, so long as they all chain on the relation on which you called `summarize`. They can be on different, possibly-overlapping subsets of the original relation, i.e., they can have their own `where` clauses and even `group`. The final result of each will be exactly as it would have been if you had run each query independently, but only one query will actually be issued to the database.

The only restriction is that each of the queries must be structurally compatible with the parent relation, in the same sense as is required for `relation.or(other)`. So if you wanted to display the region's name, you'd need to group by a sub-select (ew) or do the join at the top level:

```ruby
Purchase.complete.left_joins(:region).summarize do |purchases|
  promotions = purchases.where.not(promotion_id: nil)
  @promotion_sales = promotions.count
  @promotion_revenue = promotions.sum(:amount)
  @by_region = purchases.group("regions.name").count
end
```

Until the `summarize` block ends, the return value of your calculations are `ChainableResult::Future` instances, a bit like a Promise with a more convenient API. You can call any method you like on a `ChainableResult`, and you'll get back another `ChainableResult`, and they'll all turn out alright in the end—provided you called methods that would have worked if you had just run that calculation without `summarize`. OTOH, using a `ChainableResult` as an argument to another method generally will not work.

```ruby
Purchase.last_quarter.complete.summarize do |purchases|
  @sales = purchases.sum(:amount)
  # x * y is syntactic sugar for x.*(y), so this will work:
  @vc_projection = @sales * 3
  # And this won't:
  @vc_projection = 3 * @sales
end
```

If, within a `summarize` block, you want to combine data from more than one `ChainableResult`, you must use the otherwise-optional second argument yielded to the block, a `proc` I like to name `with`—and you must return the new result from the `with` block:

```ruby
Purchase.complete.left_joins(:promotion).summarize do |purchases, with|
  @all_revenue = purchases.sum(:amount)
  promotions = purchases.where.not(promotions: {id: nil})
  @promotion_sales = promotions.count
  @promotion_discounts = promotions.sum("promotions.discount_amount")
  @avg_discount = with[@promotion_sales, @promotion_discounts] do |sales, discounts|
    sales.zero? ? 0 : discounts / sales
  end
end
```

## Escape hatch

For few-query cases where each query is well-served by its own index, `summarize` could possibly be slower than the same queries executed without it. The design intention of `summarize` is that every operation is correct, and those that can't ever be correct or aren't yet will raise exceptions—but only humans have worked on this code, so you might also wonder if `summarize` is producing correct results. Fortunately, you can easily check both with `summarize(noop: true)`, which causes `summarize` to yield the relation it was called on and a trivial `with` proc.

## How

`ActiveRecord::Relation#summarize` yields a lightly-tweaked copy of the relation that intercepts all calls to `sum` or `count` which, instead of a number or hash, return a `ChainableResult::Future`. A `ChainableResult` accepts any method called on it, returning a new `ChainableResult` that will evaluate to the result of running the method on the eventual result of its parent.

At the end of the `summarize` block:

1. All the calculations are combined into a single query.
2. The results of the query are collected into the same shapes they would have if they had been called independently. E.g., a bare `.count` returns a number, but `.group(...).count` returns a hash.
3. Any `ChainableResult` in the return value of the block (usually a single `ChainableResult` or an `Array` or `Hash` with `ChainableResult` values) is replaced with its resolved value.
4. Any `ChainableResult` in the local scope of the block (i.e., `block.binding`) or an instance variable of the block context (i.e., `block.binding.receiver`) is replaced with its resolved value.

N.b., if you are using `summarize` in a more functional style and will return all values you care about, you can let `summarize` know to skip step 4 by invoking it with `summarize(pure: true)`.

When the parent relation already has `group` applied, `pure: true` is implied and step 4 does not take place.

## Power usage with `group`

When the relation already has `group` applied, for correct results, `summarize` requires that the block mutate no state and return all values you care about—functional purity, no side effects. `ChainableResult` values referenced by instance variables or local variables not returned from the block won't be evaluated. To see why:

```ruby
# A trivial example:
Purchase.complete.group(:region_id).summarize {|purchases| purchases.sum(:amount) }

# ...is exactly equivalent to:
Purchase.complete.group(:region_id).sum(:amount)

# But if there were three regions, what should the value of @target be in this case?
region_targets = Purchase.last_quarter.complete.group(:region_id).summarize do |purchases|
  @target = purchases.sum(:amount) * 1.2
end
```

As a rubyist, that last example looks like the block will be evaluated for each group, so `@target` should keep whatever value it got the last time the block was run. However:

1. This is not often useful.
2. The block is not actually linearly evaluated for each group.

Instead the block is evaluated once to determine what calculations need to be run, the query is built and evaluated, and then, for each group of the parent relation, the return value of the block is evaluated with respect to just those rows belonging to the group. In practice this is quite powerful and makes a pleasant, legible API for complex reporting. I think so, anyway. E.g.:

```ruby
puts Purchase.last_year.complete.group(:region_id).summarize do |purchases,with|
  total = purchases.count
  by_quarter = purchases.group(CREATED_TO_YEAR_SQL, CREATED_TO_QUARTER_SQL).count.sort.to_h
  target = with[total / 4, by_quarter.values.max] {|avg_q, best_q| [avg_q * 1.25, best_q].max.round }
  {last_year: total, quarters: by_quarter, unit_target: target}
end
# Output:
# {
#   1 => {
#     last_year: 2717316,
#     quarters: {
#       [2021, 1] => 634057,
#       [2021, 2] => 590012,
#       [2021, 3] => 659010,
#       [2021, 4] => 834237
#     },
#     unit_target: 849161
#   },
#   2 => { ... },
#   3 => { ... }
# }
```

The ActiveRecord API has no direct analog for this, so `noop: true` is not allowed when `summarize` is called on a grouped relation.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/midnightmonster/activerecord-summarize.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
