# frozen_string_literal: true

describe UnblockObjectWorker do
  describe "#perform" do
    let(:email_domain) { "example.com" }

    it "unblocks email domains" do
      PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:email_domain], object_value: email_domain)
      expect(PlatformBlock.active.email_domain.count).to eq(1)

      described_class.new.perform(email_domain)
      expect(PlatformBlock.active.email_domain.count).to eq(0)
    end
  end
end
