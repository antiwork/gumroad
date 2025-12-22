# frozen_string_literal: true

class DisputeEvidence::GenerateRefundPolicyImageService
  class ImageTooLargeError < StandardError; end

  def self.perform(url:, mobile_purchase:, open_fine_print_modal:, max_size_allowed:)
    new(url, mobile_purchase:, open_fine_print_modal:, max_size_allowed:).perform
  end

  def initialize(url, mobile_purchase:, open_fine_print_modal:, max_size_allowed:)
    @url = url
    @open_fine_print_modal = open_fine_print_modal
    @max_size_allowed = max_size_allowed
    @width = mobile_purchase ? BREAKPOINT_SM : BREAKPOINT_LG
  end

  def perform
    binary_data = generate_screenshot
    unless binary_data
      Bugsnag.notify("DisputeEvidence::GenerateRefundPolicyImageService: Could not generate screenshot for url #{url}")
      return
    end

    optimized_binary_data = optimize_image(binary_data)
    image = MiniMagick::Image.read(binary_data)
    raise ImageTooLargeError if image.size > max_size_allowed

    optimized_binary_data
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

    # Should match $breakpoints definitions from app/javascript/stylesheets/_definitions.scss
    BREAKPOINT_SM = 640
    BREAKPOINT_LG = 1024

    IMAGE_RESIZE_FACTOR = 2
    IMAGE_QUALITY = 80

    attr_reader :url, :width, :open_fine_print_modal, :max_size_allowed

    def generate_screenshot
      options = Selenium::WebDriver::Chrome::Options.new(args: CHROME_ARGS)
      driver = Selenium::WebDriver.for(:chrome, options:)
      # Height will be adjusted after the page is loaded
      driver.manage.window.size = Selenium::WebDriver::Dimension.new(width, width)

      driver.navigate.to url

      # Ensures the page is fully loaded, especially when we want to render with the refund policy modal open.
      wait = Selenium::WebDriver::Wait.new(timeout: 10)
      wait.until { driver.execute_script("return document.readyState") == "complete" }

      height = calculate_height(driver, open_fine_print_modal:)

      driver.manage.window.size = Selenium::WebDriver::Dimension.new(width, height)
      driver.screenshot_as(:png)
    ensure
      driver.quit if driver.present?
    end

    def calculate_height(driver, open_fine_print_modal:)
      document_height = driver.execute_script(js_max_height_dimension)
      if open_fine_print_modal
        modal_height = driver.execute_script(%{ return document.querySelector("dialog").scrollHeight; })
        [modal_height, document_height].max
      else
        # We need to calculate the height of the content, plus the padding added by the parent element
        content_height = driver.execute_script(%{ return document.querySelector("article").parentElement.scrollHeight; })
        [content_height, document_height].max
      end
    end

    def js_max_height_dimension
      %{
        return Math.max(
          document.body.scrollHeight,
          document.body.offsetHeight,
          document.documentElement.clientHeight,
          document.documentElement.scrollHeight,
          document.documentElement.offsetHeight,
          );
        }
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
