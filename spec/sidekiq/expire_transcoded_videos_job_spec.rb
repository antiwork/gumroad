# frozen_string_literal: true

require "spec_helper"

describe ExpireTranscodedVideosJob do
  describe "#perform" do
    it "marks old stamped pdfs as deleted" do
      $redis.set(RedisKey.transcoded_videos_recentness_limit_in_months, 3)
      record_1 = create(:transcoded_video, last_accessed_at: nil)
      record_2 = create(:transcoded_video, last_accessed_at: 10.days.ago)
      record_3 = create(:transcoded_video, last_accessed_at: 9.months.ago)

      described_class.new.perform
      expect(record_1.reload.deleted?).to be(false)
      expect(record_1.product_file.reload.is_transcoded_for_hls?).to be(true)
      expect(record_2.reload.deleted?).to be(false)
      expect(record_2.product_file.reload.is_transcoded_for_hls?).to be(true)
      expect(record_3.reload.deleted?).to be(true)
      expect(record_3.product_file.reload.is_transcoded_for_hls?).to be(false)
    end
  end
end
