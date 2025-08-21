# frozen_string_literal: true

require "spec_helper"

describe "Checkout currency conversions", :js, type: :system do
  before do
    $currency_namespace = Redis::Namespace.new(:currencies, redis: $redis)
    $currency_namespace.set("GBP", 5.1651)
    @product = create(:product, price_cents: 2300, price_currency_type: "gbp")
  end

  it "correctly converts to USD at checkout" do
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    within "[role=listitem]" do
      expect(page).to have_text("US$4.45")
    end
    check_out(@product)
  end
end
