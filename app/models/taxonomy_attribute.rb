# frozen_string_literal: true

class TaxonomyAttribute < ApplicationRecord
  VALUE_TYPES = %w[enum boolean number].freeze
  FILTERABLE_VALUE_TYPES = %w[enum boolean].freeze

  belongs_to :taxonomy

  scope :active, -> { where(active: true) }
  scope :active_ordered, -> { active.order(:position, :id) }

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

  def normalized_options
    Array(values).map(&:to_s)
  end

  def filter_options
    value_type == "boolean" ? %w[true false] : normalized_options
  end

  def filter_label_for(value)
    return value == "true" ? "Yes" : "No" if value_type == "boolean"

    value
  end

  # The token space a request is allowed to filter on right now. Retiring an attribute (or
  # dropping/renaming one of its values) doesn't touch already-indexed products — see
  # `Onetime::SeedTaxonomyAttributes` — so a stale bookmarked or hand-built URL can otherwise
  # keep matching documents that still carry the old token.
  def self.valid_filter_tokens
    active.each_with_object(Set.new) do |attribute, tokens|
      attribute.filter_options.each do |option|
        token = attribute.filter_token_for(option)
        tokens << token if token
      end
    end
  end
end
