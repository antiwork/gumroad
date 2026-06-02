# frozen_string_literal: true

class Pages::BuyAffordance
  BUY_SELECTOR = '[data-gumroad-action="buy"]'
  CHECKOUT_MESSAGE = "gumroad:checkout"

  def self.missing?(html)
    new(html).missing?
  end

  def initialize(html)
    @html = html.to_s
  end

  def missing?
    return false if @html.blank?

    Loofah.fragment(@html).css(BUY_SELECTOR).empty? && !@html.include?(CHECKOUT_MESSAGE)
  end
end
