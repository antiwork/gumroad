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

    it "waits for the avatar to decode before screenshotting" do
      scripts = []
      allow_any_instance_of(Selenium::WebDriver::Driver).to receive(:execute_script).and_wrap_original do |original, script, *args|
        scripts << script
        original.call(script, *args)
      end

      described_class.generate_pngs([@user1])

      expect(scripts).to include(described_class::AVATAR_READY_SCRIPT)
    end

    it "screenshots only once the avatar has actually decoded" do
      last_ready_result = nil
      ready_at_screenshot = nil

      allow_any_instance_of(Selenium::WebDriver::Driver).to receive(:execute_script).and_wrap_original do |original, script, *args|
        result = original.call(script, *args)
        last_ready_result = result if script == described_class::AVATAR_READY_SCRIPT
        result
      end
      allow_any_instance_of(Selenium::WebDriver::Driver).to receive(:screenshot_as).and_wrap_original do |original, *args|
        ready_at_screenshot = last_ready_result
        original.call(*args)
      end

      described_class.generate_pngs([@user1])

      # The script only returns true after img.decode() has settled, so this
      # fails if the screenshot is taken on load-complete alone.
      expect(ready_at_screenshot).to be(true)
    end

    it "still returns a png when the avatar never loads" do
      allow_any_instance_of(Selenium::WebDriver::Wait).to receive(:until).and_raise(Selenium::WebDriver::Error::TimeoutError)

      images = described_class.generate_pngs([@user1])

      expect(images.first).to start_with("\x89PNG".b)
    end

    it "always quits the webdriver on error" do
      error = "FAILURE"
      expect_any_instance_of(Selenium::WebDriver::Driver).to receive(:quit)
      allow_any_instance_of(Selenium::WebDriver::Driver).to receive(:screenshot_as).and_raise(error)
      expect { described_class.generate_pngs([@user2]) }.to raise_error(error)
    end
  end
end
