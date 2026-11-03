# frozen_string_literal: true

# A Gumroad seller that a partner application brought over, keyed by the partner's own user ID.
# Partner API endpoints only ever expose sellers listed here for the calling application.
class PartnerSeller < ApplicationRecord
  include Deletable

  belongs_to :oauth_application
  belongs_to :user

  validates :external_user_id, presence: true, length: { maximum: 255 }
  validates :external_user_id, uniqueness: { scope: :oauth_application_id }
  validates :user_id, uniqueness: { scope: :oauth_application_id }

  class LinkConflict < StandardError; end

  # Links `user` to the partner's user ID, or restores a link that was removed. Raises LinkConflict
  # when either side is already linked to another account. The caller holds the application's lock.
  def self.link!(oauth_application:, user:, external_user_id:)
    partner_sellers = oauth_application.partner_sellers
    by_external_user = partner_sellers.find_by(external_user_id:)
    by_user = partner_sellers.find_by(user:)

    if by_external_user&.user_id.present? && by_external_user.user_id != user.id
      raise LinkConflict, "This #{oauth_application.name} account is already linked to a different Gumroad account."
    end
    if by_user.present? && by_user.external_user_id != external_user_id
      raise LinkConflict, "Your Gumroad account is already linked to a different #{oauth_application.name} account."
    end

    partner_seller = by_user || partner_sellers.build(user:, external_user_id:)
    partner_seller.deleted_at = nil
    partner_seller.save!
    partner_seller
  end
end
