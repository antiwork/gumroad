# frozen_string_literal: true

class Charge < ApplicationRecord
  include ExternalId, Chargeable, Purchase::ChargeEventsHandler, Disputable, FlagShihTzu, Refundable

  COMBINED_CHARGE_PREFIX = "CH-"

  belongs_to :order
  belongs_to :seller, class_name: "User"
  belongs_to :merchant_account, optional: true
  belongs_to :credit_card, optional: true
  has_many :charge_purchases, dependent: :destroy
  has_many :purchases, through: :charge_purchases, dependent: :destroy
  has_many :refunds, through: :purchases

  attr_accessor :charge_intent, :setup_future_charges

  has_flags 1 => :receipt_sent,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  delegate :full_name, :purchaser, to: :purchase_as_chargeable
  delegate :tax_label_with_creator_tax_info, to: :purchase_with_tax_as_chargeable, allow_nil: true
  delegate :purchase_sales_tax_info, to: :purchase_with_sales_tax_info_as_chargeable, allow_nil: true
  delegate :purchase_taxjar_info, to: :purchase_with_taxjar_info_as_chargeable, allow_nil: true
  delegate :street_address, :city, :state, :state_or_from_ip_address, :zip_code, :country, to: :purchase_with_address_as_chargeable

  def statement_description
    seller.name_or_username
  end

  def reference_id_for_charge_processors
    COMBINED_CHARGE_PREFIX + external_id
  end

  def id_with_prefix
    COMBINED_CHARGE_PREFIX + id.to_s
  end

  def update_processor_fee_cents!(processor_fee_cents:)
    return unless processor_fee_cents.present?

    transaction do
      update!(processor_fee_cents:)

      charged_purchases.each do |purchase|
        purchase_processor_fee_cents = (processor_fee_cents * (purchase.total_transaction_cents.to_f / amount_cents)).round
        purchase.update!(processor_fee_cents: purchase_processor_fee_cents)
      end
    end
  end

  def upload_invoice_pdf(pdf)
    purchase_as_chargeable.upload_invoice_pdf(pdf)
  end

  def successful_purchases
    purchases.all_success_states_including_test
  end

  def shipping_cents
    @_shipping_cents ||= successful_purchases.sum(&:shipping_cents)
  end

  def has_invoice?
    successful_purchases.any?(&:has_invoice?)
  end

  def country_name
    purchase_as_chargeable.country_or_ip_country
  end

  def update_charge_details_from_processor!(processor_charge)
    return unless processor_charge.present?

    self.processor = processor_charge.charge_processor_id
    self.payment_method_fingerprint = processor_charge.card_fingerprint
    self.processor_transaction_id = processor_charge.id
    self.processor_fee_cents = processor_charge.fee
    self.processor_fee_currency = processor_charge.fee_currency
    update_processor_fee_cents!(processor_fee_cents: processor_charge.fee)
    save!
  end

  # Avoids creating an endpoint for the charge invoice since the invoice is the same
  # for all purchases that belong to the same charge
  def invoice_url
    Rails.application.routes.url_helpers.new_purchase_invoice_url(
      purchase_as_chargeable.external_id,
      email: purchase_as_chargeable.email,
      host: UrlService.domain_with_protocol
    )
  end

  def taxable?
    purchase_with_tax_as_chargeable.present?
  end

  def multi_item_charge?
    @_is_multi_item_charge ||= successful_purchases.many?
  end

  def require_shipping?
    purchase_with_shipping_as_chargeable.present?
  end

  def is_direct_to_australian_customer?
    require_shipping? && country == Compliance::Countries::AUS.common_name
  end

  def taxed_by_gumroad?
    purchase_with_gumroad_tax_as_chargeable.present?
  end

  def refund_and_save!(refunding_user_id)
    transaction do
      successful_purchases.each do |purchase|
        purchase.refund_and_save!(refunding_user_id)
      end
    end
  end

  def refund_gumroad_taxes!(refunding_user_id:, note: nil, business_vat_id: nil)
    transaction do
      successful_purchases
        .select { _1.gumroad_tax_cents > 0 }.each do |purchase|
        purchase.refund_gumroad_taxes!(refunding_user_id:, note:, business_vat_id:)
      end
    end
  end

  def refund_for_fraud_and_block_buyer!(refunding_user_id)
    with_lock do
      successful_purchases.each do |purchase|
        purchase.refund_for_fraud!(refunding_user_id)
      end
      block_buyer!(blocking_user_id: refunding_user_id)
    end
  end

  def block_buyer!(blocking_user_id: nil, comment_content: nil)
    purchase_as_chargeable.block_buyer!(blocking_user_id:, comment_content:)
  end

  def sync_status_with_charge_processor(mark_as_failed: false)
    transaction do
      purchases.each do |purchase|
        purchase.sync_status_with_charge_processor(mark_as_failed:)
      end
    end
  end

  def external_id_for_invoice
    purchase_as_chargeable.external_id
  end

  def external_id_numeric_for_invoice
    purchase_as_chargeable.external_id_numeric.to_s
  end

  def country_or_ip_country
    purchase_with_address_as_chargeable.country.presence ||
    purchase_with_address_as_chargeable.ip_country
  end

  def purchases_requiring_stamping
    @_purchases_requiring_stamping ||= successful_purchases
      .select { _1.link.has_stampable_pdfs? && _1.url_redirect.present? }
      .reject { _1.url_redirect.is_done_pdf_stamping? }
  end

  def charged_using_stripe_connect_account?
    merchant_account&.is_a_stripe_connect_account?
  end

  def buyer_blocked?
    purchase_as_chargeable.buyer_blocked?
  end

  def receipt_email_info
    # Queries `email_info_charges` first to leverage the index since there is no `purchase_id` on the associated
    # `email_infos` record (`email_infos` has > 1b records, and relies on `purchase_id` index)
    EmailInfoCharge.includes(:email_info)
      .where(charge_id: id)
      .where(
        email_infos: {
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
          type: CustomerEmailInfo.name
        }
      )
      .last&.email_info
  end

  def first_purchase_for_subscription
    successful_purchases.includes(:subscription).detect { _1.subscription.present? }
  end

  def self.parse_id(id)
    id.starts_with?(Charge::COMBINED_CHARGE_PREFIX) ? id.sub(Charge::COMBINED_CHARGE_PREFIX, "") : id
  end

  private
    # At least one product must be taxable for the charge to be taxable.
    # For that, we need to find at least one purchase that was taxable.
    def purchase_with_tax_as_chargeable
      @_purchase_with_tax_as_chargeable ||= successful_purchases.select(&:was_purchase_taxable?).first
    end

    def purchase_with_sales_tax_info_as_chargeable
      @_purchase_with_sales_tax_info_as_chargeable ||= \
        successful_purchases.find { _1.purchase_sales_tax_info&.business_vat_id.present? } ||
        purchase_with_tax_as_chargeable
    end

    def purchase_with_taxjar_info_as_chargeable
      @_purchase_with_taxjar_info_as_chargeable ||= successful_purchases.find { _1.purchase_taxjar_info.present? }
    end

    # Used to determine if the charge requires shipping. It returns a purchase associated with a physical product
    # At least one product must require shipping for the charge to require shipping.
    def purchase_with_shipping_as_chargeable
      @_purchase_with_shipping_as_chargeable ||= successful_purchases.select(&:require_shipping?).first
    end

    # During checkout we collect partial address information that is used for generating the invoice
    # If the charge doesn't require shipping, we still want to use the partial address information
    # to generate the invoice
    def purchase_with_address_as_chargeable
      purchase_with_shipping_as_chargeable || purchase_as_chargeable
    end

    # To be used only when the data retrieved is present on ALL purchases
    def purchase_as_chargeable
      @_purchase_as_chargeable ||= successful_purchases.first
    end

    def purchase_with_gumroad_tax_as_chargeable
      @_purchase_with_gumroad_tax_as_chargeable ||= successful_purchases
        .select { _1.gumroad_tax_cents > 0 }
        .first
    end
end
