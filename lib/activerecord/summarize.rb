# frozen_string_literal: true

require_relative "summarize/version"

module ActiveRecord::Summarize
  class Error < StandardError; end
  class Unproxyable < StandardError; end
  class TimeTravel < StandardError; end

  class Summarize
    def initialize(relation)
      @relation = relation
      @futures = Set.new
      @queue = []
    end

    def process(&block)
      block_result = yield SummarizingProxy.new(self, @relation)
      resolve(block_result, block.binding)
    end

    def add_future(relation,method,column_sql)
      future = AggregateResult.new(self,relation,method,column_sql)
      @futures << future
      future
    end

    def enqueue(future,method,block)
      case method
      when :tap
        @queue << [future,:_tap,block]
        future
      when :then
        @queue << [tr = ThenResult.new(future),:resolve,block]
        tr
      else raise Error.new("Don't know how to enqueue #{method.inspect}")
      end
    end

    # :where, :joins, and :left_outer_joins are the only use cases I've seen IRL
    BASE_QUERY_PARTS = [:where, :limit, :offset, :joins, :left_outer_joins, :from, :optimizer_hints]
    AGGREGATE_FROM_WHERE_PARTS = [:where, :joins, :left_outer_joins, :from]

    def resolve(block_value,block_context)
      # groups = []
      # plucks = []
      base_from_where = @relation.only(*BASE_QUERY_PARTS)
      full_from_where = block_value.
        map {|f| f.relation.only(*AGGREGATE_FROM_WHERE_PARTS) }.
        inject(base_from_where) {|f, memo| memo.or(f) }
      base_group = @relation.group_values
      groups = base_group + block_value.map {|f| f.relation.group_values }.flatten.uniq
      grouped_query = groups.any? ? full_from_where.group(*groups) : full_from_where
      plucks = block_value.map {|f| f.select_value(@relation) }
      result = grouped_query.pluck(*groups,*plucks)
      [groups, result]
      # TODO support hash returns
      # TODO support single value returns
      # TODO don't assume the whole return is FutureResults
      # TODO collect things to query (try just using the block_value first, allowing arrays and hashes)
      # TODO do query
      # TODO assign results
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

    def count(column_name=:id)
      column_name = :id if ['*',:all].include? column_name
      @summarize.add_future(@relation,:count,aggregate_column(column_name))
    end

    def sum(column_name=nil)
      @summarize.add_future(@relation,:sum,aggregate_column(column_name))
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

  class FutureResult
    def initialize
      @value = nil
      @resolved = false
    end

    def tap(&block)
      @summarize.enqueue self, :tap, block
    end

    def then(&block)
      @summarize.enqueue self, :then, block
    end

    def value
      raise TimeTravel.new("#{this.class.name} not resolved yet") unless @resolved
      @value
    end

    def arel
      # TODO: remove me; only for development
      @relation.arel
    end

    def method_missing(method, *args, &block)
      raise NoMethodError.new(method)
    end

    protected
    def _tap(&block)
      value.tap &block
      self
    end

    def relation
      @relation
    end
  end

  class AggregateResult < FutureResult
    attr_reader :relation, :method, :column

    def initialize(summarize,relation,method,column)
      super()
      @summarize = summarize
      @relation = relation
      @method = method
      @column = column
    end

    def resolve(value)
      @resolved = true
      @value = value
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

  class ThenResult < FutureResult
    def initialize(parent, &block)
      super
      @parent = parent
      @block = block
    end

    def resolve!
      @resolved = true
      @value = @parent.value.then &@block
    end
  end


end

class ActiveRecord::Base
  class << self
    def summarize(noop: false, &block)
      return yield self.all if noop
      ActiveRecord::Summarize::Summarize.new(self.all).process(&block)
    end
  end
end


class ActiveRecord::Relation
  class << self
    def summarize(noop: false, &block)
      return yield self if noop
      ActiveRecord::Summarize::Summarize.new(self).process(&block)
    end
  end
end