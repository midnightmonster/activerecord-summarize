module ActiveRecord::Summarize::CalculationImplementation
  def self.new(operation, relation, column_name)
    case operation
    when "sum" then Sum
    when "count" then Count
    when "minimum" then Minimum
    when "maximum" then Maximum
    else raise "Unknown calculation #{operation}"
    end.new(relation, column_name)
  end

  class Base
    attr_reader :relation, :column

    def initialize(relation, column)
      @relation = relation
      @column = column
    end

    def select_column_arel_node(base_relation)
      where = relation.where_clause - base_relation.where_clause
      for_select = column
      for_select = Arel::Nodes::Case.new(where.ast).when(true, for_select).else(unmatch_arel_node) unless where.empty?
      function_arel_node_class.new([for_select]).tap { |f| f.distinct = relation.distinct_value }
    end

    def function_arel_node_class
      # Arel::Node class representing the SQL function
      raise "`#{self.class}` must implement `function_arel_node_class`"
    end

    def unmatch_arel_node
      # In case of `where` filters, this is the does-not-count value for when
      # filters don't match, so far always 0 or nil (becomes NULL)
      raise "`#{self.class}` must implement `unmatch_arel_node`"
    end

    def initial
      # Initial value for reducing potentially many split-into-groups rows to
      # a single value, so far always 0 or nil.
      raise "`#{self.class}` must implement `initial`"
    end

    def reducer(memo, v)
      # Reducer method for reducing potentially many split-into-groups rows to
      # a single value. Method should return a value the same type as memo
      # and/or v. A reducer is necessary at all because .group in columns
      # _other than_ this one results in fragmenting this result into several
      # rows.
      raise "`#{self.class}` must implement `reducer`"
    end
  end

  class Sum < Base
    def unmatch_arel_node
      0 # Adding zero to a sum does nothing
    end

    def function_arel_node_class
      Arel::Nodes::Sum
    end

    def initial
      0
    end

    def reducer(memo, v)
      memo + (v || 0)
    end
  end

  class Count < Base
    def unmatch_arel_node
      nil # In SQL, null is no value and is not counted
    end

    def function_arel_node_class
      Arel::Nodes::Count
    end

    def initial
      0
    end

    def reducer(memo, v)
      memo + (v || 0)
    end
  end

  class Minimum < Base
    def unmatch_arel_node
      nil # In SQL, null is no value and is not considered for min()
    end

    def function_arel_node_class
      Arel::Nodes::Min
    end

    def initial
      nil
    end

    def reducer(memo, v)
      return memo if v.nil?
      return v if memo.nil?
      v < memo ? v : memo
    end
  end

  class Maximum < Base
    def unmatch_arel_node
      nil # In SQL, null is no value and is not considered for max()
    end

    def function_arel_node_class
      Arel::Nodes::Max
    end

    def initial
      nil
    end

    def reducer(memo, v)
      return memo if v.nil?
      return v if memo.nil?
      v > memo ? v : memo
    end
  end
end
