# frozen_string_literal: true

describe HandleGrmcCallbackJob do
  let(:product_file) { create(:product_file) }
  let(:transcoded_video) { create(:transcoded_video, job_id: "test_job_id", streamable: product_file, transcoded_video_key: "/attachments/68756f28973n28347/hls/", state: :processing) }

  describe "#perform" do
    context "when notification status is 'success'" do
      let(:notification) { { "job_id" => transcoded_video.job_id, "status" => "success" } }

      it "updates the product file and transcoded video, and marks it as completed" do
        described_class.new.perform(notification)

        product_file.reload
        transcoded_video.reload
        expect(product_file.is_transcoded_for_hls).to be true
        expect(transcoded_video.transcoded_video_key).to eq("/attachments/68756f28973n28347/hls/index.m3u8")
        expect(transcoded_video).to be_completed
      end

      it "updates all processing transcoded videos, and marks them as completed" do
        transcoded_video_2 = create(:transcoded_video, original_video_key: transcoded_video.original_video_key, transcoded_video_key: transcoded_video.transcoded_video_key, state: :processing)

        described_class.new.perform(notification)

        product_file.reload
        transcoded_video.reload
        expect(product_file.is_transcoded_for_hls).to be true
        expect(transcoded_video.transcoded_video_key).to eq("/attachments/68756f28973n28347/hls/index.m3u8")
        expect(transcoded_video).to be_completed

        product_file_2 = transcoded_video_2.reload.streamable.reload
        expect(product_file_2.is_transcoded_for_hls).to be true
        expect(transcoded_video_2.transcoded_video_key).to eq("/attachments/68756f28973n28347/hls/index.m3u8")
        expect(transcoded_video_2).to be_completed
      end
    end

    context "when notification status is not 'success'" do
      let(:notification) { { "job_id" => transcoded_video.job_id, "status" => "failure" } }

      it "enqueues TranscodeVideoForStreamingWorker" do
        described_class.new.perform(notification)
        expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(product_file.id, ProductFile.name, TranscodeVideoForStreamingWorker::MEDIACONVERT, true)
      end

      it "marks transcoded video, marks it as errored" do
        described_class.new.perform(notification)
        transcoded_video.reload
        expect(transcoded_video.state).to eq("error")
      end
    end
  end
end
