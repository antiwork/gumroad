# frozen_string_literal: true

class Refund < ApplicationRecord
  FRAUD = "fraud"

  include JsonData, FlagShihTzu

  belongs_to :user, foreign_key: :refunding_user_id, optional: true
  belongs_to :purchase
  belongs_to :product, class_name: "Link", foreign_key: :link_id
  belongs_to :seller, class_name: "User"
  has_many :balance_transactions
  has_one :credit

  before_validation :assign_product, on: :create
  before_validation :assign_seller, on: :create
  validates_uniqueness_of :processor_refund_id, scope: :link_id, allow_blank: true

  has_flags 1 => :is_for_fraud,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  # Refunds whose money actually left (or is leaving) our account. A "failed" refund is
  # one the buyer's bank returned after Stripe initially accepted it — the buyer never
  # received the money — so failed rows must not count toward how much of a purchase has
  # been refunded. status is NULL for refunds created before we started persisting
  # processor status, all of which completed, so NULL counts as effective.
  scope :effective, -> { where("refunds.status IS NULL OR refunds.status != 'failed'") }

  attr_json_data_accessor :note
  attr_json_data_accessor :business_vat_id
  attr_json_data_accessor :debited_stripe_transfer
  attr_json_data_accessor :retained_fee_cents
  attr_json_data_accessor :presentment_currency
  attr_json_data_accessor :presentment_amount_cents
  attr_json_data_accessor :presentment_price_cents
  attr_json_data_accessor :presentment_tip_cents
  attr_json_data_accessor :presentment_seller_tax_cents
  attr_json_data_accessor :presentment_gumroad_tax_cents
  attr_json_data_accessor :presentment_shipping_cents
  # Live-rate settlement facts from the Stripe refund balance transaction. Stripe converts
  # refunds at the live rate (not the locked FX quote rate), so the settled amount differs
  # from the amount originally settled for the charge; the delta against the canonical
  # balance debit is platform-side FX gain or loss. Persisted for treasury reconciliation.
  attr_json_data_accessor :presentment_settled_currency
  attr_json_data_accessor :presentment_settled_amount_cents
  # Set when a refund failed after acceptance (async bank-transfer refunds can be
  # returned by the buyer's bank) and Purchase::HandleFailedRefundService has offset
  # the balance debits this refund created. Guards the reversal against re-delivered
  # refund.failed webhooks.
  attr_json_data_accessor :balance_reversed_on_failure

  private
    def assign_product
      self.link_id = purchase.link_id
    end

    def assign_seller
      self.seller_id = purchase.seller_id
    end
end
