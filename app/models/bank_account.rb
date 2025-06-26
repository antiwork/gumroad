# frozen_string_literal: true

class BankAccount < ApplicationRecord
  include ExternalId
  include Deletable

  belongs_to :user, optional: true
  has_many :payments
  belongs_to :credit_card, optional: true

  encrypt_with_public_key :account_number,
                          symmetric: :never,
                          public_key: OpenSSL::PKey.read(GlobalConfig.get("STRONGBOX_GENERAL"),
                                                         GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).public_key,
                          private_key: GlobalConfig.get("STRONGBOX_GENERAL")

  alias_attribute :stripe_external_account_id, :stripe_bank_account_id

  validates_presence_of :user, :account_number, :account_number_last_four, :account_holder_full_name,
                        message: "We could not save your bank account information."

  after_create_commit :handle_stripe_bank_account
  after_create_commit :handle_compliance_info_request
  after_create :update_user_products_search_index

  # This state machine can be expanded once we implement a complex verification process.
  state_machine(:state, initial: :unverified) do
    event :mark_verified do
      transition unverified: :verified
    end
  end

  # Public: The routing transit number that is the identifier used to reference
  # the final destination institution/location where the funds will be delivered.
  # In some countries this will be the bank number (e.g. US), in others it will be
  # a combination of bank number and the branch code, or other fields.
  def routing_number
    bank_number
  end

  def account_number_visual
    "******#{account_number_last_four}"
  end

  def formatted_account
    "#{bank_name || routing_number} - #{account_number_visual}"
  end

  def bank_name
    nil
  end

  def country
    Compliance::Countries::USA.alpha2
  end

  def currency
    Currency::USD
  end

  def to_hash
    hash = {
      bank_number:,
      routing_number:,
      account_number: account_number_visual,
      bank_account_type:
    }
    hash[:bank_name] = bank_name if bank_name.present?
    hash
  end

  def mark_deleted!
    self.deleted_at = Time.current
    save!
  end

  def supports_instant_payouts?
    return false unless stripe_connect_account_id.present? && stripe_external_account_id.present?

    @supports_instant_payouts ||= begin
      external_account = Stripe::Account.retrieve_external_account(
        stripe_connect_account_id,
        stripe_external_account_id
      )

      external_account.available_payout_methods.include?("instant")
    rescue Stripe::StripeError => e
      Bugsnag.notify(e)
      false
    end
  end

  private
    def handle_stripe_bank_account
      HandleNewBankAccountWorker.perform_in(5.seconds, id)
    end

    def handle_compliance_info_request
      UserComplianceInfoRequest.handle_new_bank_account(self)
    end

    def account_number_decrypted
      account_number.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
    end

    def update_user_products_search_index
      return if user.bank_accounts.alive.count > 1
      user.products.find_each do |product|
        product.enqueue_index_update_for(["is_recommendable"])
      end
    end
end
