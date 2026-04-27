# frozen_string_literal: true

# Chrome raises UnknownError instead of StaleElementReferenceError when React
# re-renders replace DOM nodes. Capybara retries stale elements automatically
# but doesn't recognize Chrome's variant. This patch bridges that gap.
module ChromeStaleNodeFix
  def execute(*)
    super
  rescue Selenium::WebDriver::Error::UnknownError => e
    raise Selenium::WebDriver::Error::StaleElementReferenceError, e.message if e.message.include?("does not belong to the document")
    raise
  end
end

Selenium::WebDriver::Remote::Bridge.prepend(ChromeStaleNodeFix)
