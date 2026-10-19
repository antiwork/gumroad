# frozen_string_literal: true

# Rows that `destroy!` and `delete_all` leave behind when an example runs outside the fixture transaction:
# a user's global affiliate, seller profile and notes, a deleted product's prices, a deleted post's files.
module NonTransactionalLeftovers
  def delete_leftovers(user_ids:, product_ids: [], installment_ids: [])
    Price.where(link_id: product_ids).delete_all
    ProductFile.where(installment_id: installment_ids).delete_all
    Affiliate.where(affiliate_user_id: user_ids).delete_all
    SellerProfile.where(seller_id: user_ids).delete_all
    Comment.where(commentable_type: "User", commentable_id: user_ids).delete_all
  end
end

RSpec.configure do |config|
  config.include NonTransactionalLeftovers
end
