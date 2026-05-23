# frozen_string_literal: true

module WithConst
  def with_const(name, value)
    parent, const_name = constant_parent_and_name(name)
    old_defined = parent.const_defined?(const_name, false)
    old_value = parent.const_get(const_name, false) if old_defined
    parent.send(:remove_const, const_name) if old_defined
    parent.const_set(const_name, value)
    yield
  ensure
    parent.send(:remove_const, const_name) if parent&.const_defined?(const_name, false)
    parent.const_set(const_name, old_value) if old_defined
  end

  def stub_const(name, value)
    return with_const(name, value) { yield } if block_given?

    parent, const_name = constant_parent_and_name(name)
    old_defined = parent.const_defined?(const_name, false)
    old_value = parent.const_get(const_name, false) if old_defined
    parent.send(:remove_const, const_name) if old_defined
    parent.const_set(const_name, value)
    rspec_stub_restores << lambda do
      parent.send(:remove_const, const_name) if parent.const_defined?(const_name, false)
      parent.const_set(const_name, old_value) if old_defined
    end
    value
  end

  private
    def constant_parent_and_name(name)
      parts = name.to_s.split("::")
      const_name = parts.pop
      parent = parts.reduce(Object) { |mod, part| mod.const_get(part) }
      [parent, const_name]
    end
end
