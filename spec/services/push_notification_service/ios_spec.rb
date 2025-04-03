# frozen_string_literal: true

require "spec_helper"

describe PushNotificationService::Ios do
  describe "creator app" do
    it "creates an APNS notification" do
      app = double("apns_app")
      allow(PushNotificationService::Ios).to receive(:creator_app).and_return(app)

      device_token = "ABC"
      title = "Test"
      body = "Body"

      notification = double("apns_notification")
      expect(Rpush::Apns2::Notification).to receive(:new).with({
                                                                 app:,
                                                                 device_token:,
                                                                 alert: { "title" => title, "body" => body },
                                                                 sound: "chaching.wav",
                                                                 data: { headers: { "apns-topic": "com.GRD.iOSCreator" } }
                                                               }).and_return(notification)
      expect(notification).to receive(:save!)

      PushNotificationService::Ios.new(device_token:, title:, body:, app_type: Device::APP_TYPES[:creator], sound: Device::NOTIFICATION_SOUNDS[:sale]).process
    end
  end

  describe "consumer app" do
    context "when notification sound is passed" do
      it "creates an APNS notification" do
        app = double("apns_app")
        allow(PushNotificationService::Ios).to receive(:consumer_app).and_return(app)

        device_token = "ABC"
        title = "Test"
        body = "Body"

        notification = double("apns_notification")
        expect(Rpush::Apns2::Notification).to receive(:new).with({
                                                                   app:,
                                                                   device_token:,
                                                                   alert: { "title" => title, "body" => body },
                                                                   sound: "chaching.wav",
                                                                   data: { headers: { "apns-topic": "com.GRD.Gumroad" } }
                                                                 }).and_return(notification)
        expect(notification).to receive(:save!)

        PushNotificationService::Ios.new(device_token:, title:, body:, app_type: Device::APP_TYPES[:consumer], sound: Device::NOTIFICATION_SOUNDS[:sale]).process
      end
    end

    context "when notification sound is not passed" do
      it "creates an APNS notification" do
        app = double("apns_app")
        allow(PushNotificationService::Ios).to receive(:consumer_app).and_return(app)

        device_token = "ABC"
        title = "Test"
        body = "Body"

        notification = double("apns_notification")
        expect(Rpush::Apns2::Notification).to receive(:new).with({
                                                                   app:,
                                                                   device_token:,
                                                                   alert: { "title" => title, "body" => body },
                                                                   data: { headers: { "apns-topic": "com.GRD.Gumroad" } }
                                                                 }).and_return(notification)
        expect(notification).to receive(:save!)

        PushNotificationService::Ios.new(device_token:, title:, body:, app_type: Device::APP_TYPES[:consumer]).process
      end
    end

    context "empty body"  do
      it "sets proper alert message" do
        app = double("apns_app")
        allow(PushNotificationService::Ios).to receive(:consumer_app).and_return(app)

        device_token = "ABC"
        title = "Test"

        notification = double("apns_notification")
        expect(Rpush::Apns2::Notification).to receive(:new).with({
                                                                   app:,
                                                                   device_token:,
                                                                   alert: title,
                                                                   data: { headers: { "apns-topic": "com.GRD.Gumroad" } }
                                                                 }).and_return(notification)
        expect(notification).to receive(:save!)

        PushNotificationService::Ios.new(device_token:, title:, body: nil, app_type: Device::APP_TYPES[:consumer]).process
      end
    end
  end
end
