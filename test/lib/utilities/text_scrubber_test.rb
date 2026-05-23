# frozen_string_literal: true

require "test_helper"

class TextScrubberTest < ActiveSupport::TestCase
  test "strips HTML tags and retains the spaces between paragraphs" do
    text = "  <h1>Hello world!</h1><p>I'm a \n\n text.<br>More text!</p>  "
    assert_equal "Hello world!\n\nI'm a \n\n text.\nMore text!", TextScrubber.format(text)
    assert_equal "Hello world! I'm a text. More text!", TextScrubber.format(text).squish
  end
end
