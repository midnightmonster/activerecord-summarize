# frozen_string_literal: true

require_relative "./test_helper"
require_relative "./test_data"

class TestSummarize < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::ActiveRecord::Summarize::VERSION
  end

  def test_sanity
    assert_equal 500, Person.count
    # 1 in ~2.679 E 300 chance this isn't true
    assert_includes 2..4, Person.distinct.count(:number_of_cats)
  end

  def test_single_counts_are_accurate
    assert_equal Person.count, Person.summarize { |p| p.count }
    filtered = Person.where(number_of_cats: 1..)
    assert_equal filtered.count, filtered.summarize { |p| p.count }
  end

  def test_simple_grouped_count_is_accurate
    grouped = Person.group(:number_of_cats)
    assert_equal grouped.count, grouped.summarize { |p| p.count }
  end

  def test_summarizing
    cat_owners = Person.where(number_of_cats: 1..)
    long_name_where = "length(name) > 20"
    @exp_count = cat_owners.count
    @exp_where_count = cat_owners.where(long_name_where).count
    @exp_scope_count = cat_owners.with_long_name.count
    cat_owners.summarize do |p|
      @count = p.count
      @where_count = p.where(long_name_where).count
      @scope_count = p.with_long_name.count
    end
    assert_equal @exp_count, @count
    assert_equal @exp_where_count, @where_count
    assert_equal @exp_scope_count, @scope_count
  end

  def test_prevents_distinct
    assert_raises(ActiveRecord::Summarize::Unsummarizable) do
      # This trivial case we actually could get right, but once we end up with additional group_values, distinct is likely to be wrong.
      Person.summarize { |p| p.distinct.count :number_of_cats }
    end
    assert_raises(ActiveRecord::Summarize::Unsummarizable) do
      Person.summarize { |p| p.count("distinct number_of_cats") }
    end
  end

  def test_grouped_with_proc
    avg_name_length_by_cats = Person.group(:number_of_cats).summarize do |p, with|
      with[p.sum("length(name)"), p.count] do |sum, count|
        sum.to_f / count
      end
    end
    exp = Person.group(:number_of_cats).sum("length(name)").merge(
      Person.group(:number_of_cats).count
    ) do |_key, sum, count|
      sum.to_f / count
    end
    assert_equal(exp, avg_name_length_by_cats)
  end
end
