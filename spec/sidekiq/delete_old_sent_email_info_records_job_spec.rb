# frozen_string_literal: true

require "spec_helper"

describe DeleteOldSentEmailInfoRecordsJob do
  describe "#perform" do
    it "deletes targeted rows" do
      create(:sent_email_info, created_at: 3.years.ago)
      create(:sent_email_info, created_at: 2.years.ago)
      create(:sent_email_info, created_at: 6.months.ago)
      expect(SentEmailInfo.count).to eq(3)

      described_class.new.perform
      expect(SentEmailInfo.count).to eq(1)
    end

    it "does not fail when there are no records" do
      expect(described_class.new.perform).to eq(nil)
    end
  end
end
