# frozen_string_literal: true

class Pages::WaitlistForm
  SELECTOR = "form[data-gumroad-waitlist]"

  def self.found_in?(html)
    html.present? && Loofah.fragment(html.to_s).css(SELECTOR).any?
  end
end
