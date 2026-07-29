# frozen_string_literal: true

require "test_helper"

# Guards the shared model builders whose defaults are easy to get wrong: a
# ProductFile is only valid once it belongs to a product or an installment, so
# any builder that creates one behind the caller's back has to attach a parent.
class ModelFactoriesTest < ActiveSupport::TestCase
  test "subtitle file builder attaches its default parent file to a product" do
    subtitle_file = create_subtitle_file

    assert subtitle_file.persisted?
    assert_not_nil subtitle_file.product_file.link
  end

  test "transcoded video builder attaches its default source video to a product" do
    transcoded_video = create_transcoded_video

    assert transcoded_video.persisted?
    assert_not_nil transcoded_video.streamable.link
    assert transcoded_video.streamable.is_transcoded_for_hls
  end
end
