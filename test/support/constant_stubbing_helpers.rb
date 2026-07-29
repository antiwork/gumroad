# frozen_string_literal: true

# Helpers for stubbing top-level constants without RSpec.
# Provides ergonomic block-form replacement that handles the
# "defined or not" case symmetrically.
module ConstantStubbingHelpers
  def with_const(name, value, &block)
    with_const_on(Object, name, value, &block)
  end

  # Same thing for a constant that belongs to a class or module rather than to
  # Object — e.g. a presenter's own PER_PAGE, which tests shrink so that
  # pagination fits a handful of records instead of fifty. `false` as the second
  # argument to const_defined?/const_get keeps the lookup off ancestors, so a
  # same-named constant inherited from a superclass is never mistaken for one
  # this owner actually declares (which would leave a copy behind on restore).
  def with_const_on(owner, name, value)
    defined_before = owner.const_defined?(name, false)
    old = defined_before ? owner.const_get(name, false) : nil
    owner.send(:remove_const, name) if defined_before
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, old) if defined_before
  end
end

ActiveSupport::TestCase.include(ConstantStubbingHelpers)
