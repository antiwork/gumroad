# frozen_string_literal: true

class AffiliatePartialRefund < ApplicationRecord
  include Purchase::Searchable::AffiliatePartialRefundCallbacks

  belongs_to :affiliate_user, class_name: "User", optional: true
  belongs_to :affiliate_credit, optional: true
  belongs_to :seller, class_name: "User", optional: true
  belongs_to :purchase, optional: true
  belongs_to :affiliate, optional: true
  belongs_to :balance, optional: true

  validates_presence_of :affiliate_user, :affiliate_credit, :seller, :purchase, :affiliate, :balance
end
