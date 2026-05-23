# frozen_string_literal: true

FactoryBot.define do
  factory :affiliate_partial_refund do
    affiliate_credit
    affiliate_user { affiliate_credit.affiliate_user }
    seller { affiliate_credit.seller }
    purchase { affiliate_credit.purchase }
    affiliate { affiliate_credit.affiliate }
    balance
  end
end
