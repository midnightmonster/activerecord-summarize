# frozen_string_literal: true

require_relative "summarize/version"
require_relative "../chainable_result"

module ActiveRecord::Summarize
  class Error < StandardError; end
  class Unproxyable < StandardError; end

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
      return yield(@relation, SummarizingProxy.noop_with) if noop?
      # The proxy collects all calls to `count` and `sum`, registering them with
      # this object and returning a ChainableResult via summarize.add_aggregation.
      proxy = SummarizingProxy.new(self, @relation.unscope(:group))
      future_block_result = ChainableResult.wrap(yield(proxy,ChainableResult::WITH))
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
      base_groups = @relation.group_values
      groups = @aggregations.inject(Set.new(base_groups)) {|g,f| g.merge(f.relation.group_values) }.to_a
      grouped_query = groups.any? ? full_from_where.group(*groups) : full_from_where
      value_selects = @aggregations.map {|f| f.select_value(@relation) }
      data = grouped_query.pluck(*groups,*value_selects)
      # puts [groups, data].inspect # debug
      
      # Aggregate & assign results
      group_idx = groups.each_with_index.to_h
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

  class SummarizingProxy < ActiveRecord::Relation
    def initialize(summarize,relation)
      @summarize = summarize
      @relation = relation
    end

    def summarize
      raise Unproxyable.new("Cannot summarize within a summarize block")
    end

    def self.noop_with
      ->(*results,&block){ [*results].then(&block) }
    end

    def count(column_name=:id)
      column_name = :id if ['*',:all].include? column_name
      @summarize.add_aggregation(AggregateResult.new(@relation,:count,aggregate_column(column_name)))
    end

    def sum(column_name=nil)
      @summarize.add_aggregation(AggregateResult.new(@relation,:sum,aggregate_column(column_name)))
    end

    def where(*args); self.class.new(@summarize, @relation.where(*args)); end
    def not(*args); self.class.new(@summarize, @relation.not(*args)); end
    def missing(*args); self.class.new(@summarize, @relation.missing(*args)); end
    def group(*args); self.class.new(@summarize, @relation.group(*args)); end
    def distinct(*args); self.class.new(@summarize, @relation.distinct(*args)); end

    # TODO: Figure out how to overcome, detect, and/or warn about joins changing counts
    def joins(*args); self.class.new(@summarize, @relation.joins(*args)); end
    def left_outer_joins(*args); self.class.new(@summarize, @relation.left_joins(*args)); end
    alias :left_joins :left_outer_joins

    def includes(*args); raise Unproxyable.new("`includes` is not meaningful inside `summarize` block"); end
    def eager_load(*args); raise Unproxyable.new("`eager_load` is not meaningful inside `summarize` block"); end
    def preload(*args); raise Unproxyable.new("`preload` is not meaningful inside `summarize` block"); end
    def extract_associated(*args); raise Unproxyable.new("`extract_associated` is not meaningful inside `summarize` block"); end
    def references(*args); raise Unproxyable.new("`references` is not meaningful inside `summarize` block"); end
    def select(*args); raise Unproxyable.new("`select` is not meaningful inside `summarize` block"); end
    def reselect(*args); raise Unproxyable.new("`reselect` is not meaningful inside `summarize` block"); end
    def order(*args); raise Unproxyable.new("`order` is not meaningful inside `summarize` block"); end
    def reorder(*args); raise Unproxyable.new("`reorder` is not meaningful inside `summarize` block"); end
    def limit(*args); raise Unproxyable.new("`limit` is not meaningful inside `summarize` block"); end
    def offset(*args); raise Unproxyable.new("`offset` is not meaningful inside `summarize` block"); end
    def readonly(*args); raise Unproxyable.new("`readonly` is not meaningful inside `summarize` block"); end
    def strict_loading(*args); raise Unproxyable.new("`strict_loading` is not meaningful inside `summarize` block"); end
    def create_with(*args); raise Unproxyable.new("`create_with` is not meaningful inside `summarize` block"); end
    def reverse_order(*args); raise Unproxyable.new("`reverse_order` is not meaningful inside `summarize` block"); end

    def method_missing(method, *args, **opts, &block)
      next_relation = @relation.send(method, *args, **opts, &block)
      raise Unproxyable.new("Inside `summarize` block, result of `#{method}` must be an ActiveRecord::Relation") unless next_relation.is_a? ActiveRecord::Relation
      self.class.new(@summarize,next_relation)
    end

    private
    def aggregate_column(name)
      @relation.send(:aggregate_column,name)
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

end

class ActiveRecord::Base
  class << self
    def summarize(**opts, &block)
      ActiveRecord::Summarize::Summarize.new(self.all,**opts).process(&block)
    end
  end
end


class ActiveRecord::Relation
  class << self
    def summarize(**opts, &block)
      ActiveRecord::Summarize::Summarize.new(self,**opts).process(&block)
    end
  end
end