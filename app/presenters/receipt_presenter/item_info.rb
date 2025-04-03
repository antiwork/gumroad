# frozen_string_literal: true

class ReceiptPresenter::ItemInfo
  include ActionView::Helpers::TextHelper
  include ActionView::Helpers::UrlHelper
  include CurrencyHelper
  include PreorderHelper
  include ProductsHelper
  include BasePrice::Recurrence

  attr_reader :product, :purchase

  def initialize(purchase)
    @product = purchase.link
    @purchase = purchase
    @seller = purchase.link.user
    @subscription = purchase.subscription
  end

  def props
    {
      notes:,
      custom_receipt_note:,
      show_download_button:,
      license_key:,
      gift_attributes:,
      general_attributes:,
      product: product_props,
      manage_subscription_note:
    }
  end

  private
    attr_reader :seller, :subscription

    def product_props
      @_product_props ||= ProductPresenter.card_for_email(product:)
    end

    def notes
      [
        free_trial_purchase_note,
        physical_product_note,
        rental_product_note,
        preorder_note
      ].compact
    end

    def custom_receipt_note
      return if purchase.link.custom_receipt.blank?
      return if purchase.is_gift_receiver_purchase && purchase.gift_note.present?

      Rinku.auto_link(simple_format(purchase.link.custom_receipt))
    end

    def free_trial_purchase_note
      return unless purchase.is_free_trial_purchase?

      "Your free trial has begun!"
    end

    def physical_product_note
      return unless purchase.link.is_physical
      return if purchase.is_gift_sender_purchase

      if purchase.is_preorder_authorization
        "The shipment will occur soon after #{displayable_release_at_date_and_time(
            purchase.link.preorder_link.release_at,
            purchase.link.user.timezone
          )}."
      else
        "Your order will ship shortly. The creator will notify you when your package is on its way."
      end
    end

    def rental_product_note
      return unless purchase.is_rental

      "Your rental of #{purchase.link.name} will expire in 30 days or 72 hours after you begin viewing it."
    end

    def preorder_note
      return unless purchase.is_preorder_authorization

      "You'll get it on #{displayable_release_at_date_and_time(
          purchase.link.preorder_link.release_at,
          purchase.link.user.timezone
        )}."
    end

    def show_download_button
      !purchase.is_gift_sender_purchase &&
      !purchase.is_preorder_authorization &&
      (purchase.url_redirect.present? || purchase.is_commission_completion_purchase?) &&
      purchase.link.native_type != Link::NATIVE_TYPE_COFFEE
    end

    def license_key
      return if purchase.license_key.blank?
      return if purchase.is_gift_sender_purchase

      purchase.license_key
    end

    def gift_attributes
      return [] unless purchase.is_gift_sender_purchase

      [gift_sender_attribute, gift_message_attribute].compact
    end

    def gift_sender_attribute
      {
        label: "Gift sent to",
        value: purchase.giftee_name_or_email
      }
    end

    def gift_message_attribute
      value = purchase.gift_note.strip
      return if value.blank?

      {
        label: "Message",
        value:
      }
    end

    def general_attributes
      [
        call_attributes,
        bundle_attribute,
        variant_attribute,
        product_unit_price_attribute,
        tip_attribute,
        quantity_or_seats_attribute,
        custom_fields_attributes,
        refund_policy_attribute
      ].flatten.compact
    end

    def bundle_attribute
      return unless purchase.is_bundle_product_purchase

      bundle_product = purchase.bundle_purchase.link
      {
        label: "Bundle",
        value: link_to(bundle_product.name, bundle_product.long_url, target: "_blank").html_safe
      }
    end

    def variant_attribute
      return unless purchase.variant_names&.any?
      return if purchase.link.native_type === Link::NATIVE_TYPE_COFFEE

      {
        label: purchase.link.native_type === Link::NATIVE_TYPE_CALL ? "Duration" : "Variant",
        value: variant_names_displayable(purchase.variant_names),
      }
    end

    def product_unit_price_attribute
      return if purchase.free_purchase?

      {
        label: purchase.link.native_type === Link::NATIVE_TYPE_COFFEE ? "Donation" : "Product price",
        value: purchase.formatted_total_display_price_per_unit
      }
    end

    def tip_attribute
      return unless purchase.tip.present?

      {
        label: "Tip",
        value: format_just_price_in_cents(purchase.tip.value_cents, purchase.displayed_price_currency_type),
      }
    end

    def quantity_or_seats_attribute
      @_quantity_or_seats_attribute ||= begin
        return if purchase.quantity <= 1
        return if purchase.is_gift_sender_purchase
        return if purchase.link.native_type === Link::NATIVE_TYPE_COFFEE

        label = if purchase.license_key.present? && purchase.is_multiseat_license?
          "Number of seats"
        else
          "Quantity"
        end
        {
          label:,
          value: purchase.quantity,
        }
      end
    end

    def custom_fields_attributes
      purchase.custom_fields.map { custom_field_attributes(_1) }
    end

    def custom_field_attributes(field)
      case field[:type]
      when CustomField::TYPE_TERMS then
        {
          label: "Terms and Conditions",
          value: link_to(field[:name], field[:name], target: "_blank").html_safe,
        }
      when CustomField::TYPE_CHECKBOX
        {
          label: field[:name],
          value: field[:value] ? "Yes" : "No",
        }
      else
        {
          label: field[:name],
          value: field[:value],
        }
      end
    end

    def refund_policy_attribute
      # gift.giftee_purchase doesn't have a copy of the refund policy, so it needs to be retrieved from the gifter_purchase
      refund_policy = purchase.is_gift_receiver_purchase ? purchase.gift.gifter_purchase.purchase_refund_policy : purchase.purchase_refund_policy
      return unless refund_policy.present?

      {
        label: refund_policy.title,
        value: refund_policy.fine_print,
      }
    end

    def call_schedule_attribute
      return unless purchase.call.present?

      {
        label: "Call schedule",
        value: [purchase.call.formatted_time_range, purchase.call.formatted_date_range],
      }
    end

    def call_url_attribute
      return unless purchase.call&.call_url.present?

      {
        label: "Call link",
        value: purchase.call.call_url,
      }
    end

    def call_attributes
      [call_schedule_attribute, call_url_attribute].compact
    end

    def manage_subscription_note
      @_subscription_note ||= begin
        return if subscription.blank?
        return if purchase.is_gift_receiver_purchase && subscription.credit_card_id.blank?
        return gift_subscription_renewal_note if subscription.gift? && subscription.credit_card_id.blank?

        "You will be charged once #{recurrence_long_indicator(subscription.recurrence)}. If you would like to manage your membership you can visit #{link_to(
            "subscription settings",
            Rails.application.routes.url_helpers.manage_subscription_url(
              subscription.external_id,
              { host: UrlService.domain_with_protocol },
            ),
            target: "_blank"
          )}.".html_safe
      end
    end

    def gift_subscription_renewal_note
      "Note that #{purchase.giftee_name_or_email}’s membership will not automatically renew."
    end
end
