# frozen_string_literal: false

require "spec_helper"

describe HandleSnsMediaconvertEventWorker do
  let(:notification) do
    {
      "Type" => "Notification",
      "Message" => {
        "detail" => {
          "jobId" => "abcd",
          "status" => "COMPLETE",
          "outputGroupDetails" => [
            "playlistFilePaths" => [
              "s3://#{S3_BUCKET}/path/to/playlist/file.m3u8"
            ]
          ]
        }
      }.to_json
    }
  end

  let(:error_notification) do
    {
      "Type" => "Notification",
      "Message" => {
        "detail" => {
          "jobId" => "abcd",
          "status" => "ERROR",
        }
      }.to_json
    }
  end

  describe "#perform" do
    context "when transcoded_video object doesn't exist" do
      it "returns nil" do
        expect(described_class.new.perform(notification)).to be_nil

        expect(TranscodeVideoForStreamingWorker.jobs.size).to eq(0)
        expect(HandleSnsTranscoderEventWorker.jobs.size).to eq(0)
      end
    end

    context "when MediaConvert fails to transcode the video" do
      before do
        @transcoded_video = create(:transcoded_video, job_id: "abcd", state: "processing")
      end

      it "deletes the transcoded_video object" do
        expect do
          described_class.new.perform(error_notification)
        end.to change { TranscodedVideo.count }.by(-1)

        expect { @transcoded_video.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "enqueues a job to transcode the video using ETS" do
        described_class.new.perform(error_notification)

        ets_transcoder = TranscodeVideoForStreamingWorker::ETS
        expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(@transcoded_video.streamable.id, ProductFile.name, ets_transcoder)
        expect(HandleSnsTranscoderEventWorker.jobs.size).to eq(0)
      end
    end

    context "when MediaConvert successfully transcodes the video" do
      before do
        @transcoded_video = create(:transcoded_video, job_id: "abcd", state: "processing")
        @transcoded_video_2 = create(:transcoded_video, job_id: "efgh", state: "processing", original_video_key: @transcoded_video.original_video_key)
      end

      it "updates the transcoded_video object" do
        described_class.new.perform(notification)

        @transcoded_video.reload
        expect(@transcoded_video.state).to eq "completed"
        expect(@transcoded_video.transcoded_video_key).to eq "path/to/playlist/file.m3u8"

        @transcoded_video_2.reload
        expect(@transcoded_video_2.state).to eq "completed"
        expect(@transcoded_video_2.transcoded_video_key).to eq "path/to/playlist/file.m3u8"
      end
    end
  end
end
