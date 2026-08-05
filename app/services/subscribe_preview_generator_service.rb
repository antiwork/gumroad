# frozen_string_literal: true

# Used for OpenGraph consumers like: https://developer.twitter.com/en/docs/twitter-for-websites/cards/overview/summary-card-with-large-image
class SubscribePreviewGeneratorService
  RETINA_PIXEL_RATIO = 2
  ASPECT_RATIO = 128/67r
  WIDTH = 512
  HEIGHT = WIDTH / ASPECT_RATIO
  # The PNG's real pixel dimensions (the screenshot is taken at retina scale).
  # Meta tags advertise these so Facebook's crawler can render the card on the
  # very first share of a freshly-scraped URL instead of a blank preview while
  # it processes the image asynchronously.
  OUTPUT_WIDTH = WIDTH * RETINA_PIXEL_RATIO
  OUTPUT_HEIGHT = (HEIGHT * RETINA_PIXEL_RATIO).to_i
  CHROME_ARGS = [
    "force-device-scale-factor=#{RETINA_PIXEL_RATIO}",
    "headless",
    "no-sandbox",
    "disable-setuid-sandbox",
    "disable-dev-shm-usage",
    "user-data-dir=/tmp/chrome",
  ].freeze

  # Targeted by attribute rather than by tag: any future <img> added earlier in
  # the document would otherwise satisfy the wait and silently reopen the
  # empty-circle bug this guards against.
  #
  # `complete && naturalWidth > 0` only means the bytes arrived; Chromium still
  # decodes afterwards and screenshots taken in that window get an empty circle.
  # decode() is the event that says the frame is paintable, so the poll kicks it
  # off once and then reports the flag it sets. A rejected decode is reported as
  # "failed", not "ready" — a broken image must not look identical to a decoded
  # one, or a normal attempt would attach an incomplete card instead of retrying.
  AVATAR_READY_SCRIPT = <<~JS
    const img = document.querySelector("[data-subscribe-preview-avatar]");
    if (!img) return false;
    if (window.__gumroadAvatarDecoded) return true;
    if (window.__gumroadAvatarDecodeFailed) return "failed";
    if (!window.__gumroadAvatarDecodeStarted) {
      window.__gumroadAvatarDecodeStarted = true;
      img.decode()
        .then(() => { window.__gumroadAvatarDecoded = true; })
        .catch(() => { window.__gumroadAvatarDecodeFailed = true; });
    }
    return false;
  JS

  # Screenshot whatever is on the page once this elapses, rather than waiting on
  # an avatar that is never going to arrive.
  AVATAR_WAIT_SECONDS = 10

  # readyState goes "complete" before Inertia has mounted the page, so the avatar
  # <img> does not exist yet and the card screenshots with an empty circle.
  # Waiting on the image itself is the only ordering guarantee available here.
  #
  # A timeout raises by default so the job's retries can absorb a slow CDN. Only
  # the final attempt passes require_avatar: false, trading the avatar for a card
  # rather than leaving the seller with none at all.
  def self.generate_pngs(users, require_avatar: true)
    options = Selenium::WebDriver::Chrome::Options.new(args: CHROME_ARGS)
    driver = Selenium::WebDriver.for(:chrome, options:)
    users.map do |user|
      url = Rails.application.routes.url_helpers.user_subscribe_preview_url(
        user.username,
        host: DOMAIN,
        protocol: PROTOCOL,
      )
      driver.navigate.to url
      wait = Selenium::WebDriver::Wait.new(timeout: AVATAR_WAIT_SECONDS)
      begin
        # A rejected decode only satisfies the wait when the avatar is optional —
        # otherwise it must time out like a slow one, so retries get a chance
        # before a card without an avatar is ever attached.
        wait.until do
          result = driver.execute_script(AVATAR_READY_SCRIPT)
          result == true || (result == "failed" && !require_avatar)
        end
      rescue Selenium::WebDriver::Error::TimeoutError
        raise if require_avatar
        Rails.logger.error("SubscribePreviewGeneratorService: avatar never loaded for user.id=#{user.id}, generating card without it")
      end
      driver.manage.window.size = Selenium::WebDriver::Dimension.new(WIDTH, HEIGHT)
      driver.screenshot_as(:png)
    end
  ensure
    driver.quit if driver.present?
  end
end
