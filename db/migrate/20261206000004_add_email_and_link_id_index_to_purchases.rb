# frozen_string_literal: true

class AddEmailAndLinkIdIndexToPurchases < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # The mobile library endpoints (Api::Mobile::PurchasesController#search /
    # #index) serialize each purchase's product-updates feed, and posts with
    # "hasn't bought X" targeting run an existence probe of the shape:
    #
    #   SELECT 1 FROM purchases
    #   WHERE seller_id = ? AND link_id = ? AND email = ? AND <flag predicates>
    #   LIMIT 1
    #
    # MySQL was driving this off the single-column seller_id index and then
    # scanning that seller's entire purchase history to check link_id/email —
    # instant for small sellers, 7-12 seconds per probe for mega-sellers
    # (antiwork/gumroad#6009: two such probes were 19.9s of a 22.0s request).
    #
    # A composite (email, link_id) index lets the optimizer satisfy both
    # equality predicates directly, reducing the probe to a handful of row
    # lookups regardless of how large the seller is. Email leads because it is
    # the most selective predicate and also serves existing email-only lookups
    # if the optimizer prefers this index over index_purchases_on_email_long.
    # The 191-character prefix matches that existing email index (the column is
    # TEXT, so a prefix length is required, and 191 keeps it within the 767-byte
    # InnoDB key limit under utf8mb4).
    add_index :purchases, [:email, :link_id],
              name: "index_purchases_on_email_and_link_id",
              length: { email: 191 }
  end
end
