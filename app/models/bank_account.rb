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

  def stripe_external_account_country
    country
  end

  def stripe_external_account_currency
    currency
  end

  def stripe_external_account_routing_number
    routing_number
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

  # The routing fields with the labels the payout form puts next to them, so a rejection can quote
  # back the value that was refused instead of leaving the seller to guess which box was wrong.
  #
  # Ordered aliases before the raw columns they alias: a country that calls branch_code its
  # "transit number" must be described that way once, not twice under both names.
  ROUTING_FIELD_LABELS = {
    transit_number: "transit number",
    institution_number: "institution number",
    bsb_number: "BSB",
    sort_code: "sort code",
    ifsc: "IFSC",
    clearing_code: "clearing code",
    bank_code: "bank code",
    branch_code: "branch code",
  }.freeze
  private_constant :ROUTING_FIELD_LABELS

  # ["bank code JSCLUZ22XXX", "branch code 00401"], or the bare routing number for the countries
  # that collect a single unlabelled value. Empty when there is nothing to name.
  def routing_field_descriptions
    described_columns = []
    descriptions = ROUTING_FIELD_LABELS.filter_map do |attribute, label|
      next unless respond_to?(attribute)

      value = public_send(attribute)
      next if value.blank?

      column = self.class.attribute_aliases[attribute.to_s] || attribute.to_s
      next unless described_columns.exclude?(column)

      described_columns << column
      "#{label} #{value}"
    end
    return descriptions if descriptions.any?

    routing_number.present? ? ["routing number #{routing_number}"] : []
  end

  # "bank code JSCLUZ22XXX and branch code 00401". Blank when nothing can be named, so callers can
  # append it to a rejection message without checking first.
  def routing_fields_sentence
    routing_field_descriptions.to_sentence
  end

  # True when the seller filled in a bank code AND a separate branch code, which is the shape that
  # makes "we couldn't find the bank" ambiguous: the bank code is usually right and the branch code
  # is the half that is refused, but nothing in the rejection says so.
  def has_separate_branch_code?
    respond_to?(:bank_code) && bank_code.present? && branch_code.present?
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
      ErrorNotifier.notify(e) unless e.message.to_s.include?("has been deleted and can no longer be used")
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
