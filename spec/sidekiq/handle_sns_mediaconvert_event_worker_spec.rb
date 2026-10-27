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
      end
    end

    context "when MediaConvert fails to transcode the video" do
      let!(:transcoded_video) { create(:transcoded_video, job_id: "abcd", state: "processing") }

      it "marks the transcoded_video object as errored and notifies the creator" do
        expect do
          described_class.new.perform(error_notification)
        end.to have_enqueued_mail(ContactingCreatorMailer, :video_transcode_failed).with(transcoded_video.streamable_id)

        expect(transcoded_video.reload.state).to eq "error"
      end

      it "does not enqueue another transcoding job" do
        described_class.new.perform(error_notification)

        expect(TranscodeVideoForStreamingWorker.jobs.size).to eq(0)
      end
    end

    context "when an old job's error arrives again during a newer attempt" do
      let!(:old_video) { create(:transcoded_video, job_id: "abcd", state: "error") }
      let!(:new_video) { create(:transcoded_video, job_id: "efgh", state: "processing", original_video_key: old_video.original_video_key) }

      it "leaves the newer attempt processing and sends no email" do
        expect do
          described_class.new.perform(error_notification)
        end.not_to have_enqueued_mail(ContactingCreatorMailer, :video_transcode_failed)

        expect(new_video.reload.state).to eq "processing"
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
