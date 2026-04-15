# frozen_string_literal: true

class PurchasePreview
  include ActiveModel::Model

  attr_accessor :link, :seller, :created_at, :quantity, :custom_fields,
                :formatted_total_display_price_per_unit, :shipping_cents,
                :displayed_price_currency_type, :url_redirect, :displayed_price_cents,
                :support_email, :charged_amount_cents, :external_id_for_invoice,
                :unbundled_purchases, :successful_purchases, :orderable

  validates :link, presence: true
  validates :seller, presence: true
  validates :created_at, presence: true
  validates :quantity, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :formatted_total_display_price_per_unit, presence: true
  validates :shipping_cents, presence: true
  validates :displayed_price_currency_type, presence: true
  validates :url_redirect, presence: true
  validates :displayed_price_cents, presence: true
  validates :charged_amount_cents, presence: true
  validates :external_id_for_invoice, presence: true
  validates :unbundled_purchases, presence: true
  validates :successful_purchases, presence: true
  validates :orderable, presence: true
  validate :validate_custom_fields

  # The receipt template uses a lot of fields of `purchase`
  # in different pieces of business logic that are not relevant to our preview need.
  # For them it's fine to return `nil` instead of trying to add fields
  # to mock all those irrelevant pieces of business logic.
  #
  # Meanwhile the fields that are needed for previews are defined in `attr_accessor`
  # and we have validations for them.
  def method_missing(name)
    nil
  end

  private
    def validate_custom_fields
      errors.add(:custom_fields, "must be an array") unless custom_fields.is_a?(Array)
    end
end
