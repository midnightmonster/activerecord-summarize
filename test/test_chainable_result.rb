require_relative "./test_helper"
require_relative "./test_data"

class TestChainableResult < Minitest::Test
  def test_with_invocations
    counts, factor, addends = toy_values.map { |v| ChainableResult.wrap(v) }
    # A single value
    assert_equal(
      {123 => :foo, 200 => :bar},
      ChainableResult::WITH[counts] { |h| h.to_h { |k, v| [v, k] } }.value
    )
    # Two values with a block that receives two arguments
    assert_equal(
      {foo: 369, bar: 600},
      ChainableResult::WITH[counts, factor] { |h, f| h.transform_values { |v| v * f } }.value
    )
    # Two values with a block that receives one argument (as an array)
    assert_equal(
      163,
      ChainableResult::WITH[factor, addends] { |vs| vs.flatten.sum }.value
    )
    # Three values with a block that receives three arguments
    assert_equal(
      {foo: 469, bar: 660},
      ChainableResult::WITH[counts, factor, addends] { |h, f, a| h.transform_values.each_with_index { |v, i| v * f + a[i] } }.value
    )
    # Three values with a block that receives two arguments (there's probably no good reason to do this)
    assert_equal(
      {foo: 369, bar: 600},
      ChainableResult::WITH[counts, factor, addends] { |h, f| h.transform_values { |v| v * f } }.value
    )
    # Repeated argument and symbol proc
    assert_equal(
      9,
      ChainableResult::WITH[factor, factor, factor, &:sum].value
    )
  end

  def test_sync_with_invocations
    counts, factor, addends = toy_values
    # A single value
    assert_equal(
      {123 => :foo, 200 => :bar},
      ChainableResult::SYNC_WITH[counts] { |h| h.to_h { |k, v| [v, k] } }
    )
    # Two values with a block that receives two arguments
    assert_equal(
      {foo: 369, bar: 600},
      ChainableResult::SYNC_WITH[counts, factor] { |h, f| h.transform_values { |v| v * f } }
    )
    # Two values with a block that receives one argument (as an array)
    assert_equal(
      163,
      ChainableResult::SYNC_WITH[factor, addends] { |vs| vs.flatten.sum }
    )
    # Three values with a block that receives three arguments
    assert_equal(
      {foo: 469, bar: 660},
      ChainableResult::SYNC_WITH[counts, factor, addends] { |h, f, a| h.transform_values.each_with_index { |v, i| v * f + a[i] } }
    )
    # Three values with a block that receives two arguments (there's probably no good reason to do this)
    assert_equal(
      {foo: 369, bar: 600},
      ChainableResult::SYNC_WITH[counts, factor, addends] { |h, f| h.transform_values { |v| v * f } }
    )
    # Repeated argument and symbol proc
    assert_equal(
      9,
      ChainableResult::SYNC_WITH[factor, factor, factor, &:sum]
    )
  end

  private

  def toy_values
    [{foo: 123, bar: 200}, 3, [100, 60]]
  end
end
