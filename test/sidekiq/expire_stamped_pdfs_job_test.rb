# frozen_string_literal: true

require "test_helper"

class ExpireStampedPdfsJobTest < ActiveSupport::TestCase
  self.described_class = ExpireStampedPdfsJob



  context_ ExpireStampedPdfsJob do
  context_ "#perform" do
  test "marks old stamped pdfs as deleted" do
        record_1 = create(:stamped_pdf, created_at: 1.year.ago)
        record_2 = create(:stamped_pdf, created_at: 1.day.ago)

        described_class.new.perform
        expect(record_1.reload.deleted?).to be(true)
        expect(record_2.reload.deleted?).to be(false)
      end
    end
  end
end
