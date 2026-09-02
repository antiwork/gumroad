# frozen_string_literal: true

class UserYoutubeIdentity < ApplicationRecord
  belongs_to :user

  validates :channel_id, presence: true
  validates :user_id, uniqueness: true
end
