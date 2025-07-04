# frozen_string_literal: true

class ServiceCharge < ApplicationRecord
  include CurrencyHelper
  include ActionView::Helpers::DateHelper
  include Mongoable
  include PurchaseErrorCode
  include DiscountCode
  include ExternalId
  include JsonData
  include TimestampScopes
  include Purchase::CardCountrySource
  include Rails.application.routes.url_helpers
  include FlagShihTzu

  attr_json_data_accessor :locale, default: -> { "en" }
  attr_json_data_accessor :card_country_source
  attr_json_data_accessor :chargeback_reason

  belongs_to :user, optional: true
  belongs_to :recurring_service, optional: true
  belongs_to :credit_card, optional: true
  belongs_to :merchant_account, optional: true

  has_one :dispute
  has_many :events

  # ServiceCharge state transitions:
  #
  # in_progress  →  successful
  #     ↓
  #   failed
  #
  # (DEPRECATED) Authorizations - these are to make sure the card can be charged prior to the free trial:
  #
  # in_progress  →  authorization_successful
  #      ↓
  # authorization_failed
  #
  state_machine :state, initial: :in_progress do
    event :mark_successful do
      transition in_progress: :successful
    end

    event :mark_failed do
      transition in_progress: :failed
    end

    event :mark_authorization_successful do
      transition in_progress: :authorization_successful
    end

    event :mark_authorization_failed do
      transition in_progress: :authorization_failed
    end
  end

  before_save :to_mongo

  validates_presence_of :user
  validates_associated :user
  validates :charge_cents, numericality: true, presence: true

  has_flags 1 => :chargeback_reversed,
            2 => :was_zip_code_check_performed,
            3 => :is_authorization_charge,
            4 => :is_automatic_charge,
            5 => :is_charge_by_admin,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  attr_accessor :chargeable, :card_data_handling_error, :perceived_charge_cents, :charge_intent

  delegate :email, :name, to: :user

  scope :in_progress, -> { where(state: "in_progress") }
  scope :successful, -> { where(state: "successful") }
  scope :authorization_successful, -> { where(state: "authorization_successful") }
  scope :successful_or_authorization_successful, -> { where("state = 'successful' OR state = 'authorization_successful'") }
  scope :failed, -> { where(state: "failed") }
  scope :charge_processor_failed, -> { failed.where("service_charges.charge_processor_fingerprint IS NOT NULL AND service_charges.charge_processor_fingerprint != ''") }
  scope :refunded, -> { successful.where("service_charges.charge_processor_refunded = 1") }
  scope :not_refunded, -> { where("service_charges.charge_processor_refunded = 0") }
  scope :chargedback, -> { successful.where("service_charges.chargeback_date IS NOT NULL") }
  scope :not_chargedback, -> { where("service_charges.chargeback_date IS NULL") }
  scope :created_after, ->(start_at = nil) { start_at ? where("service_charges.created_at > ?", start_at) : all }
  scope :created_before, ->(end_at = nil) { end_at ? where("service_charges.created_at < ?", end_at) : all }

  def as_json(options = {})
    {
      id: external_id,
      user_id: user.external_id,
      timestamp: "#{time_ago_in_words(created_at)} ago",
      created_at:,
      charge_cents:,
      formatted_charge:,
      refunded: refunded?,
      chargedback: chargedback?,
      card: {
        visual: card_visual,
        type: card_type,
        # legacy param
        bin: nil,
        expiry_month: card_expiry_month,
        expiry_year: card_expiry_year
      }
    }
  end

  def chargedback?
    chargeback_date.present?
  end

  def refunded?
    charge_processor_refunded
  end

  def formatted_charge
    MoneyFormatter.format(charge_cents, :usd, no_cents_if_whole: true, symbol: true)
  end

  def send_service_charge_receipt
    ServiceMailer.service_charge_receipt(id).deliver_later(queue: "critical", wait: 3.seconds)
  end

  def time_fields
    fields = attributes.keys.keep_if { |key| key.include?("_at") && send(key) }
    fields << "chargeback_date" if chargeback_date
    fields
  end

  def discount_amount
    discount = DiscountCode::DISCOUNT_CODES[discount_code.to_sym]
    amount = discount[:function] ? recurring_service.send(discount[:function]) : discount[:amount]

    if discount[:type] == :percentage
      old_total = charge_cents / (1 - amount / 100.0).round
      discount_cents = old_total - charge_cents
    elsif discount[:type] == :cents
      discount_cents = amount
    end

    MoneyFormatter.format(discount_cents, :usd, no_cents_if_whole: true, symbol: true)
  end

  def upload_invoice_pdf(pdf)
    timestamp = Time.current.strftime("%F")
    key = "#{Rails.env}/#{timestamp}/invoices/service_charges/#{external_id}-#{SecureRandom.hex}/invoice.pdf"

    s3_obj = Aws::S3::Resource.new.bucket(INVOICES_S3_BUCKET).object(key)
    s3_obj.put(body: pdf)
    s3_obj
  end
end
