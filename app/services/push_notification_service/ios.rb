# frozen_string_literal: true

module PushNotificationService
  class Ios
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
      send_notification
    end

    def self.creator_app
      @_creator_app ||= RpushApnsAppService.new(name: Device::APP_TYPES[:creator]).first_or_create!
    end

    def self.consumer_app
      @_consumer_app ||= RpushApnsAppService.new(name: Device::APP_TYPES[:consumer]).first_or_create!
    end

    private
      def send_notification
        init_args = { app:,
                      device_token:,
                      alert:,
                      data: data_with_headers }
        init_args[:sound] = @sound if @sound.present?
        notification = Rpush::Apns2::Notification.new(init_args)
        notification.save!
      end

      def alert
        if body.present?
          {
            "title" => title,
            "body" => body
          }
        else
          title
        end
      end

      def creator_app?
        @app_type == Device::APP_TYPES[:creator]
      end

      def app
        creator_app? ? self.class.creator_app : self.class.consumer_app
      end

      def bundle_id
        creator_app? ? "com.GRD.iOSCreator" : "com.GRD.Gumroad"
      end

      def data_with_headers
        data.merge({ headers: { 'apns-topic': bundle_id } })
      end
  end
end
