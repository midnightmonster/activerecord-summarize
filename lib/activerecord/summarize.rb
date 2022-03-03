# frozen_string_literal: true

require_relative "summarize/version"
require_relative "../chainable_result"

module ActiveRecord::Summarize
  class Error < StandardError; end
  class Unsummarizable < StandardError; end

  class Summarize
    attr_reader :current_result_row, :pure, :noop
    alias_method :pure?, :pure
    alias_method :noop?, :noop

    def initialize(relation, pure: nil, noop: false)
      @relation = relation
      @noop = noop
      has_base_groups = relation.group_values.any?
      raise Error.new("`summarize` must be pure when called on a grouped relation") if pure == false && has_base_groups
      @pure = has_base_groups || !!pure
      @aggregations = []
    end

    def process(&block)
      # noop: true is meant as a convenient way to test/prove the correctness of
      # `summarize` and to compare performance of `summarize` vs not using it.
      # For noop, just yield the relation and a transparent `with` proc.
      return yield(@relation, ->(*results,&block){ [*results].then(&block) }) if noop?
      # The proxy collects all calls to `count` and `sum`, registering them with
      # this object and returning a ChainableResult via summarize.add_aggregation.
      summarizing = @relation.unscope(:group).tap {|r| r.instance_variable_set(:@summarize,self) }
      future_block_result = ChainableResult.wrap(yield(summarizing,ChainableResult::WITH))
      ChainableResult.with_cache(!pure?) do
        # `resolve` builds the single query that answers all collected aggregations,
        # executes it, and aggregates the results by the values of
        # `@relation.group_values``. In the common case of no `@relation.group_values`,
        # the result is just `{[]=>[*final_value_for_each_aggregation]}`
        result = resolve().transform_values! do |row|
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
          when 1 then result.transform_keys! {|k| k.first }
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

    def add_aggregation(aggregation)
      index = @aggregations.size
      @aggregations << aggregation
      ChainableResult.wrap(aggregation) { current_result_row[index] }
    end

    # :where, :joins, and :left_outer_joins are the only use cases I've seen IRL
    BASE_QUERY_PARTS = [:where, :limit, :offset, :joins, :left_outer_joins, :from, :order, :optimizer_hints]
    AGGREGATE_FROM_WHERE_PARTS = [:where, :joins, :left_outer_joins, :from, :order]

    def resolve
      # Build & execute query
      base_from_where = @relation.only(*BASE_QUERY_PARTS)
      full_from_where = @aggregations.
        map {|f| f.relation.only(*AGGREGATE_FROM_WHERE_PARTS) }.
        inject(base_from_where) {|f, memo| memo.or(f) }
      # keep all base groups, even if they did something stupid like group by
      # the same key twice, but otherwise don't repeat any groups
      base_groups = @relation.group_values
      groups = base_groups.dup
      groups_set = Set.new(groups)
      @aggregations.map {|f| f.relation.group_values }.flatten.each do |k|
        next if groups_set.include? k
        groups_set << k
        groups << k
      end
      group_idx = groups.each_with_index.to_h
      grouped_query = groups.any? ? full_from_where.group(*groups) : full_from_where
      value_selects = @aggregations.map {|f| f.select_value(@relation) }
      data = grouped_query.pluck(*groups,*value_selects)
      # puts [groups, data].inspect # debug
      
      # Aggregate & assign results
      starting_values, reducers = @aggregations.each_with_index.map do |f,i|
        value_column = groups.size + i
        group_columns = f.relation.group_values.map {|k| group_idx[k] }
        case group_columns.size
        when 0 then [0,->(memo,row){ memo+row[value_column] }]
        when 1 then [Hash.new(0),->(memo,row){ memo[row[group_columns[0]]] += row[value_column] unless row[value_column].zero?; memo }]
        else [Hash.new(0),->(memo,row){ memo[group_columns.map {|i| row[i] }] += row[value_column] unless row[value_column].zero?; memo }]
        end
      end.transpose # For an array of pairs, `transpose` is the reverse of `zip`
      cols = (0...reducers.size)
      base_group_columns = (0...base_groups.size)
      data.
        group_by {|row| row[base_group_columns] }.
        tap {|h| h[[]] = [] if h.empty? && base_groups.size.zero? }.
        # tap {|d| puts d.inspect }. # The rows 
        transform_values! do |rows|
          values = starting_values.map &:dup # Some are hashes, so need to start fresh with them
          rows.each do |row|
            cols.each do |i|
              values[i] = reducers[i].call(values[i],row)
            end
          end
          values
        end
    end

    private
    def lightly_touch_impure_hash(h)
      h.each do |k,v|
        h[k] = v.value if v.is_a? ChainableResult
      end
    end
  end

  class AggregateResult
    attr_reader :relation, :method, :column

    def initialize(relation,method,column)
      @relation = relation
      @method = method
      @column = column
    end

    def select_value(base_relation)
      where = relation.where_clause - base_relation.where_clause
      for_select = column
      for_select = Arel::Nodes::Case.new(where.ast,unmatch_value).when(true,for_select) unless where.empty?
      function.new([for_select]).tap {|f| f.distinct = relation.distinct_value }
    end
    
    def unmatch_value
      case method
      when :sum then 0
      when :count then nil
      else raise "Unknown aggregate method"
      end
    end

    def function
      case method
      when :sum then Arel::Nodes::Sum
      when :count then Arel::Nodes::Count
      else raise "Unknown aggregate method"
      end
    end
  end

  module Methods
    def summarize(**opts, &block)
      raise Unsummarizable.new("Cannot summarize within a summarize block") if @summarize
      ActiveRecord::Summarize::Summarize.new(self,**opts).process(&block)
    end

    def count(column_name=:id)
      return super unless @summarize
      column_name = :id if ['*',:all].include? column_name
      @summarize.add_aggregation(AggregateResult.new(self,:count,aggregate_column(column_name)))
    end

    def sum(column_name=nil)
      return super unless @summarize
      @summarize.add_aggregation(AggregateResult.new(self,:sum,aggregate_column(column_name)))
    end
  end

end

class ActiveRecord::Base
  class << self
    def summarize(**opts, &block)
      ActiveRecord::Summarize::Summarize.new(self.all,**opts).process(&block)
    end
  end
end


class ActiveRecord::Relation
  include ActiveRecord::Summarize::Methods
end