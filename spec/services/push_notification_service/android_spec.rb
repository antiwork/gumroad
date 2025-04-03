# frozen_string_literal: true

require "spec_helper"

describe PushNotificationService::Android do
  before do
    Feature.activate(:send_notifications_to_android_devices)
  end

  describe "consumer app" do
    context "when notification sound is passed" do
      it "creates a FCM notification with sound" do
        app = double("fcm_app")
        allow(PushNotificationService::Android).to receive(:consumer_app).and_return(app)

        device_token = "ABC"
        title = "Test"
        body = "Test body"
        sound = Device::NOTIFICATION_SOUNDS[:sale]

        notification = double("fcm_notification")
        expect(Rpush::Fcm::Notification).to receive(:new).and_return(notification)
        expect(notification).to receive(:app=).with(app)
        expect(notification).to receive(:alert=).with(title)
        expect(notification).to receive(:device_token=).with(device_token)
        expect(notification).to receive(:content_available=).with(true)
        expect(notification).to receive(:sound=).with(sound)
        expect(notification).to receive(:notification=).with({ title: title, body: body, icon: "notification_icon", channel_id: "Purchases" })
        expect(notification).to receive(:data=).with({ message: title })
        expect(notification).to receive(:save!)

        PushNotificationService::Android.new(device_token: device_token, title: title, body: body, app_type: Device::APP_TYPES[:consumer], sound: sound).process
      end
    end

    context "when notification sound is not passed" do
      it "creates a FCM notification without sound" do
        app = double("fcm_app")
        allow(PushNotificationService::Android).to receive(:consumer_app).and_return(app)

        device_token = "ABC"
        title = "Test"
        body = "Test body"

        notification = double("fcm_notification")
        expect(Rpush::Fcm::Notification).to receive(:new).and_return(notification)
        expect(notification).to receive(:app=).with(app)
        expect(notification).to receive(:alert=).with(title)
        expect(notification).to receive(:device_token=).with(device_token)
        expect(notification).to receive(:content_available=).with(true)
        expect(notification).to receive(:notification=).with({ title: title, body: body, icon: "notification_icon" })
        expect(notification).to receive(:data=).with({ message: title })
        expect(notification).to receive(:save!)

        PushNotificationService::Android.new(device_token: device_token, title: title, body: body, app_type: Device::APP_TYPES[:consumer]).process
      end
    end
  end
end
