# frozen_string_literal: true

module Product::Validations
  include ActionView::Helpers::TextHelper

  MAX_VIEW_CONTENT_BUTTON_TEXT_LENGTH = 26
  CUSTOM_FIELD_TYPES = %w[text terms checkbox].freeze

  private
    def preview_url_https
      return if preview_url.blank?

      errors.add(:base, "Sorry, the product must have a secure (https) preview URL.") unless URI(URI::DEFAULT_PARSER.escape(preview_url).gsub("[", "%5B").gsub("]", "%5D")).is_a?(URI::HTTPS)
    end

    def max_purchase_count_is_greater_than_or_equal_to_inventory_sold
      return unless max_purchase_count_changed?
      return if max_purchase_count.nil?
      errors.add(:base, "Sorry, you cannot limit the number of purchases to that amount.") unless max_purchase_count >= sales_count_for_inventory
    end

    def require_shipping_for_physical
      errors.add(:base, "Shipping form is required for physical products.") if is_physical && !require_shipping
    end

    def duration_multiple_of_price_options
      return unless is_recurring_billing
      return if duration_in_months.nil?

      return errors.add(:base, "Your subscription length in months must be a number greater than zero.") if duration_in_months <= 0

      prices.alive.pluck(:recurrence).each do |recurrence|
        unless duration_in_months % BasePrice::Recurrence.number_of_months_in_recurrence(recurrence) == 0
          return errors.add(:base, "Your subscription length in months must be a multiple of #{BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)} because you have selected a payment option of #{recurrence} payments.")
        end
      end
    end

    def custom_view_content_button_text_length
      return if custom_view_content_button_text.blank? || custom_view_content_button_text.length <= MAX_VIEW_CONTENT_BUTTON_TEXT_LENGTH

      over_limit = custom_view_content_button_text.length - MAX_VIEW_CONTENT_BUTTON_TEXT_LENGTH
      errors.add(:base, "Button: #{pluralize(over_limit, 'character')} over limit (max: #{MAX_VIEW_CONTENT_BUTTON_TEXT_LENGTH})")
    end

    def content_has_no_adult_keywords
      [description, name].each do |content|
        if AdultKeywordDetector.adult?(content)
          errors.add(:base, "Adult keywords are not allowed")
          break
        end
      end
    end

    def bundle_is_not_in_bundle
      return unless BundleProduct.alive.where(product: self).exists?

      errors.add(:base, "This product cannot be converted to a bundle because it is already part of a bundle.")
    end

    def published_bundle_must_have_at_least_one_product
      return unless published?
      return if not_is_bundle?
      return if bundle_products.alive.exists?

      errors.add(:base, "Bundles must have at least one product.")
    end

    def user_is_eligible_for_service_products
      return if user.eligible_for_service_products?

      errors.add(:base, "Service products are disabled until your account is 30 days old.")
    end

    def commission_price_is_valid
      double_min_price = currency["min_price"] * 2
      return if price_cents == 0 || price_cents >= double_min_price

      errors.add(:base, "The commission price must be at least #{formatted_amount_in_currency(double_min_price, price_currency_type, no_cents_if_whole: true)}.")
    end

    def one_coffee_per_user
      return unless user.links.visible_and_not_archived.where(native_type: Link::NATIVE_TYPE_COFFEE).where.not(id:).exists?

      errors.add(:base, "You can only have one coffee product.")
    end

    def calls_must_have_at_least_one_duration
      return unless native_type == Link::NATIVE_TYPE_CALL
      return if deleted_at.present?
      return if variant_categories.alive.first&.alive_variants&.exists?

      errors.add(:base, "Calls must have at least one duration")
    end
end
