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

  private
    def assign_product
      self.link_id = purchase.link_id
    end

    def assign_seller
      self.seller_id = purchase.seller_id
    end
end
