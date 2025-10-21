# frozen_string_literal: true

class MerchantAccount < ApplicationRecord
  include Deletable
  include ExternalId
  include JsonData
  include ChargeProcessable

  belongs_to :user, optional: true
  has_many :purchases
  has_many :credits
  has_many :balances
  has_many :balance_transactions
  has_many :charges

  attr_json_data_accessor :meta

  validates :charge_processor_id, presence: true
  validates :charge_processor_merchant_id, presence: true, if: -> { user && charge_processor_alive? }
  validates :charge_processor_merchant_id, uniqueness: { case_sensitive: true, message: "This account is already connected with another Gumroad account" }, allow_blank: true, if: proc { |ma| ma.is_a_gumroad_managed_stripe_account? }

  scope :charge_processor_alive, -> { where.not(charge_processor_alive_at: nil).where(charge_processor_deleted_at: nil) }
  scope :charge_processor_verified, -> { where.not(charge_processor_verified_at: nil) }
  scope :charge_processor_unverified, -> { where(charge_processor_verified_at: nil) }
  scope :charge_processor_deleted, -> { where.not(charge_processor_deleted_at: nil) }
  scope :paypal, -> { where(charge_processor_id: PaypalChargeProcessor.charge_processor_id) }
  scope :stripe, -> { where(charge_processor_id: StripeChargeProcessor.charge_processor_id) }
  scope :stripe_connect, -> { stripe.where("json_data->>'$.meta.stripe_connect' = 'true'").where.not(user_id: nil) } # Logic should match method `#is_a_stripe_connect_account?`

  # Public: Get Gumroad's merchant account on the charge processor.
  #
  # charge_processor_id – The charge processor to get a MerchantAccount for.
  #
  # Returns a MerchantAccount which is Gumroad's merchant account on the given charge processor.
  def self.gumroad(charge_processor_id)
    where(user_id: nil, charge_processor_id:).first
  end

  def is_managed_by_gumroad?
    !user_id
  end

  def can_accept_charges?
    !stripe_charge_processor? ||
        is_a_stripe_connect_account? ||
        Country.new(country).can_accept_stripe_charges?
  end

  # Logic should match `.stripe_connect` scope
  def is_a_stripe_connect_account?
    stripe_charge_processor? &&
        user_id.present? &&
        json_data.dig("meta", "stripe_connect") == "true"
  end

  def is_a_brazilian_stripe_connect_account?
    is_a_stripe_connect_account? && country == Compliance::Countries::BRA.alpha2
  end

  def is_a_paypal_connect_account?
    paypal_charge_processor?
  end

  def is_a_gumroad_managed_stripe_account?
    stripe_charge_processor? && json_data.dig("meta", "stripe_connect") != "true"
  end

  # Public: Returns who holds the funds for charges created for this merchant account.
  def holder_of_funds
    if charge_processor_id.in?(ChargeProcessor.charge_processor_ids)
      ChargeProcessor.holder_of_funds(self)
    else
      # Assume we hold the funds for removed charge processors
      HolderOfFunds::GUMROAD
    end
  end

  def delete_charge_processor_account!
    mark_deleted!
    self.meta = {} unless is_a_stripe_connect_account?
    self.charge_processor_deleted_at = Time.current
    self.charge_processor_alive_at = nil
    self.charge_processor_verified_at = nil
    save!
  end

  def charge_processor_delete!
    case charge_processor_id
    when StripeChargeProcessor.charge_processor_id
      StripeMerchantAccountManager.delete_account(self)
    else
      raise NotImplementedError
    end
  end

  def active?
    alive? && charge_processor_alive?
  end

  def charge_processor_alive?
    charge_processor_alive_at.present? && !charge_processor_deleted?
  end

  def charge_processor_verified?
    charge_processor_verified_at.present?
  end

  def charge_processor_unverified?
    charge_processor_verified_at.nil?
  end

  def charge_processor_deleted?
    charge_processor_deleted_at.present?
  end

  def mark_charge_processor_verified!
    return if charge_processor_verified?

    self.charge_processor_verified_at = Time.current
    save!
  end

  def mark_charge_processor_unverified!
    return if charge_processor_unverified?

    self.charge_processor_verified_at = nil
    save!
  end

  def paypal_account_details
    payment_integration_api = PaypalIntegrationRestApi.new(user, authorization_header: PaypalPartnerRestCredentials.new.auth_token)
    paypal_response = payment_integration_api.get_merchant_account_by_merchant_id(charge_processor_merchant_id)

    if paypal_response.success?
      parsed_response = paypal_response.parsed_response
      # Special handling for China as PayPal returns country code as C2 instead of CN
      parsed_response["country"] = "CN" if paypal_response["country"] == "C2"
      parsed_response
    end
  end
end
