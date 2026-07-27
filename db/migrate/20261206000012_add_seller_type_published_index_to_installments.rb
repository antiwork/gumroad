# frozen_string_literal: true

class AddSellerTypePublishedIndexToInstallments < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # The mobile library endpoints (Api::Mobile::PurchasesController#search /
    # #index) build each buyer's product-updates feed through
    # Purchase.product_installments, which asks for every profile-only post a
    # seller has published:
    #
    #   SELECT ... FROM installments
    #   WHERE seller_id = ? AND installment_type = 'seller'
    #     AND published_at IS NOT NULL AND deleted_at IS NULL
    #     AND <flag predicates>
    #
    # The only index that starts with seller_id today is
    # (seller_id, link_id), and this query has no link_id predicate, so MySQL
    # can only use the seller_id prefix (production EXPLAIN reports
    # key_len=5) and then re-checks the type, published and flag conditions
    # row by row. For a prolific seller that means reading about 1,392 rows to
    # keep roughly a dozen of them, and each row read drags along the post's
    # json_data column. In the seven slowest production samples of the mobile
    # library search endpoint this one query shape was 37% of the total time,
    # with single executions up to 4.7 seconds (gumroad-private#1412).
    #
    # Leading with (seller_id, installment_type) lets both equality
    # predicates be satisfied by the index, and published_at as the third
    # column turns "published_at IS NOT NULL" into a range on the same index
    # instead of a per-row check. The remaining flag predicates are bitwise
    # tests, which no B-tree index can serve, but they now run over the
    # seller's published seller-type posts only rather than their whole
    # history.
    #
    # installments is about 24 million rows and 3.2 GB of index, so this is
    # two orders of magnitude cheaper to add than the equivalent index on
    # purchases that was considered and rejected for the same endpoint in
    # antiwork/gumroad#6195.
    #
    # (seller_id, link_id) stays: it still serves the per-product lookups that
    # do filter on link_id, and neither index is a prefix of the other.
    add_index :installments, [:seller_id, :installment_type, :published_at],
              name: "index_installments_on_seller_id_and_type_and_published_at"
  end
end
