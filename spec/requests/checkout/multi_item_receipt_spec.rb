# frozen_string_literal: true

require "spec_helper"

describe "Multi-item receipt", :js, type: :system do
  include ActiveJob::TestHelper

  let(:seller_one) { create(:user) }
  let(:product_one) { create(:product, user: seller_one, price_cents: 110, name: "Product One") }

  let(:seller_two) { create(:user) }
  let(:product_two) { create(:product, user: seller_two, price_cents: 120, name: "Product Two") }
  let(:product_three) { create(:product, user: seller_two, price_cents: 130, name: "Product Three") }

  before do
    visit product_one.long_url
    add_to_cart(product_one)
    visit product_two.long_url
    add_to_cart(product_two)
    visit product_three.long_url
    add_to_cart(product_three)
  end

  it "sends one receipt per seller", :sidekiq_inline do
    allow(CustomerMailer).to receive(:receipt).with(nil, anything).exactly(2).times.and_call_original
    # It doesn't matter which product is being passed, it works with multiple products
    check_out(product_one)

    expect(CustomerMailer).to have_received(:receipt).with(nil, product_one.sales.first.charge.id)
    expect(CustomerMailer).to have_received(:receipt).with(nil, product_two.sales.first.charge.id)
  end
end
