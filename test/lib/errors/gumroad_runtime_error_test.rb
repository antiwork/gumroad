# frozen_string_literal: true

require "test_helper"

class GumroadRuntimeErrorTest < ActiveSupport::TestCase
  test "without message or original error: has the default message" do
    raise GumroadRuntimeError
  rescue GumroadRuntimeError => error
    assert_equal "GumroadRuntimeError", error.message
  end

  test "without message or original error: has its own backtrace" do
    raise GumroadRuntimeError
  rescue GumroadRuntimeError => error
    assert_includes error.backtrace[0], "gumroad_runtime_error_test.rb"
  end

  test "with message: uses the given message" do
    raise GumroadRuntimeError, "the-message"
  rescue GumroadRuntimeError => error
    assert_equal "the-message", error.message
  end

  test "with original error: inherits its message" do
    begin
      raise StandardError
    rescue StandardError => original_error
      raise GumroadRuntimeError.new(original_error:)
    end
  rescue GumroadRuntimeError => error
    assert_equal "StandardError", error.message
  end

  test "with original error that has a message: inherits its message" do
    begin
      raise StandardError, "standard error message"
    rescue StandardError => original_error
      raise GumroadRuntimeError.new(original_error:)
    end
  rescue GumroadRuntimeError => error
    assert_equal "standard error message", error.message
  end

  test "with message and original error: uses the explicit message" do
    begin
      raise StandardError
    rescue StandardError => original_error
      raise GumroadRuntimeError.new("the-error-message", original_error:)
    end
  rescue GumroadRuntimeError => error
    assert_equal "the-error-message", error.message
  end
end
