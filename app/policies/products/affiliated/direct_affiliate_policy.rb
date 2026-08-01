# frozen_string_literal: true

# Removal from the affiliate's own side. The mirror-image seller-side permission lives in
# DirectAffiliatePolicy#destroy?, which only lets the seller who added the affiliate remove them.
class Products::Affiliated::DirectAffiliatePolicy < ApplicationPolicy
  def destroy?
    user.role_admin_for?(seller) &&
    when_record_available { record.affiliate_user_id == seller.id }
  end
end
