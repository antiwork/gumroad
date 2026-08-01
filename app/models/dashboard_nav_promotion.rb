# frozen_string_literal: true

# One row per dashboard destination a user has used, plus one marker row per seeded user. Written
# only by User::DashboardNavItems, and only ever inserted — see that module for why this is not a
# users.json_data key.
class DashboardNavPromotion < ApplicationRecord
  belongs_to :user

  validates :nav_item, presence: true, uniqueness: { scope: :user_id }
end
