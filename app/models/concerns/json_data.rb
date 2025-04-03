# frozen_string_literal: true

# Mixin for modules that contain a `json_data` field. Adds functions that
# standardize how data is stored within the `json_data` field, and what happens
# if the data within is not present or blank.
#
# All functions are safe to call when `json_data` is nil and it does not need
# to be initialized before use.
module JsonData
  extend ActiveSupport::Concern

  included do
    extend ClassMethods
    serialize :json_data, coder: JSON
  end

  module ClassMethods
    # Public: Defines both reader and writer methods for an attributes
    # stored within json_data.
    # Can be used with a single attribute at a time.
    #  * attribute – the name of the attribute, as a symbol
    #  * default – the value that will be returned by the reader if the value is blank
    #              the default may be a lambda, Proc, or a static value.
    def attr_json_data_accessor(attribute, default: nil)
      attr_json_data_reader(attribute, default:)
      attr_json_data_writer(attribute)
    end

    # Public: Defines reader methods for attributes in json_data.
    # Can be used with a single attribute at a time.
    #  * attribute – the name of the attribute, as a symbol
    #  * default – the value that will be returned if the value is blank
    #              the default may be a lambda, Proc, or a static value.
    def attr_json_data_reader(attribute, default: nil)
      define_method(attribute) do
        default_value = default.try(:respond_to?, :call) ? instance_exec(&default) : default
        json_data_for_attr(attribute.to_s, default: default_value)
      end
    end

    # Public: Defines writer methods for attributes in json_data.
    # Can be used with a single attribute at a time.
    #  * attribute – the name of the attribute, as a symbol
    def attr_json_data_writer(attribute)
      define_method("#{attribute}=") do |value|
        set_json_data_for_attr(attribute.to_s, value)
      end
    end
  end

  # Public: Returns the json_data field, instantiating it to an empty hash if
  # it is not already set.
  def json_data
    self[:json_data] ||= {}
    raise ArgumentError, "json_data must be a hash" unless self[:json_data].is_a?(Hash)

    self[:json_data].deep_stringify_keys!
  end

  # Public: Sets the attribute on the json_data of this object, such that
  # calling with attribute 'attr' and value 'value' will result in a json_data
  # field containing:
  # { 'attr' => 'value' }
  def set_json_data_for_attr(attribute, value)
    json_data[attribute] = value
  end

  # Public: Gets the value for an attribute on the json_data of this object, such that
  # calling with attribute 'attr' of the following json_data would return 'value':
  # { 'attr' => 'value' }
  #
  # If the attr is not present in the json_data, the value passed as the default will be returned.
  def json_data_for_attr(attribute, default: nil)
    return json_data[attribute] if json_data && json_data[attribute].present?

    default
  end
end
