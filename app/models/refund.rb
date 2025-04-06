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

  # Keep retained_fee_cents_value in sync with the json_data
  before_save :sync_retained_fee_cents_value, if: :has_column_retained_fee_cents_value?

  def retained_fee_cents=(value)
    super(value)
    self.retained_fee_cents_value = value if has_column_retained_fee_cents_value?
  end

  # Returns the retained_fee_cents value, preferring the column over json_data if available
  def retained_fee_cents
    if has_column_retained_fee_cents_value? && retained_fee_cents_value.present?
      retained_fee_cents_value
    else
      super
    end
  end

  private
    def assign_product
      self.link_id = purchase.link_id
    end

    def assign_seller
      self.seller_id = purchase.seller_id
    end

    def sync_retained_fee_cents_value
      # Keep the column in sync with json_data
      self.retained_fee_cents_value = super_retained_fee_cents
    end

    # Check if the retained_fee_cents_value column exists in the database
    def has_column_retained_fee_cents_value?
      @has_column_retained_fee_cents_value ||= self.class.column_names.include?('retained_fee_cents_value')
    end

    # Store the original method to access it later
    alias_method :super_retained_fee_cents, :retained_fee_cents
end
