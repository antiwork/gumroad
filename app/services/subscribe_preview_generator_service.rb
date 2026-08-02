# frozen_string_literal: true

# Used for OpenGraph consumers like: https://developer.twitter.com/en/docs/twitter-for-websites/cards/overview/summary-card-with-large-image
class SubscribePreviewGeneratorService
  RETINA_PIXEL_RATIO = 2
  ASPECT_RATIO = 128/67r
  WIDTH = 512
  HEIGHT = WIDTH / ASPECT_RATIO
  CHROME_ARGS = [
    "force-device-scale-factor=#{RETINA_PIXEL_RATIO}",
    "headless",
    "no-sandbox",
    "disable-setuid-sandbox",
    "disable-dev-shm-usage",
    "user-data-dir=/tmp/chrome",
  ].freeze

  # Any avatar, including the default one, is an <img>, so this is satisfied on
  # every profile rather than only on sellers who uploaded a portrait.
  AVATAR_READY_SCRIPT = <<~JS
    const img = document.querySelector("img");
    return !!img && img.complete && img.naturalWidth > 0;
  JS

  def self.generate_pngs(users)
    options = Selenium::WebDriver::Chrome::Options.new(args: CHROME_ARGS)
    driver = Selenium::WebDriver.for(:chrome, options:)
    users.map do |user|
      url = Rails.application.routes.url_helpers.user_subscribe_preview_url(
        user.username,
        host: DOMAIN,
        protocol: PROTOCOL,
      )
      driver.navigate.to url
      wait = Selenium::WebDriver::Wait.new(timeout: 10)
      # readyState goes "complete" before Inertia has mounted the page, so the
      # avatar <img> does not exist yet and the card screenshots with an empty
      # circle. Wait for the image itself to be decoded, not for the document.
      begin
        wait.until { driver.execute_script(AVATAR_READY_SCRIPT) }
      rescue Selenium::WebDriver::Error::TimeoutError
        # A card missing its avatar still beats no card at all, and a broken
        # avatar would otherwise fail this user forever on every retry.
        Rails.logger.warn("SubscribePreviewGeneratorService: avatar never loaded for user.id=#{user.id}")
      end
      driver.manage.window.size = Selenium::WebDriver::Dimension.new(WIDTH, HEIGHT)
      driver.screenshot_as(:png)
    end
  ensure
    driver.quit if driver.present?
  end
end
