# frozen_string_literal: true

require_relative "summarize/version"
require_relative "../chainable_result"

module ActiveRecord::Summarize
  class Unsummarizable < StandardError; end

  class Summarize
    attr_reader :current_result_row, :pure, :noop, :from_where
    alias_method :pure?, :pure
    alias_method :noop?, :noop

    # noop: true
    #   causes `summarize` simply to yield the original relation and a trivial,
    #   synchronous `with` proc. It is meant as a convenient way to test/prove
    #   the correctness of `summarize` and to compare performance of the single
    #   combined query vs the original individual queries.
    #   N.b., if `relation` already has a grouping applied, there is no direct
    #   ActiveRecord translation for what `summarize` does, so noop: true is
    #   impossible and raises an exception.
    # pure: true
    #   lets `summarize` know that you're not mutating state within the block,
    #   so it doesn't need to go spelunking in the block binding for
    #   ChainableResults. See `if !pure?` section below.
    #   N.b., if `relation` already has a grouping applied, pure: true is
    #   implied and pure: false throws an exception, as the impure behavior
    #   would be non-obvious and of doubtful value.
    def initialize(relation, pure: nil, noop: false)
      @relation = relation
      @noop = noop
      has_base_groups = relation.group_values.any?
      raise Unsummarizable, "`summarize` must be pure when called on a grouped relation" if pure == false && has_base_groups
      raise ArgumentError, "`summarize(noop: true)` is impossible on a grouped relation" if noop && has_base_groups
      @pure = has_base_groups || !!pure
      @calculations = []
    end

    def process(&block)
      # For noop, just yield the original relation and a transparent `with` proc.
      return yield(@relation, ->(*results, &block) { [*results].then(&block) }) if noop?
      # Within the block, the relation and its future clones intercept calls to
      # `count` and `sum`, registering them and returning a ChainableResult via
      # summarize.add_calculation.
      future_block_result = ChainableResult.wrap(yield(
        @relation.unscope(:group).tap do |r|
          r.instance_variable_set(:@summarize, self)
          class << r
            include InstanceMethods
          end
        end,
        ChainableResult::WITH
      ))
      ChainableResult.with_cache(!pure?) do
        # `resolve` builds the single query that answers all collected calculations,
        # executes it, and aggregates the results by the values of
        # `@relation.group_values``. In the common case of no `@relation.group_values`,
        # the result is just `{[]=>[*final_value_for_each_calculation]}`
        result = resolve.transform_values! do |row|
          # Each row (in the common case, only one) is used to resolve any
          # ChainableResults returned by the block. These may be a one-to-one mapping,
          # or the block return may have combined some results via `with` or chained
          # additional methods on results, etc..
          @current_result_row = row
          future_block_result.value
        end.then do |result|
          # Change ungrouped result from `{[]=>v}` to `v` and grouped-by-one-column
          # result from `{[k1]=>v1,[k2]=>v2,...}` to `{k1=>v1,k2=>v2,...}`.
          # (Those are both probably more common than multiple-column base grouping.)
          case @relation.group_values.size
          when 0 then result.values.first
          when 1 then result.transform_keys! { |k| k.first }
          else result
          end
        end
        if !pure?
          # Check block scope's local vars and block's self's instance vars for
          # any ChainableResult, and replace it with its resolved value.
          #
          # Also check the values of any of those vars that are Hashes, since IME
          # it's not rare to assign counts to hashes, and it is rare to have giant
          # hashes that would be particularly wasteful to traverse. Do not do the
          # same for Arrays, since IME pushing counts to arrays is rare, and large
          # arrays, e.g., of many eagerly-fetched ActiveRecord objects, are not
          # rare in controllers.
          #
          # Preconditions:
          # - @current_result_row is still set to the single result row
          # - we are within a ChainableResult.with_cache(true) block
          block_binding = block.binding
          block_self = block_binding.receiver
          block_binding.local_variables.each do |k|
            v = block_binding.local_variable_get(k)
            next block_binding.local_variable_set(k, v.value) if v.is_a?(ChainableResult)
            lightly_touch_impure_hash(v) if v.is_a?(Hash)
          end
          block_self.instance_variables.each do |k|
            v = block_self.instance_variable_get(k)
            next block_self.instance_variable_set(k, v.value) if v.is_a?(ChainableResult)
            lightly_touch_impure_hash(v) if v.is_a?(Hash)
          end
        end
        @current_result_row = nil
        result
      end
    end

    def add_calculation(relation, operation, column_name)
      merge_from_where!(relation)
      calculation = CalculationResult.new(relation, operation, column_name)
      index = @calculations.size
      @calculations << calculation
      ChainableResult.wrap(calculation) { current_result_row[index] }
    end

    def resolve
      # Build & execute query
      groups = all_groups
      # MariaDB, SQLite, and Postgres all support `GROUP BY 1, 2, 3`-style syntax,
      # where the numbers are 1-indexed references to SELECT values. It makes these
      # generated queries much shorter and more readable, and it avoids the
      # ambiguity of using aliases (for GROUP BY, they can get clobbered by columns
      # from underlying tables) even where those are supported. But in case we find
      # a database that doesn't support numeric references, the fully-explicit
      # grouping code is commented out below.
      #
      # grouped_query = groups.any? ? from_where.group(*groups) : from_where
      grouped_query = groups.any? ? from_where.group(*1..groups.size) : from_where
      data = grouped_query.pluck(*groups, *value_selects)

      # Aggregate & assign results
      group_idx = groups.each_with_index.to_h
      starting_values, reducers = @calculations.each_with_index.map do |f, i|
        value_column = groups.size + i
        group_columns = f.relation.group_values.map { |k| group_idx[k] }
        case group_columns.size
        when 0 then [
          0,
          ->(memo, row) { memo + row[value_column] }
        ]
        when 1 then [
          Hash.new(0), # Default 0 makes the reducer much cleaner, but we have to clean it up later
          ->(memo, row) {
            memo[row[group_columns[0]]] += row[value_column] unless row[value_column].zero?
            memo
          }
        ]
        else [
          Hash.new(0),
          ->(memo, row) {
            memo[group_columns.map { |i| row[i] }] += row[value_column] unless row[value_column].zero?
            memo
          }
        ]
        end
      end.transpose # For an array of pairs, `transpose` is the reverse of `zip`
      cols = (0...reducers.size)
      base_group_columns = (0...base_groups.size)
      data
        .group_by { |row| row[base_group_columns] }
        .tap { |h| h[[]] = [] if h.empty? && base_groups.size.zero? }
        .transform_values! do |rows|
          values = starting_values.map(&:dup) # map(&:dup) since some are hashes and we don't want to mutate starting_values
          rows.each do |row|
            cols.each do |i|
              values[i] = reducers[i].call(values[i], row)
            end
          end
          # Set any hash's default back to nil, since callers will expect a normal hash
          values.each { |v| v.default = nil if v.is_a? Hash }
        end
    end

    private

    def compatible_base
      @compatible_base ||= @relation.except(:select, :group)
    end

    def merge_from_where!(other)
      other_from_where = other.except(:select, :group)
      incompatible_values = compatible_base.send(:structurally_incompatible_values_for, other_from_where)
      unless incompatible_values.empty?
        raise Unsummarizable, "Within a `summarize` block, each calculation must be structurally compatible. Incompatible values: #{incompatible_values}"
      end
      # Logical OR the criteria of all calculations. Most often this is equivalent
      # to `compatible_base`, since usually one is a total or grouped count without
      # additional `where` criteria, but that needn't necessarily be so.
      @from_where = if @from_where.nil?
        other_from_where
      else
        @from_where.or(other_from_where)
      end
    end

    def base_groups
      @relation.group_values.dup
    end

    def all_groups
      # keep all base groups, even if they did something silly like group by
      # the same key twice, but otherwise don't repeat any groups
      groups = base_groups
      groups_set = Set.new(groups)
      @calculations.map { |f| f.relation.group_values }.flatten.each do |k|
        next if groups_set.include? k
        groups_set << k
        groups << k
      end
      groups
    end

    def value_selects
      @calculations.map { |f| f.select_value(@relation) }
    end

    def lightly_touch_impure_hash(h)
      h.each do |k, v|
        h[k] = v.value if v.is_a? ChainableResult
      end
    end
  end

  class CalculationResult
    attr_reader :relation, :method, :column

    def initialize(relation, method, column)
      @relation = relation
      @method = method
      @column = column
    end

    def select_value(base_relation)
      where = relation.where_clause - base_relation.where_clause
      for_select = column
      for_select = Arel::Nodes::Case.new(where.ast, unmatch_value).when(true, for_select) unless where.empty?
      function.new([for_select]).tap { |f| f.distinct = relation.distinct_value }
    end

    def unmatch_value
      case method
      when "sum" then 0
      when "count" then nil
      else raise "Unknown calculation method"
      end
    end

    def function
      case method
      when "sum" then Arel::Nodes::Sum
      when "count" then Arel::Nodes::Count
      else raise "Unknown calculation method"
      end
    end
  end

  module RelationMethods
    def summarize(**opts, &block)
      raise Unsummarizable, "Cannot summarize within a summarize block" if @summarize
      ActiveRecord::Summarize::Summarize.new(self, **opts).process(&block)
    end
  end

  module InstanceMethods
    private

    def perform_calculation(operation, column_name)
      case operation = operation.to_s.downcase
      when "count", "sum"
        column_name = :id if [nil, "*", :all].include? column_name
        @summarize.add_calculation(self, operation, aggregate_column(column_name))
      else super
      end
    end
  end
end

class ActiveRecord::Base
  class << self
    def summarize(**opts, &block)
      ActiveRecord::Summarize::Summarize.new(all, **opts).process(&block)
    end
  end
end

class ActiveRecord::Relation
  include ActiveRecord::Summarize::RelationMethods
end
