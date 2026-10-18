# frozen_string_literal: true

require "test_helper"

class UserPagesControllerNoindexTest < ActionController::TestCase
  tests UserPagesController

  setup do
    @seller = create_user(username: "noindexpages")
    @request.host = "#{@seller.username}.example.com"
  end

  def create_page(**attrs)
    # A slugged page is moderated on save, so the fixture is built under a passing stub.
    ContentModeration::ModerateRecordService.stub(:check, moderation_result(passed: true)) do
      @seller.pages.create!({ title: "About", slug: "about" }.merge(attrs))
    end
  end

  def get_page(action = :show)
    with_const(:ROOT_DOMAIN, "example.com") do
      get action, params: { slug: "about" }
    end
  end

  test "GET show sets noindex for a seller nobody has reviewed and who has no sale" do
    create_page(content: "<p>Hello</p>")
    assert @seller.not_reviewed?

    get_page

    assert_equal "noindex", response.headers["X-Robots-Tag"]
  end

  test "GET landing_iframe_content sets noindex for the same seller" do
    create_page(custom_html: "<h1>Hello</h1>")

    get_page(:landing_iframe_content)

    assert_equal "noindex", response.headers["X-Robots-Tag"]
  end

  test "GET show does not set noindex once the seller has a paid sale" do
    create_page(content: "<p>Hello</p>")
    create_purchase(link: create_product(user: @seller, price_cents: 500), price_cents: 500)

    get_page

    assert_nil response.headers["X-Robots-Tag"]
  end

  test "GET show does not set noindex for a seller marked compliant" do
    create_page(content: "<p>Hello</p>")
    @seller.mark_compliant!(author_name: "test")

    get_page

    assert_nil response.headers["X-Robots-Tag"]
  end
end
