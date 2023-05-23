# frozen_string_literal: true

require_relative "summarize/version"
require_relative "summarize/calculation_implementation"
require_relative "../chainable_result"

module ActiveRecord::Summarize
  class Unsummarizable < StandardError; end

  class Summarize
    attr_reader :current_result_row, :base_groups, :base_association, :pure, :noop, :from_where
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
      @base_groups, @base_association = relation.group_values.dup.then do |group_fields|
        # Based upon a bit from ActiveRecord::Calculations.execute_grouped_calculation,
        # if the base relation is grouped only by a belongs_to association, group by
        # the association's foreign key.
        if group_fields.size == 1 && group_fields.first.respond_to?(:to_sym)
          association = relation.klass._reflect_on_association(group_fields.first)
          # Like ActiveRecord's group(:association).count behavior, this only works with belongs_to associations
          next [Array(association.foreign_key), association] if association&.belongs_to?
        end
        [group_fields, nil]
      end
      has_base_groups = base_groups.any?
      raise Unsummarizable, "`summarize` must be pure when called on a grouped relation" if pure == false && has_base_groups
      raise ArgumentError, "`summarize(noop: true)` is impossible on a grouped relation" if noop && has_base_groups
      @pure = has_base_groups || !!pure
      @calculations = []
    end

    def process(&block)
      # For noop, just yield the original relation and a transparent `with_resolved` proc.
      return yield(@relation, ChainableResult::SYNC_WITH_RESOLVED) if noop?
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
        ChainableResult::WITH_RESOLVED
      ))
      ChainableResult.with_cache(!pure?) do
        # `resolve` builds the single query that answers all collected calculations,
        # executes it, and aggregates the results by the values of `base_groups`.
        # In the common case of no `base_groups`, the resolve returns:
        # `{[]=>[*final_value_for_each_calculation]}`
        result = resolve.transform_values! do |row|
          # Each row (in the common case, only one) is used to resolve any
          # ChainableResults returned by the block. These may be a one-to-one mapping,
          # or the block return may have combined some results via `with`, chained
          # additional methods on results, etc..
          @current_result_row = row
          future_block_result.value
        end.then do |result|
          # Now unpack/fix-up the result keys to match shape of Relation.count or Relation.group(*cols).count return values
          if base_groups.empty?
            # Change ungrouped result from `{[]=>v}` to `v`, like Relation.count
            result.values.first
          elsif base_association
            # Change grouped-by-one-belongs_to-association result from `{[id1]=>v1,[id2]=>v2,...}` to
            # `{<AssociatedModel id:id1>=>v1,<AssociatedModel id:id2>=>v2,...}` like Relation.group(:association).count

            # Loosely based on a bit from ActiveRecord::Calculations.execute_grouped_calculation,
            # retrieve the records for the group association and replace the keys of our final result.
            key_class = base_association.klass.base_class
            key_records = key_class
              .where(key_class.primary_key => result.keys.flatten)
              .index_by(&:id)
            result.transform_keys! { |k| key_records[k[0]] }
          elsif base_groups.size == 1
            # Change grouped-by-one-column result from `{[k1]=>v1,[k2]=>v2,...}` to `{k1=>v1,k2=>v2,...}`, like Relation.group(:column).count
            result.transform_keys! { |k| k[0] }
          else
            # Multiple-column base grouping (though perhaps relatively rare) requires no change.
            result
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

    def add_calculation(operation, relation, column_name)
      merge_from_where!(relation)
      calculation = CalculationImplementation.new(operation, relation, column_name)
      index = @calculations.size
      @calculations << calculation
      ChainableResult.wrap(calculation) { current_result_row[index] }
    end

    def resolve
      #########################
      # Build & execute query #
      #########################
      groups = all_groups
      # MariaDB, SQLite, and Postgres all support `GROUP BY 1, 2, 3`-style syntax,
      # where the numbers are 1-indexed references to SELECT values.
      grouped_query = groups.any? ? from_where.group(*1..groups.size) : from_where
      data = grouped_query.pluck(*groups, *value_selects)

      # .pluck(:just_one_column) returns an array of values instead of an array
      # of arrays, which breaks the aggregation and assignment below.
      data = data.map { |d| [d] } if (groups.size + value_selects.size) == 1

      ##############################
      # Build aggregation reducers #
      ##############################
      # groups includes all base groups and all sub-groups
      group_idx = groups.each_with_index.to_h # Inverts the groups list: `[:foo, :bar]` becomes `{:foo => 0, :bar => 1}`
      starting_values, reducers = @calculations.each_with_index.map do |f, i|
        value_column = groups.size + i
        # each calculation shares any base groups that exist and may have sub-groups, which won't be shared by others
        group_columns = f.relation.group_values.map { |k| group_idx[k] }
        case group_columns.size
        when 0 then [
          f.initial,
          ->(memo, row) { f.reducer(memo, row[value_column]) }
        ]
        when 1 then [
          {},
          ->(memo, row) {
            key = row[group_columns[0]]
            prev_val = memo[key] || f.initial
            next_val = f.reducer(prev_val, row[value_column])
            memo[key] = next_val unless next_val == prev_val
            memo
          }
        ]
        else [
          {},
          ->(memo, row) {
            key = group_columns.map { |i| row[i] }
            prev_val = memo[key] || f.initial
            next_val = f.reducer(prev_val, row[value_column])
            memo[key] = next_val unless next_val == prev_val
            memo
          }
        ]
        end
      end.transpose # For an array of pairs, `transpose` is the reverse of `zip`
      cols = (0...reducers.size)
      base_group_columns = (0...base_groups.size)
      data
        .group_by { |row| row[base_group_columns] }
        .tap { |h| h[[]] = [] if h.empty? && base_groups.empty? }
        .transform_values! do |rows|
          values = starting_values.map(&:dup) # map(&:dup) since some are hashes and we don't want to mutate starting_values
          rows.each do |row|
            cols.each do |i|
              values[i] = reducers[i].call(values[i], row)
            end
          end
          values
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

    def all_groups
      # keep all base groups, even if they did something silly like group by
      # the same key twice, but otherwise don't repeat any groups
      groups = base_groups.dup
      groups_set = Set.new(groups)
      @calculations.map { |f| f.relation.group_values }.flatten.each do |k|
        next if groups_set.include? k
        groups_set << k
        groups << k
      end
      groups
    end

    def value_selects
      @calculations.map { |f| f.select_column_arel_node(@relation) }
    end

    def lightly_touch_impure_hash(h)
      h.each do |k, v|
        h[k] = v.value if v.is_a? ChainableResult
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
        column_name = :id if [nil, "*", :all].include? column_name # only applies to count
        raise Unsummarizable, "DISTINCT in SQL is not reliably correct with summarize" if column_name.is_a?(String) && /\bdistinct\b/i === column_name
        @summarize.add_calculation(operation, self, aggregate_column(column_name))
      when "average"
        ChainableResult::WITH_RESOLVED[
          perform_calculation("sum", column_name),
          perform_calculation("count", column_name)
        ] do |sum, count|
          if sum.is_a? Hash
            sum.to_h { |key, s| [key, s.to_d / count[key]] }
          else
            next nil if count == 0
            sum.to_d / count
          end
        end
      when "minimum", "maximum"
        @summarize.add_calculation(operation, self, aggregate_column(column_name))
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
