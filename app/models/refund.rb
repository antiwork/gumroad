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

  # True when this refund carries a buyer-currency (presentment) snapshot. Presentment
  # refunds record the amount actually returned to the buyer in the currency they paid
  # with; refunds created before that feature (or for non-presentment purchases) have
  # neither field and should keep rendering canonical USD amounts only.
  def presentment_snapshot?
    presentment_currency.present? && presentment_amount_cents.to_i > 0
  end

  # The refunded amount in the buyer's own currency, formatted for display
  # (e.g. "CA$28.83"). Nil when there is no presentment snapshot.
  def formatted_presentment_amount
    return nil unless presentment_snapshot?

    MoneyFormatter.format(presentment_amount_cents, presentment_currency.to_sym, no_cents_if_whole: true, symbol: true)
  end

  private
    def assign_product
      self.link_id = purchase.link_id
    end

    def assign_seller
      self.seller_id = purchase.seller_id
    end
end
