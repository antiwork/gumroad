# frozen_string_literal: true

require "spec_helper"

describe SubscribePreviewGeneratorService, type: :system, js: true do
  describe "#generate_pngs" do
    before do
      @user1 = create(:user, name: "User 1", username: "user1")
      @user2 = create(:user, name: "User 2", username: "user2")
      visit user_subscribe_preview_path(@user1.username) # Needed to boot the server
    end

    it "generates a png correctly" do
      images = described_class.generate_pngs([@user1, @user2])
      expect(images.first).to start_with("\x89PNG".b)
      expect(images.second).to start_with("\x89PNG".b)
    end

    it "always quits the webdriver on success" do
      expect_any_instance_of(Selenium::WebDriver::Driver).to receive(:quit)
      described_class.generate_pngs([@user1])
    end

    it "always quits the webdriver on error" do
      error = "FAILURE"
      expect_any_instance_of(Selenium::WebDriver::Driver).to receive(:quit)
      allow_any_instance_of(Selenium::WebDriver::Driver).to receive(:screenshot_as).and_raise(error)
      expect { described_class.generate_pngs([@user2]) }.to raise_error(error)
    end
  end
end
