# frozen_string_literal: true

require "spec_helper"

describe SocialShareUrlHelper do
  describe "#twitter_url" do
    it "generates twitter share url" do
      twitter_url = "https://twitter.com/intent/tweet?text=You+%26+I:%20https://example.com"
      expect(helper.twitter_url("https://example.com", "You & I")).to eq twitter_url
    end
  end
end
