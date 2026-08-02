# frozen_string_literal: true

class TaxonomyAttribute < ApplicationRecord
  VALUE_TYPES = %w[enum boolean number].freeze
  FILTERABLE_VALUE_TYPES = %w[enum boolean].freeze

  belongs_to :taxonomy

  scope :active_ordered, -> { where(active: true).order(:position, :id) }

  validates :name, presence: true, uniqueness: { scope: :taxonomy_id }, format: { with: /\A[a-z0-9_]+\z/ }
  validates :label, :value_type, presence: true
  validates :value_type, inclusion: { in: VALUE_TYPES }

  def filterable?
    FILTERABLE_VALUE_TYPES.include?(value_type)
  end

  def normalize_value(value)
    case value_type
    when "enum"
      value.to_s if normalized_options.include?(value.to_s)
    when "boolean"
      ActiveModel::Type::Boolean.new.cast(value).to_s if !value.nil? && value != ""
    when "number"
      Float(value).finite? ? value.to_s : nil
    end
  rescue ArgumentError, TypeError
    nil
  end

  def filter_token_for(value)
    normalized_value = normalize_value(value)
    return if normalized_value.blank? || !filterable?

    "#{name}:#{normalized_value.parameterize(separator: "_")}"
  end

  def label_for_token_value(token_value)
    return token_value.titleize if value_type == "boolean"

    normalized_options.find { |option| option.parameterize(separator: "_") == token_value } || token_value
  end

  def normalized_options
    Array(values).map(&:to_s)
  end
end
