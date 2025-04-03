# frozen_string_literal: true

module PushNotificationService
  class Android
    attr_reader :device_token, :title, :body, :data

    def initialize(device_token:, title:, body:, data: {}, app_type:, sound: nil)
      @device_token = device_token
      @title = title
      @body = body
      @data = data
      @app_type = app_type
      @sound = sound
    end

    def process
      return if Feature.inactive?(:send_notifications_to_android_devices)
      return if creator_app?

      send_notification
    end

    private
      def self.consumer_app
        @_consumer_app ||= RpushFcmAppService.new(name: Device::APP_TYPES[:consumer]).first_or_create!
      end

      def send_notification
        notification_args = { title:, body:, icon: "notification_icon" }.compact

        notification = Rpush::Fcm::Notification.new
        notification.app = app
        notification.alert = title
        notification.device_token = device_token
        notification.content_available = true

        if @sound.present?
          notification.sound = @sound
          notification_args[:channel_id] = "Purchases"
        end

        notification.notification = notification_args

        if consumer_app?
          notification.data = data.merge(message: title)
        end

        notification.save!
      end

      def creator_app?
        @app_type == Device::APP_TYPES[:creator]
      end

      def consumer_app?
        @app_type == Device::APP_TYPES[:consumer]
      end

      def app
        self.class.consumer_app
      end
  end
end
