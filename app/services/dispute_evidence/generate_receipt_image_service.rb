# frozen_string_literal: true

class DisputeEvidence::GenerateReceiptImageService
  def self.perform(purchase)
    new(purchase).perform
  end

  def initialize(purchase)
    @purchase = purchase
  end

  def perform
    binary_data = generate_screenshot

    unless binary_data
      Bugsnag.notify("DisputeEvidence::GenerateRefundPolicyImageService: Could not generate screenshot for purchase ID #{purchase.id}")
      return
    end

    optimize_image(binary_data)
  end

  private
    CHROME_ARGS = [
      "headless",
      "no-sandbox",
      "disable-setuid-sandbox",
      "disable-dev-shm-usage",
      "user-data-dir=/tmp/chrome",
      "disable-scrollbars"
    ].freeze

    BREAKPOINT_LG = 1024

    IMAGE_RESIZE_FACTOR = 2
    IMAGE_QUALITY = 80

    attr_reader :purchase
    attr_accessor :width

    def generate_screenshot
      options = Selenium::WebDriver::Chrome::Options.new(args: CHROME_ARGS)
      driver = Selenium::WebDriver.for(:chrome, options:)

      html = generate_html(purchase)
      encoded_content = Addressable::URI.encode_component(html, Addressable::URI::CharacterClasses::QUERY)

      driver.navigate.to "data:text/html;charset=UTF-8,#{encoded_content}"

      # Use a fixed width in order to have a consistent way to determine if is a retina display screenshot
      @width = BREAKPOINT_LG
      height = driver.execute_script(js_max_height_dimension)

      driver.manage.window.size = Selenium::WebDriver::Dimension.new(width, height)
      driver.screenshot_as(:png)
    ensure
      driver.quit if driver.present?
    end

    def js_max_height_dimension
      %{
        return Math.max(
          document.body.scrollHeight,
          document.body.offsetHeight,
          document.documentElement.clientHeight,
          document.documentElement.scrollHeight,
          document.documentElement.offsetHeight
        );
      }
    end

    def generate_html(purchase)
      mail = CustomerMailer.receipt(purchase.id)
      mail_body = Nokogiri::HTML.parse(mail.body.raw_source)
      mail_info = %{
        <div style="padding: 20px 20px">
          <p><strong>Email receipt sent at:</strong> #{purchase.created_at}</p>
          <p><strong>From:</strong> #{mail.from.first}</p>
          <p><strong>To:</strong> #{mail.to.first}</p>
          <p><strong>Subject:</strong> #{mail.subject}</p>
        </div>
        <hr>
      }
      mail_body.at("body").prepend_child Nokogiri::HTML::DocumentFragment.parse(mail_info)
      mail_body.to_html
    end

    def optimize_image(binary_data)
      image = MiniMagick::Image.read(binary_data)
      image.resize("#{image.width / IMAGE_RESIZE_FACTOR}x") if retina_display_screenshot?(image)
      image.format("jpg").quality(IMAGE_QUALITY).strip
      image.to_blob
    end

    def retina_display_screenshot?(image)
      image.width == width * IMAGE_RESIZE_FACTOR
    end
end
