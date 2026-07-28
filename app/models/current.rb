# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  # buyer_currency_merchant_accounts memoizes seller_id => merchant account for the
  # buyer-currency display gate, so a page rendering many products of the same seller
  # resolves that seller's charging account once. Reset between requests by
  # CurrentAttributes, so a settings change is picked up on the next request.
  attribute :admin_actor, :admin_token, :buyer_currency_merchant_accounts
end
