# frozen_string_literal: true

require "test_helper"

class DeleteOldSentEmailInfoRecordsJobTest < ActiveSupport::TestCase
  self.described_class = DeleteOldSentEmailInfoRecordsJob



  context_ DeleteOldSentEmailInfoRecordsJob do
  context_ "#perform" do
  test "deletes targeted rows" do
        create(:sent_email_info, created_at: 3.years.ago)
        create(:sent_email_info, created_at: 2.years.ago)
        create(:sent_email_info, created_at: 6.months.ago)
        expect(SentEmailInfo.count).to eq(3)

        described_class.new.perform
        expect(SentEmailInfo.count).to eq(1)
      end

  test "does not fail when there are no records" do
        expect(described_class.new.perform).to eq(nil)
      end
    end
  end
end
