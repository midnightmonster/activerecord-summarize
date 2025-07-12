require_relative "./test_helper"
require_relative "./test_data"

class TestSummarize < Minitest::Test
  include AssertNoopEqual

  def test_simple_minmax_age
    compare_noop do |noop|
      Person.summarize(noop: noop) do |p|
        [p.minimum(:age), p.maximum(:age)]
      end
    end
  end

  def test_grouped_minmax_age
    compare_noop do |noop|
      Person.summarize(noop: noop) do |p|
        [p.group(:number_of_cats).minimum(:age), p.group(:number_of_cats).minimum(:age)]
      end
    end
    assert_equal(
      Person.group(:number_of_cats).minimum(:age),
      Person.group(:number_of_cats).summarize { |p| p.minimum(:age) }
    )
    assert_equal(
      Person.group(:number_of_cats).maximum(:age),
      Person.group(:number_of_cats).summarize { |p| p.maximum(:age) }
    )
  end

  def test_minmax_with_other_group
    compare_noop do |noop|
      Person.summarize(noop: noop) do |p|
        [
          p.minimum(:age),
          p.maximum(:age),
          p.where(number_of_cats: 1..).group(:number_of_cats).count
        ]
      end
    end
  end

  def test_minmax_with_nested_group_and_filter
    demo_sql_fragment = Arel.sql("case age >= 50 when 1 then 'senior' else 'junior' end")
    summary = Person.group(:favorite_color_id).summarize do |p|
      {
        how_many: p.count,
        min_adult_age: p.where(age: 18..).minimum(:age),
        max_adult_age: p.where(age: 18..).maximum(:age),
        min_demographic_cats: p.group(demo_sql_fragment).minimum(:number_of_cats),
        max_demographic_cats: p.group(demo_sql_fragment).maximum(:number_of_cats)
      }
    end
    assert_equal(
      Person.group(:favorite_color_id).count,
      summary.transform_values { |v| v[:how_many] },
      "basic favorite color count did not match"
    )
    assert_equal(
      Person.group(:favorite_color_id).where(age: 18..).minimum(:age),
      summary.transform_values { |v| v[:min_adult_age] },
      "grouped & filtered minimum age did not match"
    )
    assert_equal(
      Person.group(:favorite_color_id).where(age: 18..).maximum(:age),
      summary.transform_values { |v| v[:max_adult_age] },
      "grouped & filtered maximum age did not match"
    )
    assert_equal(
      Person.group(:favorite_color_id, demo_sql_fragment).minimum(:number_of_cats),
      summary.flat_map do |key_a, s|
        s[:min_demographic_cats].map do |key_b, min|
          [[key_a, key_b], min]
        end
      end.to_h,
      "double-grouped and filtered minimum didn't match"
    )
    assert_equal(
      Person.group(:favorite_color_id, demo_sql_fragment).maximum(:number_of_cats),
      summary.flat_map do |key_a, s|
        s[:max_demographic_cats].map do |key_b, max|
          [[key_a, key_b], max]
        end
      end.to_h,
      "double-grouped and filtered maximum didn't match"
    )
  end
end
