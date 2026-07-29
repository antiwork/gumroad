# frozen_string_literal: true

require "test_helper"

# Guards the shared model builders whose defaults are easy to get wrong. A
# ProductFile row saves happily with no parent, but a file that belongs to
# neither a product nor an installment is a shape production never has, and any
# test reaching through to the parent product finds nil. So every builder that
# creates a ProductFile behind the caller's back has to give it a product.
class ModelFactoriesTest < ActiveSupport::TestCase
  test "subtitle file builder attaches its default parent file to a product" do
    assert_not_nil create_subtitle_file.product_file.link
  end

  test "transcoded video builder attaches its default source video to a product" do
    transcoded_video = create_transcoded_video

    assert_not_nil transcoded_video.streamable.link
    # The HLS flag is what makes the source video a plausible transcode target,
    # so it is part of the default shape this builder promises.
    assert transcoded_video.streamable.is_transcoded_for_hls
  end
end
