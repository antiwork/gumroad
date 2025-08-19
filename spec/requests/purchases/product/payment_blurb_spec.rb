# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("Payment Blurb for Purchases from the product page", type: :system, js: true) do
  before do
    @user = create(:user)

    $currency_namespace = Redis::Namespace.new(:currencies, redis: $redis)
    $currency_namespace.set("GBP", 0.2)
  end

  after do
    $currency_namespace.set("GBP", nil) if $currency_namespace
  end

  it "converts the currency based on the exchange rate" do
    link = create(:product, user: @user, price_cents: 1_00, price_currency_type: "gbp")

    visit "/l/#{link.unique_permalink}"
    click_on("I want this!")

    expect(page).to have_text("Total US$5", normalize_ws: true)
  end
end

describe "payment blurb with merchant account hides merchant account currency with merchant migration disabled", type: :system, js: true do
  before do
    @user = create(:user)
    @merchant_account = create(:merchant_account, user: @user)
    Feature.deactivate_user(:merchant_migration, @user)
  end

  after do
    @merchant_account.country = "US"
    @merchant_account.currency = "usd"
    @merchant_account.save!
  end

  it "does not convert to GBP" do
    @merchant_account.country = "UK"
    @merchant_account.currency = "gbp"
    @merchant_account.save!

    link = create(:product, user: @user, price_cents: 1_00, price_currency_type: "usd")

    visit "/l/#{link.unique_permalink}"
    click_on("I want this!")

    expect(page).to have_text("Total US$1", normalize_ws: true)
  end

  it "does not convert to SGP" do
    @merchant_account.country = "Singapore"
    @merchant_account.currency = "sgd"
    @merchant_account.save!

    link = create(:product, user: @user, price_cents: 1_00, price_currency_type: "usd")

    visit "/l/#{link.unique_permalink}"
    click_on("I want this!")

    expect(page).to have_text("Total US$1", normalize_ws: true)
  end
end
