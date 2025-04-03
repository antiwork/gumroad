# frozen_string_literal: true

require "spec_helper"

describe ExpireStampedPdfsJob do
  describe "#perform" do
    it "marks old stamped pdfs as deleted" do
      record_1 = create(:stamped_pdf, created_at: 1.year.ago)
      record_2 = create(:stamped_pdf, created_at: 1.day.ago)

      described_class.new.perform
      expect(record_1.reload.deleted?).to be(true)
      expect(record_2.reload.deleted?).to be(false)
    end
  end
end
