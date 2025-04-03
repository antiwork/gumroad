# frozen_string_literal: true

class Device < ApplicationRecord
  DEVICE_TYPES = {
    ios: "ios",
    android: "android"
  }

  APP_TYPES = {
    consumer: "consumer",
    creator: "creator"
  }

  NOTIFICATION_SOUNDS = {
    sale: "chaching.wav"
  }

  belongs_to :user
  validates_presence_of :token
  validates :device_type, presence: true, inclusion: DEVICE_TYPES.values
  validates :app_type, presence: true, inclusion: APP_TYPES.values

  before_save :delete_token_if_already_linked_with_other_user

  private
    def delete_token_if_already_linked_with_other_user
      if token.present?
        Device.where(token:, device_type:).where.not(id:).destroy_all
      end
    end
end
