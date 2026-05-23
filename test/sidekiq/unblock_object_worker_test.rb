# frozen_string_literal: true

require "test_helper"

class UnblockObjectWorkerTest < ActiveSupport::TestCase
  self.described_class = UnblockObjectWorker


  context_ UnblockObjectWorker do
  context_ "#perform" do
      let(:email_domain) { "example.com" }

  test "unblocks email domains" do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: email_domain)
        expect(PlatformBlock.active.email_domain.count).to eq(1)

        described_class.new.perform(email_domain)
        expect(PlatformBlock.active.email_domain.count).to eq(0)
      end

  test "unblocks every row sharing the object_value across types" do
        value = "shared@example.com"
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: value)
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: value)
        expect(PlatformBlock.active.where(object_value: value).count).to eq(2)

        described_class.new.perform(value)

        expect(PlatformBlock.active.where(object_value: value)).to be_empty
      end
    end
  end
end
