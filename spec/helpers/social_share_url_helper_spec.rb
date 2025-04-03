# frozen_string_literal: true

require "spec_helper"

describe SocialShareUrlHelper do
  describe "#twitter_url" do
    it "generates twitter share url" do
      twitter_url = "https://twitter.com/intent/tweet?text=You+%26+I:%20https://example.com"
      expect(helper.twitter_url("https://example.com", "You & I")).to eq twitter_url
    end
  end

  describe "#facebook_url" do
    context "when text is present" do
      it "generates facebook share url with text" do
        facebook_url = "https://www.facebook.com/sharer/sharer.php?u=https://example.com&quote=You+%2A+I"
        expect(helper.facebook_url("https://example.com", "You * I")).to eq facebook_url
      end
    end

    context "when text is not present" do
      it "generates facebook share url without text" do
        facebook_url = "https://www.facebook.com/sharer/sharer.php?u=https://example.com"
        expect(helper.facebook_url("https://example.com")).to eq facebook_url
      end
    end
  end
end
