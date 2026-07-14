# frozen_string_literal: true

# Helpers for stubbing top-level constants without RSpec.
# Provides ergonomic block-form replacement that handles the
# "defined or not" case symmetrically.
module ConstantStubbingHelpers
  def with_const(name, value)
    defined_before = Object.const_defined?(name, false)
    old = defined_before ? Object.const_get(name, false) : nil
    Object.send(:remove_const, name) if defined_before
    Object.const_set(name, value)
    yield
  ensure
    Object.send(:remove_const, name) if Object.const_defined?(name, false)
    Object.const_set(name, old) if defined_before
  end
end

ActiveSupport::TestCase.include(ConstantStubbingHelpers)
