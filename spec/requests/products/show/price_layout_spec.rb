# frozen_string_literal: true

require "spec_helper"

describe "Product price layout", type: :system, js: true do
  # The controls section's own top padding is 24px; the bug left a gap of over 100px.
  let(:max_gap_under_price) { 40 }
  # The title must end well below the price, or a shared row could not stretch the price cell.
  let(:min_title_overhang) { 20 }

  let(:seller) { create(:named_seller) }
  let(:product) do
    create(:product, user: seller, price_cents: 49_700,
                     name: "The Complete Illustrated Guide to Hand Lettering, Brush Pens, Watercolor Washes and Greeting Cards")
  end

  def expect_right_under_the_price(control)
    price_bottom = find("[itemprop=offers]").evaluate_script("this.getBoundingClientRect().bottom")
    title_bottom = find("h1[itemprop=name]").evaluate_script("this.getBoundingClientRect().bottom")
    control_top = control.evaluate_script("this.getBoundingClientRect().top")

    expect(title_bottom).to be > price_bottom + min_title_overhang
    expect(control_top - price_bottom).to be < max_gap_under_price
  end

  it "keeps the buy button right under the price when the title wraps over several lines" do
    visit short_link_path(product)

    expect_right_under_the_price(find_link("I want this!"))
  end

  it "keeps the not-for-sale notice right under the price when the title wraps over several lines" do
    product.unpublish!

    visit short_link_path(product)

    expect_right_under_the_price(find("[role=status]", text: "This product is not currently for sale."))
  end
end
