# frozen_string_literal: true

describe BlockObjectWorker do
  describe "#perform" do
    let(:admin_user) { create(:admin_user) }

    context "when blocking email domain" do
      let(:identifier) { "example.com" }

      it "blocks email domains without expiration" do
        expect(BlockedObject.email_domain.count).to eq(0)
        described_class.new.perform("email_domain", identifier, admin_user.id)

        expect(BlockedObject.email_domain.count).to eq(1)
        blocked_object = BlockedObject.active.find_by(object_value: identifier)
        expect(blocked_object.object_value).to eq("example.com")
        expect(blocked_object.blocked_by).to eq(admin_user.id)
        expect(blocked_object.expires_at).to be_nil
      end
    end

    context "when blocking IP address" do
      let(:identifier) { "172.0.0.1" }

      it "blocks IP address with expiration" do
        expect(BlockedObject.ip_address.count).to eq(0)
        described_class.new.perform("ip_address", identifier, admin_user.id, BlockedObject::IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS.months.to_i)

        expect(BlockedObject.ip_address.count).to eq(1)
        blocked_object = BlockedObject.active.find_by(object_value: identifier)
        expect(blocked_object.object_value).to eq("172.0.0.1")
        expect(blocked_object.blocked_by).to eq(admin_user.id)
        expect(blocked_object.expires_at).to be_present
      end
    end
  end
end
