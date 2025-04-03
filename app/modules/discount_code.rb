# frozen_string_literal: true

# DiscountCode is where all discounts for ServiceCharges are kept. They are broken into 2 types:
# cents & percentage just like OfferCodes. There is either an amount directly correlated to the type
# (e.g. type: :percentage, amount: 50 --> 50% off) or a function name which is used to calculate the
# amount and is used in accordance with the type. The reason for this is because invite_credit is based
# off of one month's black charge and there are 2 types of recurrence so we cannot set a fixed amount here
# and instead have to calculate it on the fly.
module DiscountCode
  INVITE_CREDIT_DISCOUNT_CODE = :invite_credit

  DISCOUNT_CODES = {
    invite_credit: { type: :cents, function: :invite_discount_amount }
  }.freeze
end
