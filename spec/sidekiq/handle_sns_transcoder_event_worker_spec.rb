# frozen_string_literal: true

require "spec_helper"

describe HandleSnsTranscoderEventWorker do
  describe "#perform" do
    before do
      @product = create(:product)
      @product.product_files << create(:product_file, link: @product,
                                                      url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/files/43a5363194e74e9ee75b6203eaea6705/original/test.mp4",
                                                      filegroup: "video", width: 640, height: 360, bitrate: 3_000)
    end

    it "marks the transcoded_video object as completed", :vcr do
      travel_to(Time.current) do
        TranscodeVideoForStreamingWorker.new.perform(@product.product_files.last.id, ProductFile.name)

        expect(TranscodedVideo.last.state).to eq "processing"

        TranscodedVideo.all.each do |transcoded_video|
          webhook_params = {
            "Type" => "Notification",
            "Message" => "{\"state\" : \"COMPLETED\", \"jobId\": \"#{transcoded_video.job_id}\"}"
          }
          described_class.new.perform(webhook_params)
        end

        expect(TranscodedVideo.last.state).to eq "completed"
      end
    end

    it "marks the transcoded_video object as failed", :vcr do
      product_file_id = @product.product_files.last.id
      TranscodeVideoForStreamingWorker.new.perform(product_file_id, ProductFile.name)

      webhook_params = {
        "Type" => "Notification",
        "Message" => "{\"state\" : \"ERROR\", \"jobId\": \"#{TranscodedVideo.last.job_id}\"}"
      }
      described_class.new.perform(webhook_params)

      expect(TranscodedVideo.last.state).to eq "error"
    end
  end
end
