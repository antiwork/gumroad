# frozen_string_literal: true

require "test_helper"

class CurrencyHelperTest < ActionView::TestCase
  test "get_rate returns the correct value" do
    assert_equal "78.3932", get_rate("JPY")
    assert_equal "0.652571", get_rate("GBP")
  end

  test "get_usd_cents converts money amounts correctly" do
    assert_equal 128, get_usd_cents("JPY", 100)
    assert_equal 153, get_usd_cents("GBP", 100)
  end

  test "usd_cents_to_currency converts money amounts correctly" do
    assert_equal 100, usd_cents_to_currency("JPY", 127)
    assert_equal 100, usd_cents_to_currency("GBP", 153)
  end

  test "symbol_for returns the correct symbol" do
    assert_equal "$", symbol_for(:usd)
    assert_equal "£", symbol_for(:gbp)
  end

  test "symbol_for falls back to USD for unknown currencies" do
    assert_equal "$", symbol_for(:xyz)
  end

  test "min_price_for returns the correct value" do
    assert_equal 99, min_price_for(:usd)
    assert_equal 59, min_price_for(:gbp)
  end

  test "min_price_for falls back to USD for unknown currencies" do
    assert_equal 99, min_price_for(:xyz)
  end

  test "string_to_price_cents ignores commas" do
    assert_equal 120_000, string_to_price_cents(:usd, "1,200")
    assert_equal 120_099, string_to_price_cents(:usd, "1,200.99")
  end

  test "string_to_price_cents keeps only the first decimal point" do
    assert_equal 5000, string_to_price_cents(:usd, "50.00.000")
    assert_equal 100, string_to_price_cents(:usd, "1.000.00")
    assert_equal 123, string_to_price_cents(:usd, "1.2.3.4")
  end

  test "string_to_price_cents handles normal prices with a single decimal point" do
    assert_equal 999, string_to_price_cents(:usd, "9.99")
    assert_equal 10_000, string_to_price_cents(:usd, "100.00")
    assert_equal 50, string_to_price_cents(:usd, "0.50")
  end

  test "string_to_price_cents treats strings without digits as zero" do
    assert_equal 0, string_to_price_cents(:usd, ".")
    assert_equal 0, string_to_price_cents(:usd, "..")
    assert_equal 0, string_to_price_cents(:usd, "")
    assert_equal 0, string_to_price_cents(:usd, "abc")
  end

  test "unit_scaling_factor returns the correct value" do
    assert_equal 1, unit_scaling_factor("jpy")
    assert_equal 100, unit_scaling_factor("usd")
    assert_equal 100, unit_scaling_factor("gbp")
  end

  test "formatted_amount_in_currency returns the formatted amount with currency code and no symbol" do
    amount_cents = 1234
    %w[usd cad aud gbp].each do |currency|
      assert_equal "#{(amount_cents / 100.0)} #{currency.upcase}", formatted_amount_in_currency(amount_cents, currency)
    end
  end

  test "format_just_price_in_cents formats USD" do
    assert_equal "$12.99", format_just_price_in_cents(1299, "usd")
    assert_equal "99¢", format_just_price_in_cents(99, "usd")
  end

  test "format_just_price_in_cents formats other currencies" do
    assert_equal "A$7.99", format_just_price_in_cents(799, "aud")
    assert_equal "£7.99", format_just_price_in_cents(799, "gbp")
    assert_equal "¥799", format_just_price_in_cents(799, "jpy")
  end

  test "formatted_price_with_recurrence renders short format" do
    assert_equal(
      "$19.99 / month x 2",
      formatted_price_with_recurrence("$19.99", BasePrice::Recurrence::MONTHLY, 2, format: :short)
    )
  end

  test "formatted_price_with_recurrence renders long format" do
    assert_equal(
      "$19.99 a month x 2",
      formatted_price_with_recurrence("$19.99", BasePrice::Recurrence::MONTHLY, 2, format: :long)
    )
  end

  test "formatted_price_with_recurrence omits the charge count when nil" do
    assert_equal(
      "$19.99 / month",
      formatted_price_with_recurrence("$19.99", BasePrice::Recurrence::MONTHLY, nil, format: :short)
    )
  end

  test "product_card_formatted_price formats a fixed price" do
    assert_equal(
      "$19.99",
      product_card_formatted_price(price: 1999, currency_code: "usd", is_pay_what_you_want: false, recurrence: nil, duration_in_months: nil)
    )
  end

  test "product_card_formatted_price adds a plus sign for pay-what-you-want" do
    assert_equal(
      "$19.99+",
      product_card_formatted_price(price: 1999, currency_code: "usd", is_pay_what_you_want: true, recurrence: nil, duration_in_months: nil)
    )
  end

  test "product_card_formatted_price adds recurrence for pay-what-you-want" do
    assert_equal(
      "$19.99+ a month",
      product_card_formatted_price(price: 1999, currency_code: "usd", is_pay_what_you_want: true, recurrence: BasePrice::Recurrence::MONTHLY, duration_in_months: nil)
    )
  end

  test "product_card_formatted_price adds duration_in_months for pay-what-you-want" do
    assert_equal(
      "$19.99+ a month x 3",
      product_card_formatted_price(price: 1999, currency_code: "usd", is_pay_what_you_want: true, recurrence: BasePrice::Recurrence::MONTHLY, duration_in_months: 3)
    )
  end
end
