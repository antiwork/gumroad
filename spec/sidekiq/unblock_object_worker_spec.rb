# frozen_string_literal: true

describe UnblockObjectWorker do
  describe "#perform" do
    let(:email_domain) { "example.com" }

    it "unblocks email domains" do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], email_domain, nil)
      expect(BlockedObject.active.email_domain.count).to eq(1)

      described_class.new.perform(email_domain)
      expect(BlockedObject.active.email_domain.count).to eq(0)
    end
  end
end
