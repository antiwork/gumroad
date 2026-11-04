# frozen_string_literal: true

class Pages::WaitlistForm
  SELECTOR = "form[data-gumroad-waitlist]"
  SIGNUP_MESSAGE = "gumroad:waitlist"

  def self.found_in?(html)
    html = html.to_s
    html.present? && (html.include?(SIGNUP_MESSAGE) || Loofah.fragment(html).css(SELECTOR).any?)
  end
end
