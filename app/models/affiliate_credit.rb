# frozen_string_literal: true

class AffiliateCredit < ApplicationRecord
  include Purchase::Searchable::AffiliateCreditCallbacks

  belongs_to :affiliate_user, class_name: "User"
  belongs_to :seller, class_name: "User"
  belongs_to :purchase
  belongs_to :link, optional: true
  belongs_to :affiliate, optional: true
  belongs_to :oauth_application, optional: true

  belongs_to :affiliate_credit_success_balance, class_name: "Balance", optional: true
  belongs_to :affiliate_credit_chargeback_balance, class_name: "Balance", optional: true
  belongs_to :affiliate_credit_refund_balance, class_name: "Balance", optional: true

  has_many :affiliate_partial_refunds

  validates :basis_points, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100_00 }
  validate :affiliate_or_oauth_application_present
  scope :paid, -> { not_refunded_or_chargebacked.where("affiliate_credit_success_balance_id IS NOT NULL") }
  scope :not_refunded_or_chargebacked, -> { where("affiliate_credit_refund_balance_id IS NULL AND " \
                             "affiliate_credit_chargeback_balance_id IS NULL")}

  def self.create!(purchase:, affiliate:, affiliate_amount_cents:, affiliate_fee_cents:, affiliate_balance:)
    affiliate_credit = new
    affiliate_credit.affiliate = affiliate
    affiliate_credit.amount_cents = affiliate_amount_cents
    affiliate_credit.fee_cents = affiliate_fee_cents
    affiliate_credit.basis_points = affiliate.basis_points(product_id: purchase.link_id)
    affiliate_credit.seller = purchase.seller
    affiliate_credit.affiliate_credit_success_balance = affiliate_balance
    affiliate_credit.affiliate_user = affiliate.affiliate_user
    affiliate_credit.purchase = purchase
    affiliate_credit.link = purchase.link
    affiliate_credit.save!
    affiliate_credit
  end

  def amount_partially_refunded_cents
    affiliate_partial_refunds.sum(:amount_cents)
  end

  def fee_partially_refunded_cents
    affiliate_partial_refunds.sum(:fee_cents)
  end

  private
    def affiliate_or_oauth_application_present
      return if affiliate.present? || oauth_application.present?

      errors.add(:base, "Either affiliate or oauth_application should be set on AffiliateCredit")
    end
end
