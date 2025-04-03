# frozen_string_literal: true

require "spec_helper"

describe RpushFcmAppService do
  let!(:app_name) { Device::APP_TYPES[:consumer] }

  describe "#first_or_create!" do
    before do
      Rpush::Fcm::App.all.each(&:destroy)
      Modis.with_connection do |redis|
        redis.flushdb
      end
    end

    context "when the record exists" do
      it "returns the record" do
        app = described_class.new(name: app_name).first_or_create!
        expect(Rpush::Fcm::App.where(name: app_name).size > 0).to be(true)

        expect do
          fetched_app = described_class.new(name: app_name).first_or_create!

          expect(fetched_app.id).to eq(app.id)
        end.to_not change { Rpush::Fcm::App.where(name: app_name).size }
      end
    end

    context "when the record does not exist" do
      it "creates and returns a new record" do
        expect do
          app = described_class.new(name: app_name).first_or_create!

          expect(app.connections).to eq(1)
        end.to change { Rpush::Fcm::App.where(name: app_name).size }.by(1)
      end

      it "creates the Rpush::Fcm::App instance with correct params" do
        json_key = GlobalConfig.get("RPUSH_CONSUMER_FCM_JSON_KEY")
        firebase_project_id = GlobalConfig.get("RPUSH_CONSUMER_FCM_FIREBASE_PROJECT_ID")

        expect(Rpush::Fcm::App).to receive(:new).with(
          name: app_name,
          json_key: json_key,
          firebase_project_id: firebase_project_id,
          connections: 1
        ).and_call_original

        described_class.new(name: app_name).first_or_create!
      end
    end
  end
end
