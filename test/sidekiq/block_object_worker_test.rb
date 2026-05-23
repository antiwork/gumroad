# frozen_string_literal: true

require "test_helper"

class BlockObjectWorkerTest < ActiveSupport::TestCase
  self.described_class = BlockObjectWorker


  context_ BlockObjectWorker do
  context_ "#perform" do
      let(:admin_user) { create(:admin_user) }

  context_ "when blocking email domain" do
        let(:identifier) { "example.com" }

  test "blocks email domains without expiration" do
          expect(PlatformBlock.email_domain.count).to eq(0)
          described_class.new.perform("email_domain", identifier, admin_user.id)

          expect(PlatformBlock.email_domain.count).to eq(1)
          blocked_object = PlatformBlock.active.find_by(object_value: identifier)
          expect(blocked_object.object_value).to eq("example.com")
          expect(blocked_object.blocked_by).to eq(admin_user.id)
          expect(blocked_object.expires_at).to be_nil
        end
      end

  context_ "when blocking IP address" do
        let(:identifier) { "172.0.0.1" }

  test "blocks IP address with expiration" do
          expect(PlatformBlock.ip_address.count).to eq(0)
          described_class.new.perform("ip_address", identifier, admin_user.id, PlatformBlock::IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS.months.to_i)

          expect(PlatformBlock.ip_address.count).to eq(1)
          blocked_object = PlatformBlock.active.find_by(object_value: identifier)
          expect(blocked_object.object_value).to eq("172.0.0.1")
          expect(blocked_object.blocked_by).to eq(admin_user.id)
          expect(blocked_object.expires_at).to be_present
        end
      end
    end
  end
end
