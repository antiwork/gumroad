# frozen_string_literal: true

require "test_helper"

class UsersControllerNoindexTest < ActionController::TestCase
  tests UsersController

  setup do
    @seller = create_user(username: "noindexseller")
    @request.host = "#{@seller.username}.test.gumroad.com"
  end

  def get_profile
    with_const(:ROOT_DOMAIN, "test.gumroad.com") do
      get :show, params: { username: @seller.username }
    end
  end

  test "GET show sets noindex for a seller nobody has reviewed and who has no sale" do
    assert @seller.not_reviewed?

    get_profile

    assert_equal "noindex", response.headers["X-Robots-Tag"]
  end

  test "GET show sets noindex when the only sale is free" do
    create_purchase(link: create_product(user: @seller), price_cents: 0)

    get_profile

    assert_equal "noindex", response.headers["X-Robots-Tag"]
  end

  test "GET show does not set noindex once the seller has a paid sale" do
    create_purchase(link: create_product(user: @seller, price_cents: 500), price_cents: 500)

    get_profile

    assert_nil response.headers["X-Robots-Tag"]
  end

  test "GET show does not set noindex for a seller marked compliant" do
    @seller.mark_compliant!(author_name: "test")

    get_profile

    assert_nil response.headers["X-Robots-Tag"]
  end
end
