# frozen_string_literal: true

require "test_helper"

class VideoFileTest < ActiveSupport::TestCase
  self.described_class = VideoFile



  context_ VideoFile, type: :model do
  test "schedules a job to analyze the file after creation" do
      video_file = create(:video_file)

      expect(AnalyzeFileWorker).to have_enqueued_sidekiq_job(video_file.id, VideoFile.name)
    end

  context_ "#url" do
  test "must startwith S3_BASE_URL" do
        video_file = build(:video_file)

        video_file.url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/video.mp4"
        video_file.validate
        expect(video_file.errors[:url]).to be_empty

        video_file.url = "https://example.com/video.mp4"
        video_file.validate
        expect(video_file.errors[:url]).to include("must be an S3 URL")
      end
    end

  context_ "#smil_xml" do
  test "returns properly formatted SMIL XML with signed cloudfront URL" do
        s3_key = "attachments/1234567890abcdef1234567890abcdef/original/myvideo.mp4"
        s3_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/1234567890abcdef1234567890abcdef/original/myvideo.mp4"
        signed_url = "https://cdn.example.com/signed-url-for-video.mp4"

        video_file = create(:video_file, url: s3_url)

        allow(video_file).to receive(:signed_cloudfront_url).with(s3_key, is_video: true).and_return(signed_url)

        expected_xml = <<~XML.strip
          <smil><body><switch><video src="#{signed_url}"/></switch></body></smil>
        XML

        expect(video_file.smil_xml).to eq(expected_xml)
      end
    end

  context_ "#set_filetype" do
  test "sets filetype based on the file extension" do
        video_file = create(:video_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/video.mp4", filetype: nil)
        expect(video_file.filetype).to eq("mp4")

        video_file.update!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/video.mov")
        expect(video_file.filetype).to eq("mov")

        video_file.update!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/video.webm")
        expect(video_file.filetype).to eq("webm")
      end
    end
  end
end
