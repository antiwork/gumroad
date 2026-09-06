# frozen_string_literal: true

class UserInstagramIdentity < ApplicationRecord
  belongs_to :user

  validates :instagram_user_id, presence: true
  validates :user_id, uniqueness: true
end
