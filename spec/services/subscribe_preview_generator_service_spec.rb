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

    it "screenshots only after the avatar has decoded" do
      gate_values = []
      ready_at_screenshot = nil

      allow_any_instance_of(Selenium::WebDriver::Driver).to receive(:execute_script).and_wrap_original do |original, script, *args|
        result = original.call(script, *args)
        gate_values << result if script == described_class::AVATAR_READY_SCRIPT
        result
      end
      # screenshot_as takes a `full_page:` keyword and recurses into itself, so the wrapper has to
      # forward keywords separately — splatting them as a positional hash raises ArgumentError.
      allow_any_instance_of(Selenium::WebDriver::Driver).to receive(:screenshot_as).and_wrap_original do |original, *args, **kwargs|
        ready_at_screenshot = gate_values.last if ready_at_screenshot.nil?
        original.call(*args, **kwargs)
      end

      described_class.generate_pngs([@user1])

      # The script only returns true once img.decode() has settled, so a
      # document-level wait leaves this nil and a load-complete wait leaves it
      # false: both fail here.
      expect(ready_at_screenshot).to be(true)
    end

    it "raises when the avatar never loads" do
      allow_any_instance_of(Selenium::WebDriver::Wait).to receive(:until).and_raise(Selenium::WebDriver::Error::TimeoutError)

      expect { described_class.generate_pngs([@user1]) }.to raise_error(Selenium::WebDriver::Error::TimeoutError)
    end

    it "still returns a png when the avatar never loads and it is not required" do
      allow_any_instance_of(Selenium::WebDriver::Wait).to receive(:until).and_raise(Selenium::WebDriver::Error::TimeoutError)

      images = described_class.generate_pngs([@user1], require_avatar: false)

      expect(images.first).to start_with("\x89PNG".b)
    end

    it "raises on a rejected decode rather than attaching an incomplete card" do
      driver = stub_subscribe_preview_driver(script_result: "failed")

      expect { described_class.generate_pngs([@user1]) }.to raise_error(Selenium::WebDriver::Error::TimeoutError)
      expect(driver).not_to have_received(:screenshot_as)
    end

    it "treats a rejected decode as settled only when the avatar is not required" do
      stub_subscribe_preview_driver(script_result: "failed")

      images = described_class.generate_pngs([@user1], require_avatar: false)

      expect(images.first).to eq("\x89PNG".b)
    end

    it "always quits the webdriver on error" do
      error = "FAILURE"
      expect_any_instance_of(Selenium::WebDriver::Driver).to receive(:quit)
      allow_any_instance_of(Selenium::WebDriver::Driver).to receive(:screenshot_as).and_raise(error)
      expect { described_class.generate_pngs([@user2]) }.to raise_error(error)
    end

    def stub_subscribe_preview_driver(script_result:)
      navigate = double(to: nil)
      window = double
      allow(window).to receive(:size=)
      manage = double(window:)
      driver = instance_double(
        Selenium::WebDriver::Driver,
        navigate:,
        manage:,
        execute_script: script_result,
        screenshot_as: "\x89PNG".b,
        quit: nil,
      )
      wait = instance_double(Selenium::WebDriver::Wait)

      allow(Selenium::WebDriver).to receive(:for).and_return(driver)
      allow(Selenium::WebDriver::Wait).to receive(:new).and_return(wait)
      allow(wait).to receive(:until) do |&block|
        next true if block.call

        raise Selenium::WebDriver::Error::TimeoutError
      end

      driver
    end
  end
end
