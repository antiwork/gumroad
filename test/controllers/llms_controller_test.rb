# frozen_string_literal: true

require "test_helper"

class LlmsControllerTest < ActionController::TestCase
  tests LlmsController

  test "GET index renders llms.txt" do
    get :index, format: :txt

    assert_response :success
    assert_includes response.body, "# Gumroad"
  end

  test "llms.txt follows the llms.txt spec format" do
    get :index, format: :txt

    assert_match(/\A# Gumroad\n\n> /, response.body)
    assert_includes response.body, "## URL patterns"
    assert_includes response.body, "## Pricing"
    assert_includes response.body, "## API"
  end

  test "llms.txt pricing matches the fee constants" do
    get :index, format: :txt

    flat_pct = Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND / 10
    fixed_fee = Purchase::GUMROAD_FIXED_FEE_CENTS / 100.0
    discover_pct = Purchase::GUMROAD_DISCOVER_FEE_PER_THOUSAND / 10

    assert_includes response.body, "#{flat_pct}% + $#{format("%.2f", fixed_fee)} per transaction"
    assert_includes response.body, "#{discover_pct}% per transaction"
    assert_includes response.body, "https://gumroad.com/pricing"
  end

  test "llms.txt documents canonical URL patterns and API docs" do
    get :index, format: :txt

    assert_includes response.body, "gumroad.com/l/{permalink}"
    assert_includes response.body, "{username}.gumroad.com"
    assert_includes response.body, "gumroad.com/discover"
    assert_includes response.body, "gumroad.com/wishlists/{slug}"
    assert_includes response.body, "https://gumroad.com/api"
    assert_includes response.body, "https://gumroad.com/help"
  end
end
