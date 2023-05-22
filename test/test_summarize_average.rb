require_relative "./test_helper"
require_relative "./test_data"

class TestSummarize < Minitest::Test
  include AssertNoopEqual

  def test_simple_average_age
    compare_noop do |noop|
      Person.summarize(noop: noop) { |p| p.average(:age).round(10) }
    end
  end

  def test_grouped_average_age
    compare_noop do |noop|
      Person.summarize(noop: noop) do |p|
        p.group(:number_of_cats).average(:age).transform_values { |v| v.round(10) }
      end
    end
    assert_equal(
      Person.group(:number_of_cats).average(:age).transform_values { |v| v.round(10) },
      Person.group(:number_of_cats).summarize { |p| p.average(:age).round(10) }
    )
  end

  def test_average_with_other_group
    compare_noop do |noop|
      Person.summarize(noop: noop) do |p|
        [
          p.average(:age).round(10),
          p.where(number_of_cats: 1..).group(:number_of_cats).count
        ]
      end
    end
  end

  def test_average_with_nested_group_and_filter
    demo_sql_fragment = Arel.sql("case age >= 50 when 1 then 'senior' else 'junior' end")
    summary = Person.group(:favorite_color_id).summarize do |p|
      {
        how_many: p.count,
        avg_adult_age: p.where(age: 18..).average(:age).round(10),
        demographic_cats: p.group(demo_sql_fragment).average(:number_of_cats).transform_values { |v| v.round(10) }
      }
    end
    assert_equal(
      Person.group(:favorite_color_id).count,
      summary.transform_values { |v| v[:how_many] },
      "basic favorite color count did not match"
    )
    assert_equal(
      Person.group(:favorite_color_id).where(age: 18..).average(:age).transform_values { |v| v.round(10) },
      summary.transform_values { |v| v[:avg_adult_age] },
      "grouped & filtered avg age did not match"
    )
    assert_equal(
      Person.group(:favorite_color_id, demo_sql_fragment).average(:number_of_cats).transform_values { |v| v.round(10) },
      summary.flat_map do |key_a, s|
        s[:demographic_cats].map do |key_b, avg|
          [[key_a, key_b], avg]
        end
      end.to_h,
      "double-grouped and filtered average didn't match"
    )
  end
end
