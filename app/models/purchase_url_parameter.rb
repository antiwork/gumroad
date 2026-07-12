# frozen_string_literal: true

# Stores the custom query parameters the buyer had on the product URL at checkout
# (e.g. ?discord_id=x&plan=y), minus Gumroad's own reserved params. Sellers who
# deliver products through ping webhooks rely on getting these back as the ping's
# `url_params` field.
#
# This lives in its own table rather than on `purchases` because:
#   * the value must survive a database reload — asynchronous payment flows
#     (PayPal captures, webhook-driven status syncs) mark the purchase successful
#     on a freshly loaded Purchase, long after the checkout request ended, and
#     an in-memory attribute would be lost by then;
#   * `purchases.json_data` is a varchar(255), far too small for arbitrary
#     buyer-supplied params;
#   * the `purchases` table is too large to ALTER on the deploy path.
class PurchaseUrlParameter < ApplicationRecord
  belongs_to :purchase

  validates :params, presence: true
end
