# frozen_string_literal: true

module ParameterObject
  extend ActiveSupport::Concern

  included do
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveModel::Validations
  end

  class_methods do
    def call(**params)
      new(**params)
    end
  end

  def to_h
    attributes.symbolize_keys
  end

  def [](key)
    public_send(key)
  end
end
