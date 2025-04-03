# frozen_string_literal: true

class CommunityNotificationSetting < ApplicationRecord
  belongs_to :user
  belongs_to :seller, class_name: "User"

  validates :user_id, uniqueness: { scope: :seller_id }

  enum :recap_frequency, { daily: "daily", weekly: "weekly" }, prefix: true, validate: { allow_nil: true }
end
