# frozen_string_literal: true

class ProductInstallmentPlan < ApplicationRecord
  include CurrencyHelper
  include Deletable

  belongs_to :link, inverse_of: :installment_plan
  has_many :payment_options, dependent: :restrict_with_exception

  enum :recurrence,
       BasePrice::Recurrence::ALLOWED_INSTALLMENT_PLAN_RECURRENCES.index_by(&:itself), default: "monthly"

  validates :number_of_installments,
            presence: true, numericality: { only_integer: true, greater_than: 1 }

  validate :validate_product_eligibility, unless: :being_marked_as_deleted?
  validate :validate_bundle_content_eligibility, unless: :being_marked_as_deleted?
  validate :validate_installment_payment_price, unless: :being_marked_as_deleted?

  ELIGIBLE_PRODUCT_NATIVE_TYPES = [
    Link::NATIVE_TYPE_CALL,
    Link::NATIVE_TYPE_COURSE,
    Link::NATIVE_TYPE_DIGITAL,
    Link::NATIVE_TYPE_EBOOK,
    Link::NATIVE_TYPE_BUNDLE,
  ].to_set.freeze

  class << self
    def eligible_for_product?(link)
      eligibility_erorr_message_for_product(link).blank?
    end

    def eligibility_erorr_message_for_product(link)
      if link.is_recurring_billing? || link.is_tiered_membership?
        return "Installment plans are not available for membership products"
      end

      if link.is_in_preorder_state?
        return "Installment plans are not available for pre-order products"
      end

      unless ELIGIBLE_PRODUCT_NATIVE_TYPES.include?(link.native_type)
        return "Installment plans are not available for this product type"
      end

      nil
    end
  end

  def calculate_installment_payment_price_cents(full_price_cents)
    base_price = full_price_cents / number_of_installments
    remainder = full_price_cents % number_of_installments

    Array.new(number_of_installments) do |i|
      i.zero? ? base_price + remainder : base_price
    end
  end

  def destroy_if_no_payment_options!
    destroy!
  rescue ActiveRecord::DeleteRestrictionError
    mark_deleted!
  end

  private
    def validate_product_eligibility
      if error_message = self.class.eligibility_erorr_message_for_product(link)
        errors.add(:base, error_message)
      end
    end

    def validate_bundle_content_eligibility
      return unless link.is_bundle?

      ineligible_products = link.bundle_products.alive.includes(:product)
        .reject(&:eligible_for_installment_plans?)

      if ineligible_products.any?
        errors.add(:base, "Installment plan is not available for the bundled product: #{ineligible_products.first.product.name}")
      end
    end

    def validate_installment_payment_price
      if link.customizable_price?
        errors.add(:base, 'Installment plans are not available for "pay what you want" pricing')
      end

      if link.currency["min_price"] * (number_of_installments || 0) > link.price_cents
        errors.add(:base, "The minimum price for each installment must be at least #{formatted_amount_in_currency(link.currency["min_price"], link.price_currency_type, no_cents_if_whole: true)}.")
      end
    end
end
