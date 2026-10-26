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
end
