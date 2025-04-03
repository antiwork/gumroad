# frozen_string_literal: true

require "spec_helper"

describe DeleteOldVersionsRecordsWorker, :versioning do
  describe "#perform" do
    it "deletes targeted rows" do
      stub_const("#{described_class}::MAX_ALLOWED_ROWS", 8)
      stub_const("#{described_class}::DELETION_BATCH_SIZE", 1)
      create_list(:user, 10)
      # Deletes 10 versions for the users and 10 versions for the refund policies
      expect(PaperTrail::Version.count).to eq(20)

      described_class.new.perform
      expect(PaperTrail::Version.count).to eq(8)
    end

    it "does not fail when there are no version records" do
      expect(described_class.new.perform).to eq(nil)
    end
  end
end
