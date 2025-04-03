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
      wait.until { driver.execute_script("return document.readyState") == "complete" }
      driver.manage.window.size = Selenium::WebDriver::Dimension.new(WIDTH, HEIGHT)
      driver.screenshot_as(:png)
    end
  ensure
    driver.quit if driver.present?
  end
end
