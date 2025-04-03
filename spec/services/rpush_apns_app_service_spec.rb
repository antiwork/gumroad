# frozen_string_literal: true

require "spec_helper"

describe RpushApnsAppService do
  let!(:app_name) { Device::APP_TYPES[:creator] }

  describe "#first_or_create!" do
    before do
      Rpush::Apns2::App.all.each(&:destroy)
    end

    context "when the record exists" do
      it "returns the record" do
        app = described_class.new(name: app_name).first_or_create!
        expect(Rpush::Apns2::App.where(name: app_name).size > 0).to be(true)

        expect do
          fetched_app = described_class.new(name: app_name).first_or_create!

          expect(fetched_app.id).to eq(app.id)
        end.to_not change { Rpush::Apns2::App.where(name: app_name).size }
      end
    end

    context "when the record does not exist" do
      it "creates and returns a new record" do
        expect do
          app = described_class.new(name: app_name).first_or_create!

          expect(app.environment).to eq("development")
          expect(app.certificate).to be_present
          expect(app.connections).to eq(1)
        end.to change { Rpush::Apns2::App.where(name: app_name).size }.by(1)
      end

      it "creates an app with environment production when the Rails environment is staging and returns it" do
        allow(Rails.env).to receive(:staging?).and_return(true)

        expect do
          app = described_class.new(name: app_name).first_or_create!

          expect(app.environment).to eq("production")
        end.to change { Rpush::Apns2::App.where(name: app_name).size }.by(1)
      end

      it "creates an app with environment production when the Rails environment is production and returns it" do
        allow(Rails.env).to receive(:production?).and_return(true)

        expect do
          app = described_class.new(name: app_name).first_or_create!

          expect(app.environment).to eq("production")
        end.to change { Rpush::Apns2::App.where(name: app_name).size }.by(1)
      end
    end
  end

  describe "#creator_app?" do
    it "returns correct app type" do
      expect(described_class.new(name: Device::APP_TYPES[:creator]).send(:creator_app?)).to be(true)
      expect(described_class.new(name: Device::APP_TYPES[:consumer]).send(:creator_app?)).to be(false)
    end
  end
end
