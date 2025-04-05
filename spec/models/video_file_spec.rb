# frozen_string_literal: true

require "spec_helper"

RSpec.describe VideoFile, type: :model do
  it "schedules a job to analyze the file after creation" do
    video_file = create(:video_file)

    expect(AnalyzeFileWorker).to have_enqueued_sidekiq_job(video_file.id, VideoFile.name)
  end

  describe "#url" do
    it "must startwith S3_BASE_URL" do
      video_file = build(:video_file)

      video_file.url = "#{S3_BASE_URL}/video.mp4"
      video_file.validate
      expect(video_file.errors[:url]).to be_empty

      video_file.url = "https://example.com/video.mp4"
      video_file.validate
      expect(video_file.errors[:url]).to include("must be an S3 URL")
    end
  end
end
