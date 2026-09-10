# frozen_string_literal: true

class UserTiktokIdentity < ApplicationRecord
  belongs_to :user

  validates :tiktok_open_id, presence: true
  validates :user_id, uniqueness: true
end
