# frozen_string_literal: true

require "spec_helper"

describe TextScrubber do
  describe "#format" do
    it "strips HTML tags and retain the spaces between paragraphs." do
      text = "  <h1>Hello world!</h1><p>I'm a \n\n text.<br>More text!</p>  "
      expect(TextScrubber.format(text)).to eq "Hello world!\n\nI'm a \n\n text.\nMore text!"
      expect(TextScrubber.format(text).squish).to eq "Hello world! I'm a text. More text!"
    end
  end
end
