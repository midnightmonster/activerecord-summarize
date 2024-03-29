require_relative "./test_helper"
require_relative "./test_data"

class TestSummarize < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::ActiveRecord::Summarize::VERSION
  end

  def test_data_sanity
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
    summarizing
  end

  def test_noop_summarizing
    summarizing(noop: true)
  end

  def test_sum_of_float_and_int
    # Starting with Rails 7.0.5, continuing through (at least) 7.0.7, in PostgreSQL only,
    # plucking the same aggregate function (e.g., sum) more than once without an alias
    # results in all such columns getting cast to the type of the last such column.
    people = Person.where.not(age: nil)
    a = people.summarize(noop: true) do |p|
      [p.sum(:age), p.sum(:number_of_cats)]
    end
    b = people.summarize(noop: false) do |p|
      [p.sum(:age), p.sum(:number_of_cats)]
    end
    assert_equal(a, b)
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

  def test_grouped_withless
    avg_name_length_by_cats = Person.group(:number_of_cats).summarize do |p|
      p.sum("length(name)").to_f / p.count
    end
    exp = Person.group(:number_of_cats).sum("length(name)").merge(
      Person.group(:number_of_cats).count
    ) do |_key, sum, count|
      sum.to_f / count
    end
    assert_equal(exp, avg_name_length_by_cats)
  end

  def test_most_popular_cat_number
    most_popular_cat_number = Person.joins(:favorite_color).group(:favorite_color).summarize do |p|
      p.group(:number_of_cats).count.max_by { |(k, v)| [v, k] }
    end
    exp = Color.all.to_h do |color|
      [color, color.fans.group(:number_of_cats).count.max_by { |(k, v)| [v, k] }]
    end
    assert_equal(exp, most_popular_cat_number)
  end

  def test_inside_grouping_with_proc
    inside_grouping_with_proc
  end

  def test_noop_inside_grouping_with_proc
    inside_grouping_with_proc(noop: true)
  end

  def test_correct_empty_result_shapes
    correct_empty_result_shapes
  end

  def test_noop_correct_empty_result_shapes
    correct_empty_result_shapes(noop: true)
  end

  def test_null_sums_safely_reported_as_zero
    # SQL SUM(NULL) returns NULL, but in ActiveRecord .sum always returns a number
    # TODO: There's a small inconsistency with .sum of a Float or Decimal column when the calculation result is null:
    #  - ActiveRecord.sum returns 0.0
    #  - .sum inside a summarize block returns integer 0
    exp_single = Person.where(age: nil).sum(:age) # 0.0
    exp_group = Person.group(:number_of_cats).where(age: nil).sum(:age) # {0=>0.0, 1=>0.0, 2=>0.0, 3=>0.0}
    exp_group2 = Person.group(:number_of_cats, Arel.sql("number_of_cats % 2")).where(age: nil).sum(:age) # {[0, 0]=>0.0, [1, 1]=>0.0, [2, 0]=>0.0, [3, 1]=>0.0}
    assert_equal exp_single, Person.summarize { |p| p.where(age: nil).sum(:age) }
    assert_equal exp_group, Person.group(:number_of_cats).summarize { |p| p.where(age: nil).sum(:age) }
    assert_equal exp_group2, Person.group(:number_of_cats, Arel.sql("number_of_cats % 2")).summarize { |p| p.where(age: nil).sum(:age) }
  end

  def test_habtm_join_trivial
    simple_count = Club.joins(:members).group(:id, :name).count
    summarize_count = Club.joins(:members).group(:id, :name).summarize do |clubs|
      clubs.count
    end
    assert_equal simple_count, summarize_count
  end

  def test_habtm_join_summary
    members = Club.joins(:members).group(:id, :name).count
    long_names = Club.joins(:members).group(:id, :name).merge(Person.with_long_name).count
    cat_owners = Club.all.each_with_object({}) do |club, obj|
      obj[[club.id, club.name]] = club.members.group(:number_of_cats).count
    end
    manual = members.to_h do |k, members|
      summary = {
        members: members,
        long_names: long_names[k] || 0,
        cat_owners: cat_owners[k]
      }
      [k, summary]
    end

    club_summary = Club.joins(:members).group(:id, :name).summarize do |clubs|
      {
        members: clubs.count,
        long_names: clubs.merge(Person.with_long_name).count,
        cat_owners: clubs.group(:number_of_cats).count
      }
    end

    assert_equal(manual, club_summary)
  end

  def test_belongs_to_model_group_by
    # Keys are Color models instead of (e.g.) colors.id scalars
    simple_count = Person.joins(:favorite_color).group(:favorite_color).count
    summarize_count = Person.joins(:favorite_color).group(:favorite_color).summarize do |people|
      people.count
    end
    assert_equal simple_count, summarize_count
  end

  def test_inside_grouping_withless
    avg_name_length_by_cats = Person.summarize do |p|
      grouped = p.group(:number_of_cats)
      sums = grouped.sum("length(name)")
      counts = grouped.count
      sums.merge(counts) do |_key, sum, count|
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

  private

  def summarizing(noop: false)
    cat_owners = Person.where(number_of_cats: 1..)
    long_name_where = "length(name) > 20"
    @exp_count = cat_owners.count
    @exp_where_count = cat_owners.where(long_name_where).count
    @exp_scope_count = cat_owners.with_long_name.count
    cat_owners.summarize(noop: noop) do |p|
      @count = p.count
      @where_count = p.where(long_name_where).count
      @scope_count = p.with_long_name.count
    end
    assert_equal @exp_count, @count
    assert_equal @exp_where_count, @where_count
    assert_equal @exp_scope_count, @scope_count
  end

  def inside_grouping_with_proc(noop: false)
    avg_name_length_by_cats = Person.summarize(noop: noop) do |p, with|
      grouped = p.group(:number_of_cats)
      with[grouped.sum("length(name)"), grouped.count] do |sums, counts|
        sums.merge(counts) do |_key, sum, count|
          sum.to_f / count
        end
      end
    end
    exp = Person.group(:number_of_cats).sum("length(name)").merge(
      Person.group(:number_of_cats).count
    ) do |_key, sum, count|
      sum.to_f / count
    end
    assert_equal(exp, avg_name_length_by_cats)
  end

  def correct_empty_result_shapes(noop: false)
    # where(name: "J".."K") is empty because no words in SILLY_WORDS start with J or K
    (many, empty, zero) = Person.summarize(noop: noop) do |p|
      [
        p.group(:number_of_cats).count,
        p.where(name: "J".."K").group(:number_of_cats).count,
        p.where(name: "J".."K").count
      ]
    end
    assert_equal false, many.empty?
    assert_equal true, empty.is_a?(Hash) && empty.empty?
    assert_equal true, zero.zero?
  end
end
