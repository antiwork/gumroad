# frozen_string_literal: true

module PushNotificationService
  class Android
    attr_reader :device_token, :title, :body, :data

    # Builds from this version create the "sales" channel. Older ones only have "Purchases", which on
    # installs upgraded from the native app is stuck with a sound resource that no longer exists.
    SALES_CHANNEL_MIN_APP_VERSION = Gem::Version.new("2026.09.29")

    def initialize(device_token:, title:, body:, data: {}, app_type:, sound: nil, app_version: nil)
      @device_token = device_token
      @title = title
      @body = body
      @data = data
      @app_type = app_type
      @sound = sound
      @app_version = app_version
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
        tag = notification_tag
        notification_args = { title:, body:, icon: "notification_icon", tag: }.compact

        notification = Rpush::Fcm::Notification.new
        notification.app = app
        notification.alert = title
        notification.device_token = device_token
        notification.content_available = true

        if @sound.present?
          notification.sound = @sound
          notification_args[:channel_id] = sales_channel_id
        else
          notification_args[:channel_id] = "default"
        end

        notification.notification = notification_args

        if consumer_app?
          notification.data = data.merge("tag" => tag, "message" => title)
        end

        notification.save!
      end

      def notification_tag
        data["tag"].presence ||
          data["installment_id"].presence ||
          data["purchase_id"].presence ||
          data["subscription_id"].presence ||
          data["follower_id"].presence ||
          SecureRandom.uuid
      end

      def sales_channel_id
        return "Purchases" unless Gem::Version.correct?(@app_version.to_s)

        Gem::Version.new(@app_version) >= SALES_CHANNEL_MIN_APP_VERSION ? "sales" : "Purchases"
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
