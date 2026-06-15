# frozen_string_literal: true

require "tmpdir"

webauthn_webdriver_client = Selenium::WebDriver::Remote::Http::Default.new(open_timeout: 120, read_timeout: 120)

# WebAuthn is only available in a secure context (HTTPS or localhost). System specs serve the
# app over HTTP on a custom host, so we mark that origin as secure to expose the WebAuthn API,
# and register a virtual authenticator to drive the ceremonies without real hardware. Use these
# drivers via `use_webauthn_driver` in specs that exercise passkey registration or sign-in.
# Chrome only honors --unsafely-treat-insecure-origin-as-secure under the new headless mode, so
# the docker driver swaps the legacy --headless flag for --headless=new.
Capybara.register_driver :webauthn_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_emulation(device_metrics: { width: 1440, height: 900, touch: false })
  options.add_preference("intl.accept_languages", "en-US")
  options.add_argument("--unsafely-treat-insecure-origin-as-secure=#{Capybara.app_host}")
  options.add_argument("--user-data-dir=#{Dir.mktmpdir}")
  Capybara::Selenium::Driver.new(app, browser: :chrome, http_client: webauthn_webdriver_client, options:)
end

Capybara.register_driver :webauthn_docker_headless_chrome do |app|
  Capybara::Selenium::Driver.load_selenium
  options = Selenium::WebDriver::Chrome::Options.new.tap do |opts|
    docker_browser_args.each do |arg|
      next if arg.start_with?("--user-data-dir=")

      opts.args << (arg == "--headless" ? "--headless=new" : arg)
    end
    opts.args << "--user-data-dir=#{Dir.mktmpdir}"
    opts.args << "--window-size=1440,900"
    opts.args << "--unsafely-treat-insecure-origin-as-secure=#{Capybara.app_host}"
  end
  options.add_preference("intl.accept_languages", "en-US")
  Capybara::Selenium::Driver.new(app, browser: :chrome, http_client: webauthn_webdriver_client, options:)
end

module WebauthnSystemHelpers
  def use_webauthn_driver
    driven_by(ENV["IN_DOCKER"] == "true" ? :webauthn_docker_headless_chrome : :webauthn_chrome)
  end

  def register_virtual_authenticator!
    # Chrome keeps the browser process (and its virtual authenticators) alive across examples,
    # and allows only one internal authenticator per environment, so each one must be removed
    # after the example that created it.
    @virtual_authenticator = page.driver.browser.add_virtual_authenticator(
      Selenium::WebDriver::VirtualAuthenticatorOptions.new(
        protocol: :ctap2,
        transport: :internal,
        resident_key: true,
        user_verification: true,
        user_verified: true
      )
    )
  end

  def remove_virtual_authenticator!
    @virtual_authenticator&.remove!
  rescue Selenium::WebDriver::Error::WebDriverError
    nil
  end
end

RSpec.configure do |config|
  config.include WebauthnSystemHelpers, type: :system
  config.after(:each, type: :system) { remove_virtual_authenticator! }
end
