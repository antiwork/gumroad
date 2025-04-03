# frozen_string_literal: true

class Hash
  def deep_reject!(&block)
    reject! do |key, value|
      value.deep_reject!(&block) if value.is_a?(Hash)
      yield(key, value)
    end

    self
  end

  def deep_values_strip!
    transform_values! do |value|
      if value.is_a?(String)
        value.strip
      elsif value.is_a?(Hash)
        value.deep_values_strip!
      else
        value
      end
    end
  end
end
