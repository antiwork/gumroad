# frozen_string_literal: true

require "test_helper"

class AnalyzeFileWorkerTest < ActiveSupport::TestCase
  self.described_class = AnalyzeFileWorker


  context_ AnalyzeFileWorker do
  context_ "#perform" do
      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
      end

  test "calls analyze for product file when no class name is provided" do
        product_file = create(:product_file)
        expect_any_instance_of(ProductFile).to receive(:analyze)
        AnalyzeFileWorker.new.perform(product_file.id)
      end

  test "calls analyze for video files" do
        video_file = create(:video_file)
        expect_any_instance_of(VideoFile).to receive(:analyze)
        AnalyzeFileWorker.new.perform(video_file.id, VideoFile.name)
      end
    end
  end
end
