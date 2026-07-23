# frozen_string_literal: true

class AddEmailAndSellerIdIndexToPurchases < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # The mobile library endpoints (Api::Mobile::PurchasesController#search /
    # #index) serialize each purchase's product-updates feed. Posts with
    # seller-level "hasn't bought X" targeting, and installment lookups, run
    # existence probes of the shape:
    #
    #   SELECT 1 FROM purchases
    #   WHERE email = ? AND seller_id = ? AND purchase_state IN (...) AND ...
    #   LIMIT 1
    #
    # These probes run once per distinct seller in the buyer's library
    # (WithFiltering#seller_post_passes_filters memoizes per seller, and
    # Installment.missed_for_purchase issues one per purchase's seller), so a
    # buyer whose library spans 24 sellers pays for 24 of them per request.
    # With only the single-column email index available
    # (index_purchases_on_email_long), MySQL fetches EVERY purchase row for
    # that email and then filters by seller — ~115ms per probe, ~2.8s of an
    # 8.6s request in the worst post-deploy Sentry sample
    # (antiwork/gumroad#6185, the follow-up to #6123/#6158 which fixed the
    # per-product probe shape with an (email, link_id) index).
    #
    # A composite (email, seller_id) index satisfies both equality predicates
    # directly, reducing each probe to a handful of row lookups regardless of
    # library size. Email leads, mirroring index_purchases_on_email_and_link_id.
    # The 191-character prefix matches the existing email indexes (the column
    # is TEXT, so a prefix length is required, and 191 keeps it within the
    # 767-byte InnoDB key limit under utf8mb4).
    add_index :purchases, [:email, :seller_id],
              name: "index_purchases_on_email_and_seller_id",
              length: { email: 191 }
  end
end
