# frozen_string_literal: true

class ConsumptionEvent < ApplicationRecord
  class << self
    def create_event!(**kwargs)
      ConsumptionEvent.create!(
        event_type: kwargs.fetch(:event_type),
        platform: kwargs.fetch(:platform),
        url_redirect_id: kwargs.fetch(:url_redirect_id),
        product_file_id: kwargs.fetch(:product_file_id, nil),
        purchase_id: kwargs.fetch(:purchase_id, nil),
        link_id: kwargs.fetch(:product_id, nil),
        folder_id: kwargs.fetch(:folder_id, nil),
        consumed_at: kwargs.fetch(:consumed_at, Time.current),
        ip_address: kwargs.fetch(:ip_address)
      )
    end

    def determine_platform(user_agent)
      return Platform::OTHER if user_agent.blank?
      return Platform::ANDROID if /android/i.match?(user_agent)
      return Platform::IPHONE if /iosbuyer/i.match?(user_agent)

      Platform::OTHER
    end
  end

  include Platform
  include TimestampScopes
  include JsonData

  EVENT_TYPES = %w[download download_all folder_download listen read view watch]
  EVENT_TYPES.each do |event_type|
    self.const_set("EVENT_TYPE_#{event_type.upcase}", event_type)
  end

  belongs_to :purchase, optional: true

  attr_json_data_accessor :folder_id
  attr_json_data_accessor :ip_address

  validates_presence_of :folder_id, if: -> { event_type == EVENT_TYPE_FOLDER_DOWNLOAD }
  validates_presence_of :url_redirect_id
  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :platform, inclusion: { in: Platform.all }
end
