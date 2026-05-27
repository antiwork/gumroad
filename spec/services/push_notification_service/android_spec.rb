# frozen_string_literal: true

require "spec_helper"

describe PushNotificationService::Android do
  before do
    Feature.activate(:send_notifications_to_android_devices)
  end

  describe "consumer app" do
    context "when notification sound is passed" do
      it "creates a FCM notification with sound and the Purchases channel" do
        app = double("fcm_app")
        allow(PushNotificationService::Android).to receive(:consumer_app).and_return(app)

        device_token = "ABC"
        title = "Test"
        body = "Test body"
        sound = Device::NOTIFICATION_SOUNDS[:sale]
        data = { "purchase_id" => "abcd1234" }

        notification = double("fcm_notification")
        expect(Rpush::Fcm::Notification).to receive(:new).and_return(notification)
        expect(notification).to receive(:app=).with(app)
        expect(notification).to receive(:alert=).with(title)
        expect(notification).to receive(:device_token=).with(device_token)
        expect(notification).to receive(:content_available=).with(true)
        expect(notification).to receive(:sound=).with(sound)
        expect(notification).to receive(:notification=).with(
          { title: title, body: body, icon: "notification_icon", tag: "abcd1234", channel_id: "Purchases" }
        )
        expect(notification).to receive(:data=).with({ "purchase_id" => "abcd1234", "tag" => "abcd1234", "message" => title })
        expect(notification).to receive(:save!)

        PushNotificationService::Android.new(device_token: device_token, title: title, body: body, data: data, app_type: Device::APP_TYPES[:consumer], sound: sound).process
      end
    end

    context "when notification sound is not passed" do
      it "creates a FCM notification without sound and the default channel" do
        app = double("fcm_app")
        allow(PushNotificationService::Android).to receive(:consumer_app).and_return(app)

        device_token = "ABC"
        title = "Test"
        body = "Test body"
        data = { "installment_id" => "post-xyz" }

        notification = double("fcm_notification")
        expect(Rpush::Fcm::Notification).to receive(:new).and_return(notification)
        expect(notification).to receive(:app=).with(app)
        expect(notification).to receive(:alert=).with(title)
        expect(notification).to receive(:device_token=).with(device_token)
        expect(notification).to receive(:content_available=).with(true)
        expect(notification).to receive(:notification=).with(
          { title: title, body: body, icon: "notification_icon", tag: "post-xyz", channel_id: "default" }
        )
        expect(notification).to receive(:data=).with({ "installment_id" => "post-xyz", "tag" => "post-xyz", "message" => title })
        expect(notification).to receive(:save!)

        PushNotificationService::Android.new(device_token: device_token, title: title, body: body, data: data, app_type: Device::APP_TYPES[:consumer]).process
      end
    end

    describe "tag derivation" do
      let(:device_token) { "ABC" }
      let(:title) { "Test" }
      let(:body) { "Test body" }

      def capture_payload(data:)
        captured = {}
        notification = instance_double(Rpush::Fcm::Notification)
        allow(notification).to receive(:app=)
        allow(notification).to receive(:alert=)
        allow(notification).to receive(:device_token=)
        allow(notification).to receive(:content_available=)
        allow(notification).to receive(:sound=)
        allow(notification).to receive(:notification=) { |args| captured[:notification] = args }
        allow(notification).to receive(:data=) { |args| captured[:data] = args }
        allow(notification).to receive(:save!)
        allow(Rpush::Fcm::Notification).to receive(:new).and_return(notification)
        allow(PushNotificationService::Android).to receive(:consumer_app).and_return(double("fcm_app"))

        PushNotificationService::Android.new(
          device_token: device_token, title: title, body: body, data: data, app_type: Device::APP_TYPES[:consumer]
        ).process

        captured
      end

      it "prefers an explicit data['tag']" do
        payload = capture_payload(data: { "tag" => "explicit", "installment_id" => "fallback" })
        expect(payload[:notification][:tag]).to eq("explicit")
        expect(payload[:data]["tag"]).to eq("explicit")
      end

      it "uses installment_id when no explicit tag is set" do
        payload = capture_payload(data: { "installment_id" => "post-1", "purchase_id" => "buy-1" })
        expect(payload[:notification][:tag]).to eq("post-1")
        expect(payload[:data]["tag"]).to eq("post-1")
      end

      it "falls back through purchase_id, subscription_id, follower_id" do
        expect(capture_payload(data: { "purchase_id" => "p1" })[:data]["tag"]).to eq("p1")
        expect(capture_payload(data: { "subscription_id" => "s1" })[:data]["tag"]).to eq("s1")
        expect(capture_payload(data: { "follower_id" => "f1" })[:data]["tag"]).to eq("f1")
      end

      it "generates unique tags per message when no identifier is provided" do
        first = capture_payload(data: {})
        second = capture_payload(data: {})
        expect(first[:data]["tag"]).to be_present
        expect(second[:data]["tag"]).to be_present
        expect(first[:data]["tag"]).not_to eq(second[:data]["tag"])
      end

      it "emits distinct tags for two news-update pushes about different installments" do
        first = capture_payload(data: { "installment_id" => "post-a" })
        second = capture_payload(data: { "installment_id" => "post-b" })
        expect(first[:notification][:tag]).to eq("post-a")
        expect(second[:notification][:tag]).to eq("post-b")
        expect(first[:data]["tag"]).not_to eq(second[:data]["tag"])
      end
    end
  end

  describe "creator app" do
    it "does not send a notification" do
      expect(Rpush::Fcm::Notification).not_to receive(:new)

      PushNotificationService::Android.new(
        device_token: "ABC", title: "Test", body: "Body", app_type: Device::APP_TYPES[:creator]
      ).process
    end
  end
end
