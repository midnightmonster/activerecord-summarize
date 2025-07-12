# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "active_record"
require "activerecord/summarize"

require "minitest/autorun"

module AssertNoopEqual
  def compare_noop(message = "was not equal with noop: true and noop: false")
    noop_result = yield(true)
    result = yield(false)
    assert_equal noop_result, result
    result
  end
end
