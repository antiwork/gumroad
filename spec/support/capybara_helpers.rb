# frozen_string_literal: true

module CapybaraHelpers
  def wait_for_valid(javascript_expression)
    page.document.synchronize do
      raise Capybara::ElementNotFound unless page.evaluate_script(javascript_expression)
    end
  end

  def wait_for_visible(selector)
    wait_for_valid %($('#{selector}:visible').length > 0)
  end

  def wait_for_ajax
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until finished_all_ajax_requests?
    end
  end

  def finished_all_ajax_requests?
    page.evaluate_script(<<~EOS)
      ((typeof window.jQuery === 'undefined') || jQuery.active === 0) && !window.__activeRequests
    EOS
  end

  DISABLE_ANIMATIONS_JS = <<~JS
    if (!document.getElementById('__disable_animations')) {
      const style = document.createElement('style');
      style.id = '__disable_animations';
      style.textContent = '*, *::before, *::after { animation-duration: 0s !important; animation-delay: 0s !important; transition-duration: 0s !important; transition-delay: 0s !important; }';
      document.head.appendChild(style);
    }
  JS

  def visit(url)
    page.visit(url)
    return if Capybara.current_driver == :rack_test
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script("document.readyState") == "complete"
    end
    disable_animations
    wait_for_ajax
  end

  def wait_until_true(sleep_interval: 1)
    Timeout.timeout(Capybara.default_max_wait_time) do
      until yield
        sleep sleep_interval
      end
    end
  end

  def js_style_encode_uri_component(comp)
    # CGI.escape encodes spaces to "+"
    # but encodeURIComponent in JS encodes them to "%20"
    CGI.escape(comp).gsub("+", "%20")
  end

  def fill_in_color(field, color)
    field.execute_script("Object.getOwnPropertyDescriptor(Object.getPrototypeOf(this), 'value').set.call(this, arguments[0]); this.dispatchEvent(new Event('input', { bubbles: true }))", color)
  end

  def have_nth_table_row_record(n, text, exact_text: true)
    have_selector("tbody tr:nth-child(#{n}) > td", text:, exact_text:, normalize_ws: true)
  end

  def get_client_time_zone
    page.evaluate_script("Intl.DateTimeFormat().resolvedOptions().timeZone")
  end

  def unfocus
    find("body").click
  end

  def fill_in_datetime(field, with:)
    element = find_field(field)
    element.click
    element.execute_script("this.value = arguments[0]; this.dispatchEvent(new Event('blur', {bubbles: true}));", with)
  end

  def accept_browser_dialog
    page.driver.browser.switch_to.alert.accept
  rescue StandardError
    sleep 0.5
    page.driver.browser.switch_to.alert.accept
  end

  # Reads the flash/toast alert message and immediately dismisses it.
  # Use this instead of `have_alert` when the alert overlays content
  # you need to interact with next — it prevents the 5s auto-dismiss
  # from blocking clicks on elements underneath.
  #
  # Usage:
  #   click_on "Save"
  #   expect(flash_message).to eq "Changes saved!"
  #   # alert is now dismissed, safe to interact with content beneath it
  def flash_message
    toast = find("[data-testid='toast-alert']")
    message = toast.text
    within(toast) { click_on "Close" }
    message
  end

  # Waits for checkout surcharges to load after country/ZIP/tax ID changes.
  # The checkout form debounces these at 300ms before firing the API call.
  def wait_for_checkout_surcharges_loaded
    sleep 0.4 # debounce (300ms) + margin
    wait_for_ajax
  end

  def with_throttled_network(fixture_file, factor: 4)
    throughput = (File.size(fixture_file) * factor)
    page.driver.browser.execute_cdp("Network.enable")
    page.driver.browser.execute_cdp("Network.emulateNetworkConditions", offline: false, latency: 0, downloadThroughput: throughput, uploadThroughput: throughput)
    yield
    page.driver.browser.execute_cdp("Network.emulateNetworkConditions", offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1)
  end

  private
    def disable_animations
      page.execute_script(DISABLE_ANIMATIONS_JS)
    rescue StandardError
      nil
    end
end
