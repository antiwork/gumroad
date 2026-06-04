# frozen_string_literal: true

require "spec_helper"

describe OauthDeviceAuthorization do
  describe ".create_for!" do
    let(:oauth_application) { create(:oauth_application, scopes: "view_profile", confidential: false, device_authorization_enabled: true) }

    it "retries code collisions before creating the authorization" do
      attempts = 0
      allow(described_class).to receive(:create!) do |attributes|
        attempts += 1
        raise ActiveRecord::RecordNotUnique.new("collision") if attempts == 1

        described_class.new(attributes).tap(&:save!)
      end

      device_authorization, device_code, user_code = described_class.create_for!(
        oauth_application:,
        scopes: "view_profile",
        ip_address: "203.0.113.10",
        user_agent: "RSpec"
      )

      expect(attempts).to eq(2)
      expect(device_authorization).to be_persisted
      expect(described_class.find_by_device_code(device_code)).to eq(device_authorization)
      expect(described_class.find_by_user_code(user_code)).to eq(device_authorization)
    end

    it "raises after the maximum number of code collisions" do
      attempts = 0
      allow(described_class).to receive(:create!) do
        attempts += 1
        raise ActiveRecord::RecordNotUnique.new("collision")
      end

      expect do
        described_class.create_for!(
          oauth_application:,
          scopes: "view_profile",
          ip_address: "203.0.113.10",
          user_agent: "RSpec"
        )
      end.to raise_error(ActiveRecord::RecordNotUnique)

      expect(attempts).to eq(described_class::MAX_CODE_GENERATION_ATTEMPTS)
    end
  end
end
