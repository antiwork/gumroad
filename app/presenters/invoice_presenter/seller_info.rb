# frozen_string_literal: true

class InvoicePresenter::SellerInfo
  include ActionView::Helpers::TextHelper

  def initialize(chargeable)
    @chargeable = chargeable
    @seller = chargeable.seller
  end

  def heading
    "Creator"
  end

  def attributes
    seller_attributes
  end

  private
    attr_reader :chargeable, :seller

    def seller_attributes
      @_seller_attributes ||= [
        seller_title_attribute,
        seller_email_attribute,
      ]
    end

    def seller_title_attribute
      {
        label: nil,
        value: seller.display_name,
        link: seller.subdomain_with_protocol
      }
    end

    def seller_email_attribute
      {
        label: "Email",
        value: seller.support_or_form_email
      }
    end
end
