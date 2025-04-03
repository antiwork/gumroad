# frozen_string_literal: true

class ReceiptPresenter::ShippingInfo
  include ActionView::Helpers::TextHelper
  include CurrencyHelper

  def initialize(chargeable)
    @chargeable = chargeable
  end

  def title
    "Shipping info"
  end

  def attributes
    return [] unless chargeable.require_shipping?

    [
      to_attribute,
      address_attribute
    ]
  end

  def present?
    attributes.present?
  end

  private
    attr_reader :chargeable

    def to_attribute
      {
        label: "Shipping to",
        value: chargeable.full_name,
      }
    end

    def address_attribute
      {
        label: "Shipping address",
        value: safe_join(
          [
            chargeable.street_address,
            "#{ chargeable.city }, #{ chargeable.state } #{ chargeable.zip_code }",
            chargeable.country
          ],
          tag.br
        ),
      }
    end
end
