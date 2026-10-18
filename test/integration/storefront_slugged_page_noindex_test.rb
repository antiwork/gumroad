# frozen_string_literal: true

require "test_helper"

# Proves the header reaches the response a crawler actually gets on a seller
# subdomain. The routes that serve `/<slug>` there are picked by
# UserCustomDomainConstraint, and controller tests call the action directly —
# they bypass that constraint, so they stay green if those routes stop matching.
class StorefrontSluggedPageNoindexTest < ActionDispatch::IntegrationTest
  setup do
    @seller = create_user(username: "noindexpages")
  end

  def create_page(**attrs)
    # A slugged page is moderated on save, so the fixture is built under a passing stub.
    ContentModeration::ModerateRecordService.stub(:check, moderation_result(passed: true)) do
      @seller.pages.create!({ title: "About", slug: "about" }.merge(attrs))
    end
  end

  def get_page(path)
    with_const(:ROOT_DOMAIN, "example.com") do
      get path, headers: { "HOST" => "#{@seller.username}.example.com" }
    end
  end

  test "an unreviewed seller's slugged page is noindex on their subdomain" do
    create_page(content: "<p>Hello</p>")
    assert @seller.not_reviewed?

    get_page "/about"

    assert_response :success
    assert_equal "noindex", response.headers["X-Robots-Tag"]
  end

  test "the custom-HTML embed behind a slugged page is noindex too" do
    create_page(slug: "spam", custom_html: "<h1>Login</h1>")

    get_page "/spam/landing/embed"

    assert_response :success
    assert_equal "noindex", response.headers["X-Robots-Tag"]
  end

  test "the slugged page is indexable once the seller has a paid sale" do
    create_page(content: "<p>Hello</p>")
    create_purchase(link: create_product(user: @seller, price_cents: 500), price_cents: 500)

    get_page "/about"

    assert_response :success
    assert_nil response.headers["X-Robots-Tag"]
  end
end
