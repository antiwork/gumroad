# frozen_string_literal: true

describe BlockEmailDomainsWorker do
  describe "#perform" do
    let(:admin_user) { create(:admin_user) }
    let(:email_domains) { ["example.com", "example.org"] }

    it "blocks email domains without expiration" do
      expect(BlockedObject.email_domain.count).to eq(0)
      described_class.new.perform(admin_user.id, email_domains)

      expect(BlockedObject.email_domain.count).to eq(2)
      blocked_object = BlockedObject.active.find_by(object_value: "example.com")
      expect(blocked_object.blocked_by).to eq(admin_user.id)
      expect(blocked_object.expires_at).to be_nil
    end
  end
end
