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

  it "sends one receipt per seller, and per purchase for a two-item order", :sidekiq_inline do
    allow(CustomerMailer).to receive(:receipt).and_call_original
    # Seller one has a single-item charge (one combined receipt); seller two has a
    # two-item charge which is split into one receipt per purchase (gp#2025).
    check_out(product_one)

    expect(CustomerMailer).to have_received(:receipt).with(nil, product_one.sales.first.charge.id)
    expect(CustomerMailer).to have_received(:receipt).with(product_two.sales.first.id, single_purchase: true)
    expect(CustomerMailer).to have_received(:receipt).with(product_three.sales.first.id, single_purchase: true)
    expect(CustomerMailer).not_to have_received(:receipt).with(nil, product_two.sales.first.charge.id)
  end
end
