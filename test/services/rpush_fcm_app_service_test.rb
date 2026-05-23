# frozen_string_literal: true

require "test_helper"

class RpushFcmAppServiceTest < ActiveSupport::TestCase
  self.described_class = RpushFcmAppService



  context_ RpushFcmAppService do
    let!(:app_name) { Device::APP_TYPES[:consumer] }

  context_ "#first_or_create!" do
      before do
        Rpush::Fcm::App.all.each(&:destroy)
        Modis.with_connection do |redis|
          redis.flushdb
        end
      end

  context_ "when the record exists" do
  test "returns the record" do
          app = described_class.new(name: app_name).first_or_create!
          expect(Rpush::Fcm::App.where(name: app_name).size > 0).to be(true)

          expect do
            fetched_app = described_class.new(name: app_name).first_or_create!

            expect(fetched_app.id).to eq(app.id)
          end.not_to change { Rpush::Fcm::App.where(name: app_name).size }
        end
      end

  context_ "when the record does not exist" do
  test "creates and returns a new record" do
          expect do
            app = described_class.new(name: app_name).first_or_create!

            expect(app.connections).to eq(1)
          end.to change { Rpush::Fcm::App.where(name: app_name).size }.by(1)
        end

  test "creates the Rpush::Fcm::App instance with correct params" do
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
end
