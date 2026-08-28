# frozen_string_literal: true

require "test_helper"
require "ipaddr"

# Ported from spec/controllers/links_controller_spec.rb (#5801).
#
# The spec's single `describe LinksController, inertia: true` splits into a few
# ActionController::TestCase subclasses here, one per top-level context, so each
# gets the setup it needs (the seller-area sign-in, the consumer-area anonymous
# visitor, the product-show host, etc.) without per-test conditionals.
#
# Inertia responses are read as JSON: the `X-Inertia: true` request header makes
# inertia_rails render the page object as JSON instead of the HTML shell — the
# Minitest equivalent of the `inertia_rails/rspec` matchers the spec used. Tests
# that parse server-rendered HTML (meta tags, canonical links) deliberately omit
# the header so the full HTML page renders (views render by default in
# ActionController::TestCase, the built-in equivalent of RSpec's `render_views`).
module LinksControllerTestHelpers
  include ActionMailer::TestHelper

  # Mirror `let(:seller) { create(:named_seller) }` + the "with user signed in as
  # admin for seller" shared context: a fresh seller (the fixture named_seller
  # owns the fixture product, which would skew has_products / stats assertions,
  # so build a pristine one) plus a distinct admin team member as the logged-in
  # user. Building through create_user runs the account callbacks (refund policy,
  # etc.) the seller-area assertions rely on.
  def sign_in_seller_area!
    @seller = create_user(name: "Seller", payment_address: "seller-pay-#{unique_suffix}@example.com")
    @logged_in_user = create_user
    create_team_membership(user: @logged_in_user, seller: @seller, role: TeamMembership::ROLE_ADMIN)
    cookies.encrypted[:current_seller_id] = @seller.id
    sign_in @logged_in_user
  end

  # Sign in a fresh admin team member for an arbitrary seller — used where the
  # spec overrides `let(:seller)` to a freshly built user (e.g. an eligible
  # service-products seller for coffee-product creation).
  def sign_in_as_admin_for(seller)
    admin = create_user
    create_team_membership(user: admin, seller:, role: TeamMembership::ROLE_ADMIN)
    cookies.encrypted[:current_seller_id] = seller.id
    sign_in admin
    admin
  end

  def inertia_page
    assert_equal "application/json", response.media_type
    response.parsed_body
  end

  # For assertions that need both the Inertia page object and the rendered HTML
  # (meta tags) from a single response, parse the page object out of the root
  # element's data-page attribute instead of sending the X-Inertia header.
  def inertia_page_from_html
    html = Nokogiri::HTML.parse(response.body)
    JSON.parse(html.at_css("[data-page]")["data-page"])
  end

  # Replaces the RSpec `it_behaves_like "authorize called for action"`: stub the
  # policy so every LinkPolicy.new is recorded, then assert one was built with
  # the controller's pundit_user and the expected record (the authorize contract).
  def assert_authorize_called(verb, action, record:, policy_method: nil, params: {}, format: :html)
    policy_method ||= :"#{action}?"
    calls = []
    LinkPolicy.stubs(:new).with do |context, rec|
      calls << [context, rec]
      true
    end.returns(stub("LinkPolicy", policy_method => false))

    public_send(verb, action, params:, as: format)

    assert(calls.any? { |ctx, rec| ctx == @controller.send(:pundit_user) && rec == record },
           "Expected LinkPolicy to be built via `authorize` with the controller's pundit_user and #{record.inspect}")
  end

  # Replaces the RSpec `it_behaves_like "collaborator can access"`: a collaborator
  # on the product can reach the endpoint.
  def assert_collaborator_can_access(verb, action, product:, params: {}, format: :html, status: 200, response_attributes: nil)
    collaborator = create_collaborator(seller: product.user, products: [product])
    sign_in collaborator.affiliate_user

    public_send(verb, action, params:, as: format)

    assert_equal status, response.status
    if response_attributes
      body = JSON.parse(response.body)
      response_attributes.each { |key, value| assert_equal value, body[key] }
    end
  end

  def assert_enqueued_sidekiq_job(worker, *args)
    assert worker.jobs.any? { |job| job["args"] == args }, "Expected #{worker} to be enqueued with #{args.inspect}"
  end

  def refute_enqueued_sidekiq_job(worker, *args)
    assert_not worker.jobs.any? { |job| job["args"] == args }, "Expected #{worker} not to be enqueued with #{args.inspect}"
  end

  # Mocha has no `and_call_original` for class-method expectations. This spies on
  # `klass.new`, recording every call's positional/keyword args while delegating
  # to the real constructor, then returns the recorded calls to assert against —
  # the equivalent of `expect(Klass).to receive(:new).with(...).and_call_original`.
  def spy_on_class_new(klass)
    calls = []
    original = klass.method(:new)
    klass.singleton_class.send(:define_method, :new) do |*args, **kwargs, &blk|
      calls << { args:, kwargs: }
      original.call(*args, **kwargs, &blk)
    end
    yield
    calls
  ensure
    klass.singleton_class.send(:remove_method, :new)
  end

  # Helpers ported from the "AffiliateCookie concern" shared examples. Browsers
  # don't echo cookie attributes back, so the concern reads the Set-Cookie
  # response header directly to inspect the cookie it set.
  def parse_cookie(set_cookie, origin_url, cookie_name)
    Array.wrap(set_cookie)
         .lazy
         .flat_map { |cookie_string| HTTP::Cookie.parse(cookie_string, origin_url) }
         .find { |cookie| CGI.unescape(cookie.name) == cookie_name }
  end

  def determine_domain(url)
    uri = Addressable::URI.parse(url)
    IPAddr.new(uri.host)
    uri.host
  rescue IPAddr::InvalidAddressError
    uri.domain
  end

  def assert_includes_attributes(actual, expected)
    expected.each { |key, value| assert_equal value, actual[key], "expected #{key} to equal #{value.inspect}" }
  end
end

class LinksControllerSellerAreaTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers

  setup { sign_in_seller_area! }

  # --- GET index --------------------------------------------------------------

  test "GET index calls authorize with LinkPolicy for Link" do
    assert_authorize_called(:get, :index, record: Link)
  end

  test "GET index renders the Products/Index component with correct props" do
    @request.headers["X-Inertia"] = "true"
    get :index

    assert_response :success
    page = inertia_page
    assert_equal "Products/Index", page["component"]
    %w[has_products archived_products_count can_create_product].each { |key| assert page["props"].key?(key) }
    assert_not page["props"].key?("products_data")
    assert_not page["props"].key?("memberships_data")

    @request.headers["X-Inertia"] = "true"
    @request.headers["X-Inertia-Partial-Data"] = "products_data,memberships_data"
    @request.headers["X-Inertia-Partial-Component"] = "Products/Index"
    get :index

    page = inertia_page
    %w[products pagination sort].each { |key| assert page["props"]["products_data"].key?(key) }
    %w[memberships pagination sort].each { |key| assert page["props"]["memberships_data"].key?(key) }
  end

  # --- e404 tests (edit / unpublish / publish / destroy) ----------------------

  test "#edit 404s when link isn't found" do
    assert_raises(ActionController::RoutingError) { get :edit, params: { id: "NOT real" } }
  end

  test "#unpublish 404s when link isn't found" do
    assert_raises(ActionController::RoutingError) { get :unpublish, params: { id: "NOT real" } }
  end

  test "#publish 404s when link isn't found" do
    assert_raises(ActionController::RoutingError) { get :publish, params: { id: "NOT real" } }
  end

  test "#destroy 404s when link isn't found" do
    assert_raises(ActionController::RoutingError) { get :destroy, params: { id: "NOT real" } }
  end

  # --- POST publish -----------------------------------------------------------

  def disabled_link
    @disabled_link ||= create_physical_product(purchase_disabled_at: Time.current, user: @seller)
  end

  test "POST publish calls authorize" do
    assert_authorize_called(:post, :publish, record: disabled_link, params: { id: disabled_link.unique_permalink })
  end

  test "POST publish allows a collaborator to access" do
    assert_collaborator_can_access(:post, :publish, product: disabled_link, params: { id: disabled_link.unique_permalink }, response_attributes: { "success" => true })
  end

  test "POST publish enables a disabled link" do
    post :publish, params: { id: disabled_link.unique_permalink }

    assert_equal true, response.parsed_body["success"]
    assert_nil disabled_link.reload.purchase_disabled_at
  end

  test "POST publish returns an error message when link is not publishable" do
    Link.any_instance.stubs(:publishable?).returns(false)

    post :publish, params: { id: disabled_link.unique_permalink }

    assert_equal "You must connect at least one payment method before you can publish this product for sale.", response.parsed_body["error_message"]
  end

  test "POST publish does not publish the link when it is not publishable" do
    Link.any_instance.stubs(:publishable?).returns(false)

    post :publish, params: { id: disabled_link.unique_permalink }

    assert_equal false, response.parsed_body["success"]
    assert disabled_link.reload.purchase_disabled_at.present?
  end

  test "POST publish returns an error message when user email is not confirmed" do
    @seller.update!(confirmed_at: nil)
    unpublished_product = create_physical_product(purchase_disabled_at: Time.current, user: @seller)

    post :publish, params: { id: unpublished_product.unique_permalink }

    assert_equal "You have to confirm your email address before you can do that.", response.parsed_body["error_message"]
  end

  test "POST publish does not publish the link when user email is not confirmed" do
    @seller.update!(confirmed_at: nil)
    unpublished_product = create_physical_product(purchase_disabled_at: Time.current, user: @seller)

    post :publish, params: { id: unpublished_product.unique_permalink }

    assert_equal false, response.parsed_body["success"]
    assert unpublished_product.reload.purchase_disabled_at.present?
  end

  test "POST publish notifies error tracker when a temp file is missing" do
    Link.any_instance.stubs(:publish!).raises(Errno::ENOENT, "No such file or directory @ rb_file_s_size - /tmp/image_processing_test.png")

    ErrorNotifier.expects(:notify).once

    post :publish, params: { id: disabled_link.unique_permalink }
  end

  test "POST publish returns a retry-friendly error message when a temp file is missing" do
    Link.any_instance.stubs(:publish!).raises(Errno::ENOENT, "No such file or directory @ rb_file_s_size - /tmp/image_processing_test.png")

    post :publish, params: { id: disabled_link.unique_permalink }

    assert_equal false, response.parsed_body["success"]
    assert_equal "There was a temporary issue processing your product images. Please try again.", response.parsed_body["error_message"]
  end

  test "POST publish does not publish the link when a temp file is missing" do
    Link.any_instance.stubs(:publish!).raises(Errno::ENOENT, "No such file or directory @ rb_file_s_size - /tmp/image_processing_test.png")

    post :publish, params: { id: disabled_link.unique_permalink }

    assert_equal false, response.parsed_body["success"]
    assert disabled_link.reload.purchase_disabled_at.present?
  end

  test "POST publish notifies error tracker when an unknown exception is raised" do
    Link.any_instance.stubs(:publish!).raises(RuntimeError, "error")

    ErrorNotifier.expects(:notify).once

    post :publish, params: { id: disabled_link.unique_permalink }
  end

  test "POST publish returns an error message when an unknown exception is raised" do
    Link.any_instance.stubs(:publish!).raises(RuntimeError, "error")

    post :publish, params: { id: disabled_link.unique_permalink }

    assert_equal "Something broke. We're looking into what happened. Sorry about this!", response.parsed_body["error_message"]
  end

  test "POST publish does not publish the link when an unknown exception is raised" do
    Link.any_instance.stubs(:publish!).raises(RuntimeError, "error")

    post :publish, params: { id: disabled_link.unique_permalink }

    assert_equal false, response.parsed_body["success"]
    assert disabled_link.reload.purchase_disabled_at.present?
  end

  # --- POST unpublish ---------------------------------------------------------

  test "POST unpublish allows a collaborator to access" do
    product = create_product(user: @seller)
    assert_collaborator_can_access(:post, :unpublish, product:, params: { id: product.unique_permalink }, response_attributes: { "success" => true })
  end

  # --- PUT sections -----------------------------------------------------------

  test "PUT update_sections calls authorize" do
    product = create_product(user: @seller)
    assert_authorize_called(:put, :update_sections, record: product, params: { id: product.unique_permalink })
  end

  test "PUT update_sections allows a collaborator to access" do
    product = create_product(user: @seller)
    assert_collaborator_can_access(:put, :update_sections, product:, params: { id: product.unique_permalink }, status: 204)
  end

  test "PUT update_sections succeeds when the product has an expired default offer code" do
    product = create_product(user: @seller)
    offer_code = create_offer_code(user: @seller, products: [product])
    product.update_column(:default_offer_code_id, offer_code.id)
    offer_code.update_column(:expires_at, 1.day.ago)

    sections = create_list(:seller_profile_products_section, 2, seller: @seller, product:)

    put :update_sections, params: { id: product.unique_permalink, sections: sections.map(&:external_id), main_section_index: 0 }

    assert_response :no_content
    assert_equal sections.map(&:id), product.reload.sections
  end

  test "PUT update_sections updates the SellerProfileSections attached to the product and cleans up orphaned sections" do
    product = create_product(user: @seller)
    sections = create_list(:seller_profile_products_section, 2, seller: @seller, product:)
    create_seller_profile_posts_section(seller: @seller, product:)
    create_seller_profile_posts_section(seller: @seller)

    put :update_sections, params: { id: product.unique_permalink, sections: sections.map(&:external_id), main_section_index: 1 }

    product.reload
    assert_equal sections.map(&:id), product.sections
    assert_equal 1, product.main_section_index
    assert_equal 3, @seller.seller_profile_sections.count
    assert_equal 1, @seller.seller_profile_sections.on_profile.count
  end

  # --- DELETE destroy ---------------------------------------------------------

  test "DELETE destroy calls authorize for a suspended tos violation user" do
    admin_user = create_user
    product = create_product(user: @seller)
    @seller.flag_for_tos_violation(author_id: admin_user.id, product_id: product.id)
    @seller.suspend_for_tos_violation(author_id: admin_user.id)
    @request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i

    assert_authorize_called(:delete, :destroy, record: product, params: { id: product.unique_permalink })
  end

  test "DELETE destroy allows deletion if user suspended (tos)" do
    admin_user = create_user
    product = create_product(user: @seller)
    @seller.flag_for_tos_violation(author_id: admin_user.id, product_id: product.id)
    @seller.suspend_for_tos_violation(author_id: admin_user.id)
    @request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i

    delete :destroy, params: { id: product.unique_permalink }
    assert_equal true, product.reload.deleted_at.present?
  end

  test "DELETE destroy allows deletion when default_offer_code is no longer associated with the product" do
    product = create_product(user: @seller)
    offer_code = create_offer_code(user: @seller, products: [product])
    product.update!(default_offer_code: offer_code)
    offer_code.products = []

    delete :destroy, params: { id: product.unique_permalink }

    assert product.reload.deleted_at.present?
  end

  # --- GET edit ---------------------------------------------------------------

  test "GET edit calls authorize" do
    product = create_product(user: @seller)
    assert_authorize_called(:get, :edit, record: product, params: { id: product.unique_permalink })
  end

  test "GET edit renders the Inertia product edit page" do
    product = create_product(user: @seller)
    @request.headers["X-Inertia"] = "true"
    get :edit, params: { id: product.unique_permalink }

    assert_response :success
    page = inertia_page
    assert_equal "Products/Edit", page["component"]
    assert_equal product.external_id, page["props"]["id"]
    assert_equal product.unique_permalink, page["props"]["unique_permalink"]
    assert_equal DROPBOX_PICKER_API_KEY, page["props"]["dropbox_api_key"]
  end

  test "GET edit redirects to product page with other user not owning the product" do
    product = create_product(user: @seller)
    sign_in create_user
    get :edit, params: { id: product.unique_permalink }
    assert_redirected_to short_link_path(product)
  end

  test "GET edit renders the page with admin user signed in" do
    product = create_product(user: @seller)
    sign_in create_admin_user
    get :edit, params: { id: product.unique_permalink }
    assert_response :ok
  end

  test "GET edit redirects to the bundle edit page when the product is a bundle" do
    bundle = create_bundle
    sign_in bundle.user
    get :edit, params: { id: bundle.unique_permalink }
    assert_redirected_to edit_bundle_product_path(bundle.external_id)
  end

  test "GET edit renders the Inertia page for sub-routes with wildcard sub-path" do
    product = create_product(user: @seller)
    @request.headers["X-Inertia"] = "true"
    get :edit, params: { id: product.unique_permalink, other: "content" }
    assert_response :success
    assert_equal "Products/Edit", inertia_page["component"]
  end

  # --- POST price_check -------------------------------------------------------

  test "POST price_check calls authorize with the edit policy" do
    Flipper.enable(:price_checker)
    product = create_product(user: @seller)
    assert_authorize_called(:post, :price_check, record: product, policy_method: :edit?, params: { id: product.unique_permalink })
  end

  test "POST price_check returns 404 when the price_checker feature flag is disabled" do
    Flipper.disable(:price_checker)
    product = create_product(user: @seller)

    post :price_check, params: { id: product.unique_permalink }

    assert_response :not_found
  end

  test "POST price_check returns 504 when the service raises TimeoutError" do
    Flipper.enable(:price_checker)
    product = create_product(user: @seller)
    PriceCheckerService.expects(:call).raises(PriceCheckerService::TimeoutError)

    post :price_check, params: { id: product.unique_permalink }

    assert_response :gateway_timeout
  end

  test "POST price_check returns the price distribution payload as JSON" do
    Flipper.enable(:price_checker)
    product = create_product(user: @seller)
    payload = {
      status: "ok",
      tier: "broadened",
      match_count: 25,
      taxonomy_label: nil,
      currency_code: "usd",
      current_price_cents: product.price_cents,
      summary: { median_cents: 1_500, p25_cents: 1_000, p75_cents: 2_500, mean_cents: 1_750 },
      histogram: { interval_cents: 500, bins: [{ from_cents: 1_000, to_cents: 1_500, count: 5 }] },
      computed_at: "2024-01-01T00:00:00Z",
    }
    PriceCheckerService.expects(:call).with(product:, overrides: {}, force_refresh: false).returns(payload)

    post :price_check, params: { id: product.unique_permalink }

    assert_response :success
    assert_equal "ok", response.parsed_body["status"]
    assert_equal "broadened", response.parsed_body["tier"]
    assert_equal 25, response.parsed_body["match_count"]
  end

  test "POST price_check passes force_refresh when refresh param is present" do
    Flipper.enable(:price_checker)
    product = create_product(user: @seller)
    PriceCheckerService.expects(:call).with(product:, overrides: {}, force_refresh: true).returns({})

    post :price_check, params: { id: product.unique_permalink, refresh: "1" }

    assert_response :success
  end

  test "POST price_check passes sanitized overrides to the service" do
    Flipper.enable(:price_checker)
    product = create_product(user: @seller)
    taxonomy = Taxonomy.find_or_create_by(slug: "films")
    PriceCheckerService.expects(:call).with(
      product:,
      overrides: {
        name: "Edited title",
        description: "Edited description",
        taxonomy_id: taxonomy.id,
        native_type: "digital",
        currency_code: "eur",
      },
      force_refresh: false,
    ).returns({})

    post :price_check, params: {
      id: product.unique_permalink,
      overrides: {
        name: "  Edited title  ",
        description: "Edited description",
        taxonomy_id: taxonomy.id.to_s,
        native_type: "digital",
        currency_code: "EUR",
      },
    }

    assert_response :success
  end

  test "POST price_check drops an unknown currency_code override" do
    Flipper.enable(:price_checker)
    product = create_product(user: @seller)
    PriceCheckerService.expects(:call).with(
      product:,
      overrides: { name: "ok" },
      force_refresh: false,
    ).returns({})

    post :price_check, params: {
      id: product.unique_permalink,
      overrides: {
        name: "ok",
        currency_code: "xxx_not_a_currency",
      },
    }

    assert_response :success
  end

  test "POST price_check drops invalid overrides instead of erroring" do
    Flipper.enable(:price_checker)
    product = create_product(user: @seller)
    PriceCheckerService.expects(:call).with(
      product:,
      overrides: { name: "ok" },
      force_refresh: false,
    ).returns({})

    post :price_check, params: {
      id: product.unique_permalink,
      overrides: {
        name: "ok",
        taxonomy_id: 999_999_999,
        native_type: "totally_not_a_type",
      },
    }

    assert_response :success
  end

  test "POST price_check denies access when the user does not own the product" do
    Flipper.enable(:price_checker)
    product = create_product(user: @seller)
    sign_in create_user

    post :price_check, params: { id: product.unique_permalink }
    assert_not response.successful?
  end

  # --- GET new ----------------------------------------------------------------

  test "GET new calls authorize with LinkPolicy for Link" do
    assert_authorize_called(:get, :new, record: Link)
  end

  test "GET new shows the introduction text if the user has no memberships or products" do
    @request.headers["X-Inertia"] = "true"
    get :new

    assert_response :success
    assert_equal "What are you creating?", @controller.send(:page_title)

    page = inertia_page
    assert_equal "Products/New", page["component"]

    ProductPresenter.new_page_props(current_seller: @seller).each do |key, value|
      assert_equal JSON.parse(value.to_json), page["props"][key.to_s]
    end

    assert_equal true, page["props"]["show_orientation_text"]
  end

  test "GET new does not show the introduction text if the user has memberships" do
    create_subscription_product(user: @seller)
    @request.headers["X-Inertia"] = "true"
    get :new

    assert_response :success
    assert_equal "What are you creating?", @controller.send(:page_title)

    page = inertia_page
    assert_equal "Products/New", page["component"]

    ProductPresenter.new_page_props(current_seller: @seller).each do |key, value|
      assert_equal JSON.parse(value.to_json), page["props"][key.to_s]
    end

    assert_equal false, page["props"]["show_orientation_text"]
  end

  test "GET new does not show the introduction text if the user has products" do
    create_product(user: @seller)
    @request.headers["X-Inertia"] = "true"
    get :new

    assert_response :success
    assert_equal "What are you creating?", @controller.send(:page_title)

    page = inertia_page
    assert_equal "Products/New", page["component"]

    ProductPresenter.new_page_props(current_seller: @seller).each do |key, value|
      assert_equal JSON.parse(value.to_json), page["props"][key.to_s]
    end

    assert_equal false, page["props"]["show_orientation_text"]
  end

  test "GET new marks mobile app web view when display=mobile_app" do
    @request.headers["X-Inertia"] = "true"
    get :new, params: { display: "mobile_app" }

    assert_response :success
    assert_equal true, inertia_page["props"]["is_mobile_app_web_view"]
  end

  # --- POST create ------------------------------------------------------------

  test "POST create calls authorize with LinkPolicy for Link" do
    Rails.cache.clear
    assert_authorize_called(:post, :create, record: Link)
  end

  test "POST create creates link with display_product_reviews set to true" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "test link" } }
    assert_redirected_to edit_link_path(Link.last)
    link = @seller.links.last
    assert_equal true, link.display_product_reviews
  end

  test "POST create redirects with an error instead of raising when price_cents is too large" do
    Rails.cache.clear
    too_large = BasePrice::Shared::MAX_PRICE_CENTS + 1

    assert_no_difference -> { @seller.links.count } do
      post :create, params: { link: { price_cents: too_large, name: "expensive" } }
    end

    assert_redirected_to new_product_path
    assert_equal "Sorry, the price entered is too large.", flash[:alert]
  end

  test "POST create redirects with an error instead of raising when price_range is too large" do
    Rails.cache.clear
    too_large_range = ((BasePrice::Shared::MAX_PRICE_CENTS / 100) + 1).to_s

    assert_no_difference -> { @seller.links.count } do
      post :create, params: { link: { name: "expensive", price_range: too_large_range } }
    end

    assert_redirected_to new_product_path
    assert_equal "Sorry, the price entered is too large.", flash[:alert]
  end

  test "POST create ignores is_in_preorder_state param" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "preorder", is_in_preorder_state: true, release_at: 1.year.from_now.iso8601 } }
    assert_redirected_to edit_link_path(Link.last)
    link = @seller.links.last
    assert_equal "preorder", link.name
    assert_equal 100, link.price_cents
    assert_equal false, link.reload.preorder_link.present?
  end

  test "POST create is able to set currency type" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "test link", url: nil, price_currency_type: "jpy" } }
    assert_redirected_to edit_link_path(Link.last)
    assert_equal "jpy", Link.last.price_currency_type
  end

  test "POST create creates the product if no files are provided" do
    Rails.cache.clear
    assert_difference -> { @seller.links.count }, 1 do
      post :create, params: { link: { price_cents: 100, name: "test link", files: {} } }
    end
  end

  test "POST create assigns 'other' taxonomy" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "test link" } }
    assert_redirected_to edit_link_path(Link.last)
    assert_equal Taxonomy.find_by(slug: "other"), Link.last.taxonomy
  end

  test "POST create sets is_bundle to true when the product's native type is bundle" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "Bundle", native_type: "bundle" } }
    assert_redirected_to edit_link_path(Link.last)

    product = Link.last
    assert_equal "bundle", product.native_type
    assert_equal true, product.is_bundle
  end

  test "POST create sets custom_button_text_option to donate_prompt for a coffee product" do
    Rails.cache.clear
    seller = create_eligible_seller
    sign_in_as_admin_for(seller)

    post :create, params: { link: { price_cents: 100, name: "Coffee", native_type: "coffee" } }
    assert_redirected_to edit_link_path(Link.last)

    product = Link.last
    assert_equal "coffee", product.native_type
    assert_equal "donate_prompt", product.custom_button_text_option
  end

  test "POST create defaults should_show_all_posts to true for recurring billing products" do
    Rails.cache.clear
    params = { price_cents: 100, name: "test link", is_recurring_billing: true }
    post :create, params: { link: params.merge(subscription_duration: "monthly") }
    assert_equal true, Link.last.should_show_all_posts

    post :create, params: { link: params.merge(is_recurring_billing: false) }
    assert_equal false, Link.last.should_show_all_posts
  end

  test "POST create sets is_recurring_billing correctly for monthly duration" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "test link", is_recurring_billing: true, subscription_duration: "monthly" } }
    assert_equal true, Link.last.is_recurring_billing
  end

  test "POST create sets the correct duration for monthly duration" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "test link", is_recurring_billing: true, subscription_duration: "monthly" } }
    assert_equal "monthly", Link.last.subscription_duration
  end

  test "POST create sets is_recurring_billing correctly for yearly duration" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "test link", is_recurring_billing: true, subscription_duration: "yearly" } }
    assert_equal true, Link.last.is_recurring_billing
  end

  test "POST create sets the correct duration for yearly duration" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "test link", is_recurring_billing: true, subscription_duration: "yearly" } }
    assert_equal "yearly", Link.last.subscription_duration
  end

  test "POST create allows users to create physical products when physical products are enabled" do
    Rails.cache.clear
    @seller.update!(can_create_physical_products: true)
    post :create, params: { link: { price_cents: 100, name: "test physical link", is_physical: true } }
    assert_redirected_to edit_link_path(Link.last)
    product = Link.last
    assert product.is_physical
    assert_equal false, product.skus_enabled
  end

  test "POST create returns forbidden when physical products are disabled" do
    Rails.cache.clear
    post :create, params: { link: { price_cents: 100, name: "test physical link", is_physical: true } }
    assert_response :forbidden
  end

  test "POST create does not enable community chat by default" do
    Rails.cache.clear

    post :create, params: { link: { price_cents: 100, name: "test link" } }

    assert_redirected_to edit_link_path(Link.last)
    product = @seller.links.last
    assert_equal false, product.community_chat_enabled?
    assert_nil product.active_community
  end

  test "POST create calls AI service when ai_prompt is present" do
    Rails.cache.clear
    ai_params = {
      name: "UX design mastery using Figma",
      description: "<p>Learn how to design user interfaces using Figma</p>",
      custom_summary: "Learn how to design user interfaces using Figma",
      number_of_content_pages: 2,
      ai_prompt: "Create an ebook on UX design using Figma",
      price_cents: 100,
      native_type: "ebook",
    }
    @seller.confirm
    User.any_instance.stubs(:sales_cents_total).returns(15_000)
    create_payment_completed(user: @seller)

    service_double = mock("Ai::ProductDetailsGeneratorService")
    Ai::ProductDetailsGeneratorService.stubs(:new).returns(service_double)
    service_double.stubs(:generate_cover_image).returns({ image_data: "fake_image_data" })
    service_double.stubs(:generate_rich_content_pages).returns({
                                                                 pages: [
                                                                   { "title" => "Introduction", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Welcome to the course" }] }] },
                                                                   { "title" => "Conclusion", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Thank you for reading this course" }] }] },
                                                                 ]
                                                               })
    ActiveStorage::Blob.stubs(:create_and_upload!).returns(nil)
    Link.any_instance.stubs(:asset_previews).returns(stub(build: nil))
    Link.any_instance.stubs(:build_thumbnail).returns(nil)

    post :create, params: { link: ai_params }

    assert_redirected_to edit_link_path(Link.last, ai_generated: true)

    link = Link.last
    assert_equal "UX design mastery using Figma", link.name
    assert_equal "<p>Learn how to design user interfaces using Figma</p>", link.description
    assert_equal "Learn how to design user interfaces using Figma", link.custom_summary
    assert_equal({ "name" => "Pages", "value" => "2" }, link.custom_attributes.sole)
    assert_equal 2, link.rich_contents.count
    assert_equal "Introduction", link.rich_contents.first.title
    assert_equal [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Welcome to the course" }] }], link.rich_contents.first.description
    assert_equal "Conclusion", link.rich_contents.last.title
    assert_equal [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Thank you for reading this course" }] }], link.rich_contents.last.description
  end

  test "POST create does not call AI service when ai_prompt is blank" do
    Rails.cache.clear
    @seller.confirm
    User.any_instance.stubs(:sales_cents_total).returns(15_000)
    create_payment_completed(user: @seller)

    service_double = mock("Ai::ProductDetailsGeneratorService")
    Ai::ProductDetailsGeneratorService.stubs(:new).returns(service_double)
    service_double.expects(:generate_cover_image).never
    service_double.expects(:generate_rich_content_pages).never

    post :create, params: { link: { price_cents: 100, name: "Regular Product" } }
  end

  test "POST create does not call AI service when the seller is not eligible for AI product generation" do
    Rails.cache.clear
    ai_params = {
      name: "UX design mastery using Figma",
      description: "<p>Learn how to design user interfaces using Figma</p>",
      custom_summary: "Learn how to design user interfaces using Figma",
      number_of_content_pages: 2,
      ai_prompt: "Create an ebook on UX design using Figma",
      price_cents: 100,
      native_type: "ebook",
    }
    @seller.confirm
    create_payment_completed(user: @seller)
    User.any_instance.stubs(:sales_cents_total).returns(0)

    service_double = mock("Ai::ProductDetailsGeneratorService")
    Ai::ProductDetailsGeneratorService.stubs(:new).returns(service_double)
    service_double.expects(:generate_cover_image).never
    service_double.expects(:generate_rich_content_pages).never

    post :create, params: { link: ai_params }

    assert_redirected_to edit_link_path(Link.last)
    assert_equal "UX design mastery using Figma", Link.last.name
  end

  test "POST create records add_product_mobile_app when the request is from the mobile app" do
    Rails.cache.clear
    session[:mobile_app_web_view] = true

    assert_difference -> { Event.where(event_name: "add_product_mobile_app").count }, 1 do
      post :create, params: { link: { price_cents: 100, name: "from app" } }
    end

    event = Event.where(event_name: "add_product_mobile_app").last
    assert_equal Link.last.id, event.link_id
    assert_equal @logged_in_user.id, event.user_id
  end

  test "POST create does not record add_product_mobile_app for a web request" do
    Rails.cache.clear

    assert_no_difference -> { Event.where(event_name: "add_product_mobile_app").count } do
      post :create, params: { link: { price_cents: 100, name: "from web" } }
    end
  end

  # --- POST release_preorder --------------------------------------------------

  def preorder_setup
    @preorder_product = create_product_with_pdf_file(user: @seller, is_in_preorder_state: true)
    create_rich_content(entity: @preorder_product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => @preorder_product.product_files.first.external_id, "uid" => SecureRandom.uuid } }])
    @preorder_link = create_preorder_link(link: @preorder_product, release_at: 3.days.from_now)
    @preorder_params = { id: @preorder_product.unique_permalink }
  end

  test "POST release_preorder calls authorize" do
    preorder_setup
    assert_authorize_called(:post, :release_preorder, record: @preorder_product, params: @preorder_params)
  end

  test "POST release_preorder allows a collaborator to access" do
    preorder_setup
    assert_collaborator_can_access(:post, :release_preorder, product: @preorder_product, params: @preorder_params, response_attributes: { "success" => true })
  end

  test "POST release_preorder returns the right success value" do
    preorder_setup
    PreorderLink.any_instance.stubs(:release!).returns(false)
    post :release_preorder, params: @preorder_params
    assert_equal false, response.parsed_body["success"]

    PreorderLink.any_instance.stubs(:release!).returns(true)
    post :release_preorder, params: @preorder_params
    assert_equal true, response.parsed_body["success"]
  end

  test "POST release_preorder releases the preorder even though the release date is in the future" do
    preorder_setup
    post :release_preorder, params: @preorder_params
    assert_equal true, response.parsed_body["success"]
    assert_equal true, @preorder_link.reload.released?
  end

  # --- POST send_sample_price_change_email ------------------------------------

  def sample_email_product
    @sample_email_product ||= create_membership_product(user: @seller)
  end

  def sample_email_tier
    @sample_email_tier ||= sample_email_product.default_tier
  end

  def sample_email_required_params
    {
      id: sample_email_product.unique_permalink,
      tier_id: sample_email_tier.external_id,
      amount: "7.50",
      recurrence: "yearly",
    }
  end

  test "POST send_sample_price_change_email calls authorize with the update policy" do
    assert_authorize_called(:post, :send_sample_price_change_email, record: sample_email_product, policy_method: :update?, params: sample_email_required_params)
  end

  test "POST send_sample_price_change_email returns an error if the tier ID is incorrect" do
    other_tier = create_variant
    post :send_sample_price_change_email, params: sample_email_required_params.merge(tier_id: other_tier.external_id)
    assert_equal false, response.parsed_body["success"]
    assert_equal "Not found", response.parsed_body["error"]
  end

  test "POST send_sample_price_change_email raises an error if required params are missing" do
    assert_raises(ActionController::ParameterMissing) do
      post :send_sample_price_change_email, params: { id: sample_email_product.unique_permalink, tier_id: sample_email_tier.external_id }
    end
  end

  test "POST send_sample_price_change_email sends a sample price change email to the user" do
    assert_enqueued_email_with(
      CustomerLowPriorityMailer,
      :sample_subscription_price_change_notification,
      args: [{
        user: @logged_in_user,
        tier: sample_email_tier,
        effective_date: Date.parse("2023-04-01"),
        recurrence: "yearly",
        new_price: 7_50,
        custom_message: "<p>hi!</p>",
      }]
    ) do
      post :send_sample_price_change_email, params: sample_email_required_params.merge(
        custom_message: "<p>hi!</p>",
        effective_date: "2023-04-01",
      )
    end
  end

  test "POST send_sample_price_change_email converts a decimal amount to exact cents" do
    assert_enqueued_email_with(
      CustomerLowPriorityMailer,
      :sample_subscription_price_change_notification,
      args: [{
        user: @logged_in_user,
        tier: sample_email_tier,
        effective_date: sample_email_tier.subscription_price_change_effective_date,
        recurrence: "yearly",
        new_price: 19_99,
        custom_message: nil,
      }]
    ) do
      post :send_sample_price_change_email, params: sample_email_required_params.merge(amount: "19.99")
    end
  end

  test "POST send_sample_price_change_email preserves single-unit currency amounts" do
    product = create_membership_product(user: @seller, price_currency_type: "jpy")
    tier = product.default_tier

    assert_enqueued_email_with(
      CustomerLowPriorityMailer,
      :sample_subscription_price_change_notification,
      args: [{
        user: @logged_in_user,
        tier:,
        effective_date: tier.subscription_price_change_effective_date,
        recurrence: "yearly",
        new_price: 199,
        custom_message: nil,
      }]
    ) do
      post :send_sample_price_change_email, params: {
        id: product.unique_permalink,
        tier_id: tier.external_id,
        amount: "199",
        recurrence: "yearly",
      }
    end
  end

  test "POST send_sample_price_change_email rejects malformed amounts" do
    assert_no_enqueued_emails do
      post :send_sample_price_change_email, params: sample_email_required_params.merge(amount: "1e1000000")
    end

    assert_response :unprocessable_entity
    assert_equal({ "success" => false, "error" => "Invalid amount" }, response.parsed_body)
  end

  # --- misc -------------------------------------------------------------------

  test "allows updating and publishing a product without files" do
    product = create_product(user: @seller, purchase_disabled_at: Time.current)

    assert_changes -> { product.reload.name }, from: product.name, to: "Test" do
      post :update, params: { id: product.unique_permalink, name: "Test" }, format: :json
    end

    assert_changes -> { product.reload.purchase_disabled_at }, to: nil do
      post :publish, params: { id: product.unique_permalink }
    end
    assert_equal true, response.parsed_body["success"]
    assert_equal 0, product.alive_product_files.count
  end
end

class LinksControllerUpdateTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers

  setup do
    sign_in_seller_area!
    @product = create_product_with_pdf_file(user: @seller)
    product_file = @product.product_files.alive.first
    @params = {
      id: @product.unique_permalink,
      name: "sumlink",
      description: "New description",
      custom_button_text_option: "pay_prompt",
      custom_summary: "summary",
      custom_view_content_button_text: "Get Your Files",
      custom_receipt_text: "Thank you for purchasing! Feel free to contact us any time for support.",
      custom_attributes: [{ name: "name", value: "value" }],
      file_attributes: [{ name: "Length", value: "10 sections" }],
      files: [{ id: product_file.external_id, url: product_file.url }],
      product_refund_policy_enabled: true,
      refund_policy: {
        max_refund_period_in_days: 7,
        fine_print: "Sample fine print",
      },
    }
  end

  test "PUT update calls authorize" do
    assert_authorize_called(:put, :update, record: @product, params: @params)
  end

  test "PUT update records edit_product_mobile_app when the request is from the mobile app" do
    session[:mobile_app_web_view] = true

    assert_difference -> { Event.where(event_name: "edit_product_mobile_app").count }, 1 do
      put :update, params: @params
    end

    assert_response :success
    event = Event.where(event_name: "edit_product_mobile_app").last
    assert_equal @product.id, event.link_id
    assert_equal @logged_in_user.id, event.user_id
  end

  test "PUT update does not record edit_product_mobile_app for a web request" do
    assert_no_difference -> { Event.where(event_name: "edit_product_mobile_app").count } do
      put :update, params: @params
    end
    assert_response :success
  end

  test "PUT update allows a collaborator to access" do
    # A successful save renders the id-mapping JSON (200), not an empty 204 —
    # the editor needs the canonical ids of records the save created.
    assert_collaborator_can_access(:put, :update, product: @product, params: @params, status: 200)
  end

  test "PUT update records redirects when the seller renames the product URL" do
    @product.update!(custom_permalink: "old-slug")

    put :update, params: @params.merge(custom_permalink: "new-slug"), as: :json

    assert_response :success
    assert_equal "new-slug", @product.reload.custom_permalink
    # The editor saves the product twice per request, so a commit-time
    # `saved_change_to_custom_permalink?` gate never fires here.
    assert_equal @product.id, ProductPermalinkRedirect.find_by(seller_id: @seller.id, permalink: "old-slug")&.product_id
    assert_equal @product.id, LegacyPermalink.find_by(permalink: "old-slug")&.product_id
    assert_equal @product, Link.fetch_leniently("old-slug", user: @seller)
  end

  test "PUT update writes no redirects when the product URL is untouched" do
    @product.update!(custom_permalink: "kept-slug")

    assert_no_difference -> { LegacyPermalink.count } do
      assert_no_difference -> { ProductPermalinkRedirect.count } do
        put :update, params: @params, as: :json
      end
    end

    assert_response :success
    assert_equal "kept-slug", @product.reload.custom_permalink
  end

  test "PUT update returns the existing validation error when suggested price is set but the default price record is missing" do
    @product.prices.destroy_all
    @product.update_column(:customizable_price, true)

    put :update, params: @params.merge(suggested_price: "10", customizable_price: true), as: :json

    assert_response :unprocessable_entity
    assert_equal "Default price cents can't be blank", response.parsed_body["error_message"]
    assert_nil @product.reload.suggested_price_cents
  end

  test "PUT update reconciles a stale dead cross-product file embed before the next save" do
    own_file = @product.product_files.alive.first
    foreign_product = create_product(user: @seller)
    dead_foreign_file = create_product_file(link: foreign_product, deleted_at: Time.current)
    own_embed = { "type" => "fileEmbed", "attrs" => { "id" => own_file.external_id, "uid" => SecureRandom.uuid } }
    dead_foreign_embed = { "type" => "fileEmbed", "attrs" => { "id" => dead_foreign_file.external_id, "uid" => SecureRandom.uuid } }
    first_edit = { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "First edit" }] }
    rich_content = create_product_rich_content(entity: @product, description: [own_embed])
    rich_content.update_column(:description, [own_embed, dead_foreign_embed])
    submitted_content = [own_embed, dead_foreign_embed, first_edit]

    post :update, params: @params.merge(
      rich_content: [{
        id: rich_content.external_id,
        title: "Updated page",
        description: {
          type: "doc",
          content: submitted_content
        }
      }]
    ), format: :json

    assert_response :success
    removed_file_ids = response.parsed_body.dig("rich_content_removed_file_embed_ids", rich_content.external_id)
    assert_equal [dead_foreign_file.external_id], removed_file_ids
    assert_equal [own_file.id], rich_content.reload.embedded_product_file_ids_in_order
    assert_equal "First edit", rich_content.description.last.dig("content", 0, "text")

    # This is the browser's post-save state: it applies the returned ids to the
    # same document it just submitted, then keeps editing without a reload.
    reconciled_content = RichContent.reject_file_embeds(
      submitted_content,
      removed_file_ids.map { ObfuscateIds.decrypt(_1) }.to_set
    )
    second_edit = { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Second edit" }] }
    post :update, params: @params.merge(
      rich_content: [{
        id: rich_content.external_id,
        title: "Updated page again",
        description: {
          type: "doc",
          content: [*reconciled_content, second_edit]
        }
      }]
    ), format: :json

    assert_response :success
    assert_equal [own_file.id], rich_content.reload.embedded_product_file_ids_in_order
    assert_equal %w[First\ edit Second\ edit], rich_content.description.filter_map { _1.dig("content", 0, "text") }
  end

  test "PUT update infers a stale-embed move from an already-open editor tab" do
    category = create_variant_category(link: @product, title: "Versions")
    version = create_variant(variant_category: category, name: "Version 1")
    foreign_product = create_product(user: @seller)
    dead_foreign_file = create_product_file(link: foreign_product, deleted_at: Time.current)
    dead_foreign_embed = { "type" => "fileEmbed", "attrs" => { "id" => dead_foreign_file.external_id, "uid" => SecureRandom.uuid } }
    paragraph = { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Keep me" }] }
    source = create_product_rich_content(entity: @product, description: [paragraph])
    source.update_column(:description, [dead_foreign_embed, paragraph])
    @product.update!(has_same_rich_content_for_all_variants: true)

    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [{
        id: version.external_id,
        name: version.name,
        rich_content: [{
          id: source.external_id,
          title: "Moved page",
          description: { type: "doc", content: [dead_foreign_embed, paragraph] }
        }]
      }]
    ), format: :json

    assert_response :success
    destination = version.reload.alive_rich_contents.sole
    assert_equal [paragraph], destination.description
    assert_equal true, source.reload.deleted?
    assert_equal [dead_foreign_file.external_id],
                 response.parsed_body.dig("rich_content_removed_file_embed_ids", destination.external_id)
  end

  test "PUT update repairs a stale embed when copying a page between versions" do
    category = create_variant_category(link: @product, title: "Versions")
    source_version = create_variant(variant_category: category, name: "Source")
    destination_version = create_variant(variant_category: category, name: "Destination")
    foreign_product = create_product(user: @seller)
    dead_foreign_file = create_product_file(link: foreign_product, deleted_at: Time.current)
    dead_foreign_embed = { "type" => "fileEmbed", "attrs" => { "id" => dead_foreign_file.external_id, "uid" => SecureRandom.uuid } }
    paragraph = { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Keep me" }] }
    source = create_rich_content(entity: source_version, description: [paragraph])
    source.update_column(:description, [dead_foreign_embed, paragraph])
    client_page_id = SecureRandom.uuid
    @product.update!(has_same_rich_content_for_all_variants: false)

    post :update, params: @params.merge(
      rich_content_provenance_version: 1,
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [
        {
          id: source_version.external_id,
          name: source_version.name,
          rich_content: [{
            id: source.external_id,
            title: "Source page",
            description: { type: "doc", content: [dead_foreign_embed, paragraph] }
          }]
        },
        {
          id: destination_version.external_id,
          name: destination_version.name,
          rich_content: [{
            id: client_page_id,
            source_id: source.external_id,
            title: "Copied page",
            description: { type: "doc", content: [dead_foreign_embed, paragraph] }
          }]
        }
      ]
    ), format: :json

    assert_response :success
    destination = destination_version.reload.alive_rich_contents.sole
    assert_equal [paragraph], source.reload.description
    assert_equal [paragraph], destination.description
    assert_equal destination.external_id, response.parsed_body.dig("rich_content_id_mappings", client_page_id)
    assert_equal [dead_foreign_file.external_id],
                 response.parsed_body.dig("rich_content_removed_file_embed_ids", destination.external_id)
  end

  test "PUT update repairs a stale embed copied by an already-open editor tab" do
    category = create_variant_category(link: @product, title: "Versions")
    source_version = create_variant(variant_category: category, name: "Source")
    destination_version = create_variant(variant_category: category, name: "Destination")
    foreign_product = create_product(user: @seller)
    dead_foreign_file = create_product_file(link: foreign_product, deleted_at: Time.current)
    dead_foreign_embed = { "type" => "fileEmbed", "attrs" => { "id" => dead_foreign_file.external_id, "uid" => SecureRandom.uuid } }
    paragraph = { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Keep me" }] }
    source = create_rich_content(entity: source_version, description: [paragraph])
    source.update_column(:description, [dead_foreign_embed, paragraph])
    client_page_id = SecureRandom.uuid
    @product.update!(has_same_rich_content_for_all_variants: false)

    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [
        {
          id: source_version.external_id,
          name: source_version.name,
          rich_content: [{
            id: source.external_id,
            title: "Source page",
            description: { type: "doc", content: [dead_foreign_embed, paragraph] }
          }]
        },
        {
          id: destination_version.external_id,
          name: destination_version.name,
          rich_content: [{
            id: client_page_id,
            title: "Copied page",
            description: { type: "doc", content: [dead_foreign_embed, paragraph] }
          }]
        }
      ]
    ), format: :json

    assert_response :success
    destination = destination_version.reload.alive_rich_contents.sole
    assert_equal [paragraph], source.reload.description
    assert_equal [paragraph], destination.description
    assert_equal destination.external_id, response.parsed_body.dig("rich_content_id_mappings", client_page_id)
    assert_equal [dead_foreign_file.external_id],
                 response.parsed_body.dig("rich_content_removed_file_embed_ids", destination.external_id)
  end

  test "PUT update does not apply old-tab copy fallback to a provenance-aware request" do
    foreign_product = create_product(user: @seller)
    dead_foreign_file = create_product_file(link: foreign_product, deleted_at: Time.current)
    dead_foreign_embed = { "type" => "fileEmbed", "attrs" => { "id" => dead_foreign_file.external_id, "uid" => SecureRandom.uuid } }
    source = create_product_rich_content(entity: @product, description: [])
    source.update_column(:description, [dead_foreign_embed])

    post :update, params: @params.merge(
      rich_content_provenance_version: 1,
      rich_content: [
        {
          id: source.external_id,
          title: "Source page",
          description: { type: "doc", content: [dead_foreign_embed] }
        },
        {
          id: SecureRandom.uuid,
          title: "Unproven copy",
          description: { type: "doc", content: [dead_foreign_embed] }
        }
      ]
    ), format: :json

    assert_response :unprocessable_entity
    assert_includes response.parsed_body["error_message"], "not belonging to this product"
    assert_equal [dead_foreign_file.id], source.reload.embedded_product_file_ids_in_order
    assert_equal 1, @product.reload.alive_rich_contents.count
  end

  test "PUT update does not accept stale-embed provenance from another product" do
    source_product = create_product(user: @seller)
    file_product = create_product(user: @seller)
    dead_foreign_file = create_product_file(link: file_product, deleted_at: Time.current)
    dead_foreign_embed = { "type" => "fileEmbed", "attrs" => { "id" => dead_foreign_file.external_id, "uid" => SecureRandom.uuid } }
    source = create_product_rich_content(entity: source_product, description: [])
    source.update_column(:description, [dead_foreign_embed])

    post :update, params: @params.merge(
      rich_content: [{
        id: SecureRandom.uuid,
        source_id: source.external_id,
        title: "Invalid copy",
        description: { type: "doc", content: [dead_foreign_embed] }
      }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_includes response.parsed_body["error_message"], "not belonging to this product"
    assert_equal 0, @product.reload.alive_rich_contents.count
  end

  test "POST publish includes error_message when publishing and user email is empty" do
    @seller.email = ""
    @seller.save(validate: false)

    post :publish, params: { id: @product.unique_permalink }
    assert_equal false, response.parsed_body["success"]
    assert_equal "<span>To publish a product, we need you to have an email. <a href=\"#{settings_main_url}\">Set an email</a> to continue.</span>", response.parsed_body["error_message"]
  end

  # --- licenses ---------------------------------------------------------------

  test "PUT update sets is_licensed to true when license key is embedded in the product-level rich content" do
    assert_equal false, @product.is_licensed

    post :update, params: @params.merge(rich_content: [{ id: nil, title: "Page title", description: { type: "doc", content: [{ "type" => "licenseKey" }] } }]), format: :json

    assert_equal true, @product.reload.is_licensed
  end

  test "PUT update sets is_licensed to true when license key is embedded in the rich content of at least one version" do
    category = create_variant_category(link: @product, title: "Versions")
    version1 = create_variant(variant_category: category, name: "Version 1")
    version2 = create_variant(variant_category: category, name: "Version 2")
    version1_rich_content1 = create_rich_content(entity: version1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
    version1_rich_content1_updated_description = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Hello" }] }, { type: "licenseKey" }] }
    version2_new_rich_content_description = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Newly added version 2 content" }] }] }

    assert_equal false, @product.is_licensed

    post :update, params: @params.merge(
      variants: [
        { id: version1.external_id, name: version1.name, rich_content: [{ id: version1_rich_content1.external_id, title: "Version 1 - Page 1", description: version1_rich_content1_updated_description }] },
        { id: version2.external_id, name: version2.name, rich_content: [{ id: nil, title: "Version 2 - Page 1", description: version2_new_rich_content_description }] }
      ]
    ), format: :json

    assert_equal true, @product.reload.is_licensed
  end

  test "PUT update sets is_licensed to false when no license key is embedded in the rich content" do
    assert_equal false, @product.is_licensed

    post :update, params: @params.merge(rich_content: [{ id: nil, title: "Page title", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Hello" }] }] } }]), format: :json

    assert_equal false, @product.reload.is_licensed
  end

  # --- content deletion guards (blind-payload wipe protection) ----------------
  # Ported from the PR-6178 additions to spec/controllers/links_controller_spec.rb
  # (that spec has since moved here — see #6145). Reproduces gumroad-private#1230:
  # one production product had its content wiped three times in nine days (July
  # 13, 18 and 21, 2026) by save payloads that didn't know about its
  # variants/pages; without the guards such a save silently soft-deletes the
  # entire version tree and content. The July 21 payload was server-induced —
  # support restored per-version pages while has_same_rich_content_for_all_variants
  # stayed on, so a fresh editor load received empty variant content (see the
  # dedicated "July 21" tests below). The July 13/18 client-side trigger was
  # never identified, so these tests cover payload shapes, not one specific
  # trigger.

  def guard_content_description
    [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Course content" }] }]
  end

  def setup_guarded_version!
    @category = create_variant_category(link: @product, title: "Versions")
    @version1 = create_variant(variant_category: @category, name: "Summer Sale")
    @version1_page = create_rich_content(entity: @version1, description: guard_content_description)
  end

  test "PUT update blocks a save whose payload omits a content-bearing variant" do
    setup_guarded_version!

    # The blind payload only knows about a different, new variant — the
    # server would previously treat version1 as removed and wipe it.
    post :update, params: @params.merge(variants: [{ id: nil, name: "Brand new version" }]), format: :json

    assert_response :unprocessable_entity
    assert_includes response.parsed_body["error_message"], "refresh the page"
    assert_equal false, @version1.reload.deleted?
    assert_equal false, @version1_page.reload.deleted?
  end

  test "PUT update blocks a save with an empty variants list that would delete the whole category" do
    setup_guarded_version!

    post :update, params: @params.merge(variants: []), format: :json

    assert_response :unprocessable_entity
    assert_equal false, @version1.reload.deleted?
    assert_equal false, @version1_page.reload.deleted?
    assert_equal false, @category.reload.deleted?
  end

  test "PUT update allows removing a content-bearing variant when the seller confirmed the removal" do
    setup_guarded_version!

    post :update, params: @params.merge(
      variants: [{ id: nil, name: "Brand new version" }],
      confirmed_removed_variant_ids: [@version1.external_id]
    ), format: :json

    assert_response :success
    assert_equal true, @version1.reload.deleted?
  end

  test "PUT update allows removing a variant that has no content without confirmation" do
    setup_guarded_version!
    empty_version = create_variant(variant_category: @category, name: "Empty version")

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
    assert_equal true, empty_version.reload.deleted?
    assert_equal false, @version1.reload.deleted?
  end

  test "PUT update blocks a save whose payload omits a configured contentless variant" do
    setup_guarded_version!
    # No content pages or files, but a real custom price — the kind of
    # configured-but-contentless variant gumroad-private#1296 covers.
    priced_version = create_variant(variant_category: @category, name: "Priced version", price_difference_cents: 500)

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal false, priced_version.reload.deleted?
  end

  test "PUT update blocks a save whose payload omits a purchased contentless variant" do
    setup_guarded_version!
    purchased_version = create_variant(variant_category: @category, name: "Purchased version")
    purchase = create_purchase(link: @product, purchase_state: "successful")
    purchase.variant_attributes << purchased_version

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal false, purchased_version.reload.deleted?
  end

  test "PUT update allows removing a configured contentless variant when the seller confirmed the removal" do
    setup_guarded_version!
    priced_version = create_variant(variant_category: @category, name: "Priced version", price_difference_cents: 500)

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", description: { type: "doc", content: guard_content_description } }] }],
      confirmed_removed_variant_ids: [priced_version.external_id]
    ), format: :json

    assert_response :success
    assert_equal true, priced_version.reload.deleted?
  end

  test "PUT update blocks a save whose payload omits a content-bearing page" do
    setup_guarded_version!
    page2 = create_rich_content(entity: @version1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Page 2" }] }])

    # Payload keeps the variant but only knows about one of its two pages.
    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page 1", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal false, page2.reload.deleted?
    assert_equal false, @version1_page.reload.deleted?
  end

  test "PUT update allows deleting a page when the seller confirmed the deletion" do
    setup_guarded_version!
    page2 = create_rich_content(entity: @version1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Page 2" }] }])

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page 1", description: { type: "doc", content: guard_content_description } }] }],
      confirmed_removed_rich_content_ids: [page2.external_id]
    ), format: :json

    assert_response :success
    assert_equal true, page2.reload.deleted?
  end

  test "PUT update allows deleting a page with no content without confirmation" do
    setup_guarded_version!
    blank_page = create_rich_content(entity: @version1, description: [])

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page 1", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
    assert_equal true, blank_page.reload.deleted?
  end

  test "PUT update allows replacing a page when its content is resubmitted under a new id" do
    # Editor sessions predating the id reconciliation in the save response
    # keep their client-generated page ids across saves, so the second save of
    # such a page arrives under an unknown id and the server re-creates it.
    # That's a rewrite, not a deletion — the guard must let it through even
    # though the stored page's id is missing from the payload.
    setup_guarded_version!

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: "client-generated-uuid", title: "Page 1", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
    assert_equal 1, @version1.reload.alive_rich_contents.count
    assert_equal guard_content_description, @version1.alive_rich_contents.sole.description
  end

  test "PUT update still blocks an outdated payload that resubmits different content under a new id" do
    # The rewrite allowance matches on CONTENT — an outdated payload that submits its
    # own (different) page under a fresh id must not unlock deleting the
    # stored content-bearing page.
    setup_guarded_version!

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: "client-generated-uuid", title: "Other page", description: { type: "doc", content: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Unrelated stale content" }] }] } }] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal false, @version1_page.reload.deleted?
  end

  test "PUT update blocks an outdated payload that omits one of two duplicate-content pages" do
    # Two stored pages can legitimately carry identical content (e.g. the
    # seller duplicated a page). An outdated payload that keeps one twin under its
    # known id but omits the other must not pass the rewrite allowance — the
    # kept page is an in-place update of itself, not a rewrite of the omitted
    # one.
    setup_guarded_version!
    duplicate_page = create_rich_content(entity: @version1, description: guard_content_description)

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page 1", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal false, duplicate_page.reload.deleted?
    assert_equal false, @version1_page.reload.deleted?
  end

  test "PUT update blocks an outdated payload where one unknown-id page matches two omitted duplicate-content pages" do
    # The rewrite allowance is count-aware: a single resubmitted unknown-id
    # page can account for at most one omitted stored page. When two stored
    # duplicate-content pages are both omitted, one unknown-id twin in the
    # payload must not unlock deleting both.
    setup_guarded_version!
    create_rich_content(entity: @version1, description: guard_content_description)

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: "client-generated-uuid", title: "Page 1", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal 2, @version1.reload.alive_rich_contents.count
  end

  test "PUT update blocks an outdated payload where one unknown-id page matches omitted duplicate-content pages across the product and a variant" do
    # The rewrite allowance is shared across the whole save request: the guard
    # runs once for the product-level pages and once per variant, and a single
    # resubmitted unknown-id page must not authorize one deletion in EACH of
    # those scopes. Here duplicate content exists both as a product-level page
    # and as a variant page, both are omitted, and the payload resubmits the
    # content once under an unknown id — only one rewrite is covered, so the
    # save must be blocked.
    setup_guarded_version!
    duplicated_content = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Shared across scopes" }] }]
    product_page = create_product_rich_content(entity: @product, description: duplicated_content)
    variant_page = create_rich_content(entity: @version1, description: duplicated_content)

    post :update, params: @params.merge(
      rich_content: [{ id: "client-generated-uuid", title: "Twin", description: { type: "doc", content: duplicated_content } }],
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page 1", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal false, product_page.reload.deleted?
    assert_equal false, variant_page.reload.deleted?
  end

  test "PUT update allows deleting a page holding only the editor's blank placeholder paragraph without confirmation" do
    setup_guarded_version!
    # The editor initializes every new page with a single empty paragraph,
    # so a structurally-blank page must count as contentless — otherwise
    # cleaning up never-used pages would trip the deletion guard.
    placeholder_page = create_rich_content(entity: @version1, description: [{ "type" => "paragraph" }])

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page 1", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
    assert_equal true, placeholder_page.reload.deleted?
  end

  test "PUT update allows removing a variant whose only page is a blank placeholder without confirmation" do
    setup_guarded_version!
    placeholder_version = create_variant(variant_category: @category, name: "Placeholder version")
    create_rich_content(entity: placeholder_version, description: [{ "type" => "paragraph" }])

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
    assert_equal true, placeholder_version.reload.deleted?
    assert_equal false, @version1.reload.deleted?
  end

  test "PUT update allows a page to move between the product level and a variant without confirmation" do
    setup_guarded_version!

    # Toggling "use the same content for all versions" legitimately moves
    # pages from the variant to the product level — the page id appears
    # elsewhere in the payload, so it isn't a deletion.
    post :update, params: @params.merge(
      rich_content: [{ id: @version1_page.external_id, title: "Moved page", description: { type: "doc", content: guard_content_description } }],
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [] }]
    ), format: :json

    assert_response :success
  end

  test "PUT update blocks deleting a product-level content page missing from an outdated payload" do
    setup_guarded_version!
    product_page = create_product_rich_content(entity: @product, description: guard_content_description)

    post :update, params: @params.merge(
      rich_content: [{ id: nil, title: "Other page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Other" }] }] } }],
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page 1", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal false, product_page.reload.deleted?
  end

  test "PUT update reports blocked wipes to the error notifier" do
    setup_guarded_version!
    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(variants: []), format: :json

    assert notified.any? { |message, context| message == "Blocked product save that would delete configured, purchased, or content-bearing variants without confirmation" && context[:product_id] == @product.id },
           "Expected ErrorNotifier to be notified about the blocked wipe (got: #{notified.inspect})"
  end

  test "PUT update includes non-PII diagnostics in the blocked-save notification" do
    setup_guarded_version!
    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [] }]
    ), format: :json

    assert_response :unprocessable_entity
    _message, context = notified.find { |message, _| message.include?("delete content pages") }
    assert_not_nil context, "Expected a blocked-save notification (got: #{notified.inspect})"
    assert_equal 1, context[:submitted_variant_count]
    assert_equal 1, context[:alive_variant_count]
    assert_equal 0, context[:submitted_page_count]
    assert_equal 1, context[:alive_page_count]
    assert_equal false, context[:persisted_has_same_rich_content_for_all_variants]
    assert_nil context[:submitted_has_same_rich_content_for_all_variants]
  end

  test "PUT update blocks deleting a title-only page missing from the payload" do
    # A page can carry nothing but a title (its body is an empty paragraph).
    # That title is seller-authored work and renders in the buyer's page list,
    # so such a page must NOT be treated as a freely deletable blank.
    setup_guarded_version!
    title_only_page = create_rich_content(entity: @version1, title: "Bonus resources", description: [{ "type" => "paragraph" }])

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page 1", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal false, title_only_page.reload.deleted?
  end

  # --- canonical id reconciliation (create → save → edit → save) --------------
  # The editor creates pages/variants under client-generated ids. The save
  # response must map those to the canonical server ids, otherwise the next
  # save (without a reload) resubmits them under ids the server doesn't know —
  # re-creating records and, once the content was edited in between, tripping
  # the deletion guard with a 422.

  test "PUT update returns canonical id mappings for pages created in the editor session, and the reconciled follow-up save edits the same page" do
    post :update, params: @params.merge(
      rich_content: [{ id: "client-page-guid", title: "New page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Draft" }] }] } }]
    ), format: :json

    assert_response :success
    page = @product.reload.alive_rich_contents.sole
    assert_equal page.external_id, response.parsed_body["rich_content_id_mappings"]["client-page-guid"]

    # Second save without a reload: the editor swapped in the canonical id and
    # the seller edited the page. Before the reconciliation this 422'd — the
    # unknown-id resubmission no longer matched the rewrite allowance once the
    # content changed.
    post :update, params: @params.merge(
      rich_content: [{ id: page.external_id, title: "New page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Draft, edited" }] }] } }]
    ), format: :json

    assert_response :success
    assert_equal 1, @product.reload.alive_rich_contents.count
    assert_equal [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Draft, edited" }] }], page.reload.description
  end

  test "PUT update returns canonical id mappings for variants created in the editor session, and repeated saves keep a single variant" do
    post :update, params: @params.merge(
      variants: [{ id: nil, client_id: "client-variant-guid", name: "Version 1", rich_content: [{ id: "client-page-guid", title: nil, description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
    variant = @product.reload.alive_variants.sole
    assert_equal variant.external_id, response.parsed_body["variant_id_mappings"]["client-variant-guid"]
    page = variant.alive_rich_contents.sole
    assert_equal page.external_id, response.parsed_body["rich_content_id_mappings"]["client-page-guid"]

    # Second save without a reload, edited content, canonical ids swapped in —
    # must update the same variant in place rather than re-creating it (or
    # rejecting the save because the original would lose its content).
    post :update, params: @params.merge(
      variants: [{ id: variant.external_id, name: "Version 1 renamed", rich_content: [{ id: page.external_id, title: nil, description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Edited content" }] }] } }] }]
    ), format: :json

    assert_response :success
    assert_equal [variant.id], @product.reload.alive_variants.ids
    assert_equal "Version 1 renamed", variant.reload.name
    assert_equal [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Edited content" }] }], page.reload.description
  end

  # --- stale-snapshot overwrite guard (gumroad-private#1295) -------------------
  # The editor submits the full product on every save, so a session working
  # from an outdated snapshot resubmits existing page/variant ids carrying old
  # data. Those are plain in-place updates — the deletion guards above never
  # fire — and they silently revert whatever a newer session saved. The editor
  # echoes each page's/variant's served updated_at; the server rejects the
  # save with a structured conflict when a stored row changed after the
  # snapshot, before anything is mutated. Each "two-session" test simulates
  # session A loading (capturing snapshot timestamps), session B saving
  # (bumping the rows), then session A saving from its stale snapshot.
  #
  # The seller-visible rejection is OFF by default in production: enforcing it
  # blocked hundreds of legitimate saves because the timestamps the editor
  # echoes aren't yet trustworthy (see Product::StaleContentWriteGuard's class
  # comment). The tests that assert the 409 therefore turn the flag on
  # explicitly via enforce_stale_content_block!, and the tests below them cover
  # the DEFAULT (flag off) behavior — which is what production runs today.

  # Turns on the seller-blocking 409 path for tests that assert it. Without
  # this, a stale save is detected and reported but allowed through.
  def enforce_stale_content_block!
    Feature.activate(Product::StaleContentWriteGuard::BLOCK_FEATURE_NAME)
  end

  test "PUT update rejects a two-session page overwrite: a save echoing a stale page snapshot cannot replace content saved in between" do
    enforce_stale_content_block!
    setup_guarded_version!
    stale_snapshot = @version1_page.updated_at.as_json
    newer_content = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Session B's newer content" }] }]

    # Session B saves newer content after session A loaded.
    travel 1.minute
    @version1_page.update!(description: newer_content)

    # Session A saves old content under the same page id, echoing its stale
    # snapshot timestamp.
    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: stale_snapshot, description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :conflict
    assert_equal "stale_content_conflict", response.parsed_body["error_code"]
    assert_includes response.parsed_body["error_message"], "reload the page"
    assert_equal [{ "type" => "page", "id" => @version1_page.external_id, "name" => nil }],
                 response.parsed_body["stale_records"].map { _1.slice("type", "id", "name") }
    assert_equal newer_content, @version1_page.reload.description
  end

  test "PUT update rejects a two-session product-level page overwrite" do
    enforce_stale_content_block!
    product_page = create_rich_content(entity: @product, description: guard_content_description, title: "Shared page")
    stale_snapshot = product_page.updated_at.as_json
    newer_content = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Session B's newer content" }] }]

    travel 1.minute
    product_page.update!(description: newer_content)

    post :update, params: @params.merge(
      rich_content: [{ id: product_page.external_id, title: "Shared page", updated_at: stale_snapshot, description: { type: "doc", content: guard_content_description } }]
    ), format: :json

    assert_response :conflict
    assert_equal "stale_content_conflict", response.parsed_body["error_code"]
    assert_equal newer_content, product_page.reload.description
  end

  test "PUT update rejects a two-session variant overwrite: a save echoing a stale variant snapshot cannot revert attributes saved in between" do
    enforce_stale_content_block!
    setup_guarded_version!
    stale_snapshot = @version1.updated_at.as_json

    # Session B renames the variant after session A loaded.
    travel 1.minute
    @version1.update!(name: "Session B's newer name")

    # Session A submits the old name, echoing its stale variant snapshot.
    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: "Summer Sale", updated_at: stale_snapshot, rich_content: [{ id: @version1_page.external_id, title: "Page", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :conflict
    assert_equal "stale_content_conflict", response.parsed_body["error_code"]
    assert_equal [{ "type" => "variant", "id" => @version1.external_id, "name" => "Session B's newer name" }],
                 response.parsed_body["stale_records"].map { _1.slice("type", "id", "name") }
    assert_equal "Session B's newer name", @version1.reload.name
  end

  test "PUT update rejects a stale save before mutating ANY part of the payload" do
    enforce_stale_content_block!
    setup_guarded_version!
    stale_snapshot = @version1_page.updated_at.as_json
    original_name = @product.name

    travel 1.minute
    @version1_page.update!(description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newer" }] }])

    post :update, params: @params.merge(
      name: "Renamed by the stale session",
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: stale_snapshot, description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :conflict
    assert_equal original_name, @product.reload.name
  end

  test "PUT update sends a Sentry notification alongside the stale-save rejection" do
    enforce_stale_content_block!
    setup_guarded_version!
    stale_snapshot = @version1_page.updated_at.as_json
    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    travel 1.minute
    @version1_page.update!(description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newer" }] }])

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: stale_snapshot, description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :conflict
    message, context = notified.find { |m, _| m.include?("stale snapshot") }
    assert_not_nil message, "Expected a stale-save notification (got: #{notified.inspect})"
    assert_equal @product.id, context[:product_id]
    assert_equal [@version1_page.external_id], context[:stale_page_external_ids]
  end

  test "PUT update allows a save echoing the CURRENT snapshot timestamps and refreshes them in the response" do
    enforce_stale_content_block!
    setup_guarded_version!
    updated_content = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Edited by this session" }] }]

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, updated_at: @version1.updated_at.as_json, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: @version1_page.updated_at.as_json, description: { type: "doc", content: updated_content } }] }]
    ), format: :json

    assert_response :success
    assert_equal updated_content, @version1_page.reload.description
    # The response reports the fresh post-save timestamps so the session's
    # NEXT save echoes them instead of the pre-save ones (which would now
    # reject the session's own follow-up save as stale).
    fresh_timestamp = response.parsed_body["rich_content_updated_at"][@version1_page.external_id]
    assert_equal @version1_page.updated_at.to_i, Time.zone.parse(fresh_timestamp).to_i
    assert response.parsed_body["variant_updated_at"].key?(@version1.external_id)

    # Echoing the refreshed timestamps, the follow-up save succeeds.
    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, updated_at: response.parsed_body["variant_updated_at"][@version1.external_id], rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: fresh_timestamp, description: { type: "doc", content: updated_content } }] }]
    ), format: :json

    assert_response :success
  end

  # The freshness check has to run while this request holds the product row
  # lock, otherwise two saves that each echo the same (at-request-time fresh)
  # timestamps both pass the check and the last writer silently overwrites the
  # other — the exact overwrite the guard exists to stop. This test drives that
  # ordering: the concurrent save is committed at the moment the request
  # acquires the lock (`SELECT ... FOR UPDATE` on the product row), which is
  # where a real second request would have been unblocked. The check must
  # therefore read the post-lock state and reject, even though the echoed
  # timestamps were current when the request started.
  test "PUT update checks freshness while holding the product row lock, so a save committed just before the lock is honored" do
    enforce_stale_content_block!
    setup_guarded_version!
    snapshot_current_at_request_time = @version1_page.updated_at.as_json
    concurrent_content = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Committed by the concurrent save" }] }]

    locked_product_row = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next if locked_product_row
      next unless payload[:sql].to_s.include?("FOR UPDATE") && payload[:sql].to_s.include?("`links`")
      locked_product_row = true
      travel 1.minute
      @version1_page.update!(description: concurrent_content)
    end

    begin
      post :update, params: @params.merge(
        variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: snapshot_current_at_request_time, description: { type: "doc", content: guard_content_description } }] }]
      ), format: :json
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert locked_product_row, "Expected the save to lock the product row (SELECT ... FOR UPDATE) before checking freshness"
    assert_response :conflict
    assert_equal "stale_content_conflict", response.parsed_body["error_code"]
  end

  test "PUT update does NOT reject a save whose variant row was only touched by a buyer's purchase" do
    enforce_stale_content_block!
    setup_guarded_version!
    @version1.update!(max_purchase_count: 100)
    stale_variant_snapshot = @version1.reload.updated_at.as_json
    page_snapshot = @version1_page.updated_at.as_json

    # Every sale of a limited-quantity variant touches the variant row to bust
    # the product cache (Purchase#touch_variants_if_limited_quantity). That
    # bumps updated_at without changing anything the seller edits, so a save
    # from a session that loaded before the sale has no newer seller content to
    # overwrite and must still go through.
    travel 1.minute
    @version1.touch

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, updated_at: stale_variant_snapshot, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: page_snapshot, description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
  end

  # Membership tier prices are rows in a separate table (VariantPrice) and
  # saving them does not bump the tier row's own updated_at, so the tier row's
  # timestamp alone would let a stale full save silently revert a price another
  # session had just changed.
  test "PUT update rejects a two-session membership tier price overwrite: a stale save cannot revert a tier price saved in between" do
    enforce_stale_content_block!
    product = create_membership_product_with_preset_tiered_pricing(user: @seller)
    first_tier = product.tiers.find_by!(name: "First Tier")
    second_tier = product.tiers.find_by!(name: "Second Tier")
    stale_snapshot = Product::StaleContentWriteGuard.snapshot_at(first_tier).as_json

    # Session B raises the tier's monthly price after session A loaded. Only
    # the price row changes — the tier row itself is untouched.
    travel 1.minute
    first_tier.save_recurring_prices!(monthly: { enabled: true, price_cents: 2500 })

    # Session A resubmits the price it was served, echoing its stale snapshot.
    post :update, params: {
      id: product.unique_permalink,
      name: product.name,
      variants: [
        { id: first_tier.external_id, name: first_tier.name, updated_at: stale_snapshot,
          recurrence_price_values: { monthly: { enabled: true, price_cents: 300 } } },
        { id: second_tier.external_id, name: second_tier.name,
          updated_at: Product::StaleContentWriteGuard.snapshot_at(second_tier).as_json,
          recurrence_price_values: { monthly: { enabled: true, price_cents: 500 } } },
      ]
    }, format: :json

    assert_response :conflict
    assert_equal "stale_content_conflict", response.parsed_body["error_code"]
    assert_equal [{ "type" => "variant", "id" => first_tier.external_id, "name" => "First Tier" }],
                 response.parsed_body["stale_records"].map { _1.slice("type", "id", "name") }
    assert_equal 2500, first_tier.reload.alive_prices.is_buy.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).price_cents
  end

  test "PUT update lets a session change a membership tier price and save again, because the response refreshes the tier's price-aware snapshot" do
    enforce_stale_content_block!
    product = create_membership_product_with_preset_tiered_pricing(user: @seller)
    first_tier = product.tiers.find_by!(name: "First Tier")
    second_tier = product.tiers.find_by!(name: "Second Tier")
    tier_params = ->(snapshots) do
      [
        { id: first_tier.external_id, name: first_tier.name, updated_at: snapshots[first_tier.external_id],
          recurrence_price_values: { monthly: { enabled: true, price_cents: 900 } } },
        { id: second_tier.external_id, name: second_tier.name, updated_at: snapshots[second_tier.external_id],
          recurrence_price_values: { monthly: { enabled: true, price_cents: 500 } } },
      ]
    end
    served_snapshots = product.tiers.to_h { [_1.external_id, Product::StaleContentWriteGuard.snapshot_at(_1).as_json] }

    post :update, params: { id: product.unique_permalink, name: product.name, variants: tier_params.call(served_snapshots) }, format: :json

    assert_response :success
    assert_equal 900, first_tier.reload.alive_prices.is_buy.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).price_cents
    # The refreshed snapshot has to account for the price row this save wrote,
    # otherwise the session's next save echoes a timestamp older than the price
    # and rejects itself.
    refreshed = response.parsed_body["variant_updated_at"]
    assert_equal Product::StaleContentWriteGuard.snapshot_at(first_tier).to_i, Time.zone.parse(refreshed[first_tier.external_id]).to_i

    travel 1.second
    post :update, params: { id: product.unique_permalink, name: product.name, variants: tier_params.call(refreshed) }, format: :json

    assert_response :success
  end

  test "PUT update does NOT reject a save that resubmits a membership tier's stored prices unchanged" do
    enforce_stale_content_block!
    product = create_membership_product_with_preset_tiered_pricing(user: @seller)
    first_tier = product.tiers.find_by!(name: "First Tier")
    second_tier = product.tiers.find_by!(name: "Second Tier")
    stale_snapshot = Product::StaleContentWriteGuard.snapshot_at(first_tier).as_json

    # The tier row moves without any seller-editable value changing — the same
    # bare touch a sale of a limited-quantity tier performs. Resubmitting the
    # stored prices would overwrite nothing, so the save must go through.
    travel 1.minute
    first_tier.touch

    post :update, params: {
      id: product.unique_permalink,
      name: product.name,
      variants: [
        { id: first_tier.external_id, name: first_tier.name, updated_at: stale_snapshot,
          recurrence_price_values: { monthly: { enabled: true, price_cents: 300 } } },
        { id: second_tier.external_id, name: second_tier.name,
          updated_at: Product::StaleContentWriteGuard.snapshot_at(second_tier).as_json,
          recurrence_price_values: { monthly: { enabled: true, price_cents: 500 } } },
      ]
    }, format: :json

    assert_response :success
  end

  test "PUT update re-denominates membership tier prices when the editor changes display currency" do
    product = create_membership_product_with_preset_tiered_pricing(user: @seller, price_currency_type: "usd")
    first_tier = product.tiers.find_by!(name: "First Tier")
    second_tier = product.tiers.find_by!(name: "Second Tier")

    post :update, params: {
      id: product.unique_permalink,
      name: product.name,
      price_currency_type: "eur",
      variants: [
        { id: first_tier.external_id, name: first_tier.name,
          updated_at: Product::StaleContentWriteGuard.snapshot_at(first_tier).as_json,
          recurrence_price_values: { monthly: { enabled: true, price_cents: 300 } } },
        { id: second_tier.external_id, name: second_tier.name,
          updated_at: Product::StaleContentWriteGuard.snapshot_at(second_tier).as_json,
          recurrence_price_values: { monthly: { enabled: true, price_cents: 500 } } },
      ]
    }, format: :json

    assert_response :success
    assert_equal "eur", product.reload.price_currency_type
    assert_equal 300, first_tier.reload.alive_prices.is_buy.find_by!(currency: "eur", recurrence: BasePrice::Recurrence::MONTHLY).price_cents
    assert_equal 500, second_tier.reload.alive_prices.is_buy.find_by!(currency: "eur", recurrence: BasePrice::Recurrence::MONTHLY).price_cents
  end

  test "PUT update rejects a stale tier save that would re-enable a recurrence another session turned off" do
    enforce_stale_content_block!
    # Both tiers carry the same set of recurrences — the editor enforces that,
    # and a payload with mismatched sets is rejected before the guard runs.
    product = create_membership_product_with_preset_tiered_pricing(
      user: @seller,
      recurrence_price_values: [
        { monthly: { enabled: true, price_cents: 300 }, yearly: { enabled: true, price_cents: 3000 } },
        { monthly: { enabled: true, price_cents: 500 }, yearly: { enabled: true, price_cents: 5000 } },
      ]
    )
    first_tier = product.tiers.find_by!(name: "First Tier")
    second_tier = product.tiers.find_by!(name: "Second Tier")
    stale_snapshot = Product::StaleContentWriteGuard.snapshot_at(first_tier).as_json
    second_snapshot = Product::StaleContentWriteGuard.snapshot_at(second_tier).as_json

    # Session B drops the yearly option from both tiers. That SOFT-DELETES the
    # yearly price rows rather than writing live ones, and the monthly prices it
    # resubmits are unchanged so those rows aren't touched either — a snapshot
    # built only from ALIVE price rows therefore doesn't move. Session A's stale
    # payload would bring the deleted yearly prices straight back.
    travel 1.minute
    first_tier.save_recurring_prices!(monthly: { enabled: true, price_cents: 300 })
    second_tier.save_recurring_prices!(monthly: { enabled: true, price_cents: 500 })

    post :update, params: {
      id: product.unique_permalink,
      name: product.name,
      variants: [
        { id: first_tier.external_id, name: first_tier.name, updated_at: stale_snapshot,
          recurrence_price_values: { monthly: { enabled: true, price_cents: 300 }, yearly: { enabled: true, price_cents: 3000 } } },
        { id: second_tier.external_id, name: second_tier.name, updated_at: second_snapshot,
          recurrence_price_values: { monthly: { enabled: true, price_cents: 500 }, yearly: { enabled: true, price_cents: 5000 } } },
      ]
    }, format: :json

    assert_response :conflict
    assert_equal "stale_content_conflict", response.parsed_body["error_code"]
    assert_nil first_tier.reload.alive_prices.is_buy.find_by(recurrence: BasePrice::Recurrence::YEARLY)
  end

  test "PUT update fails open for payloads that do not echo snapshot timestamps (sessions predating the guard)" do
    enforce_stale_content_block!
    setup_guarded_version!
    newer_content = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newer" }] }]

    travel 1.minute
    @version1_page.update!(description: newer_content)

    # No updated_at anywhere in the payload — a legacy session. The save goes
    # through the way it always did (this is the pre-guard behavior, kept so a
    # deploy doesn't break every open editor tab).
    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
    assert_equal guard_content_description, @version1_page.reload.description
  end

  test "PUT update ignores unparseable echoed timestamps instead of failing the save" do
    enforce_stale_content_block!
    setup_guarded_version!

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, updated_at: "not-a-timestamp", rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: "also-not-a-timestamp", description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
  end

  # --- enforcement is OFF by default (gumroad-private#1295) --------------------
  # In production the seller-visible 409 blocked 363 saves for 61 sellers in
  # about twelve hours, and every sampled block submitted exactly as many pages
  # and variants as the product had — nothing was being overwritten. The
  # rejection is therefore gated off while the payload contract is fixed
  # (gumroad-private#1329). These tests pin the DEFAULT behavior: staleness is
  # still detected and still reported to Sentry, but the save goes through, and
  # the deletion guards are unaffected.

  # The tab a seller had open when the guard deployed is the case the guard's
  # "fail open for legacy sessions" allowance was supposed to cover and did
  # NOT: page timestamps were already part of the editor payload long before
  # the guard shipped (RichContents#rich_content_json), so such a tab carries a
  # real page id AND a page timestamp it has no way to refresh. It was blocked
  # on its very next save. With enforcement off it saves normally.
  test "PUT update lets a pre-deploy editor tab save: a real page id with an unrefreshed page timestamp is not blocked" do
    setup_guarded_version!
    # The timestamp this tab was served when it loaded, before the guard existed.
    pre_deploy_snapshot = @version1_page.updated_at.as_json
    seller_edit = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Edit made in the old tab" }] }]

    # The stored page moves on afterwards, for any reason at all — another save
    # from this same seller, a support restore, a background touch.
    travel 1.minute
    @version1_page.update!(description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Something else" }] }])

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: pre_deploy_snapshot, description: { type: "doc", content: seller_edit } }] }]
    ), format: :json

    assert_response :success
    assert_equal seller_edit, @version1_page.reload.description
  end

  test "PUT update lets ordinary consecutive saves through even when the session never refreshes its page snapshot" do
    setup_guarded_version!
    snapshot = @version1_page.updated_at.as_json
    save = ->(text) do
      post :update, params: @params.merge(
        variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: snapshot, description: { type: "doc", content: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => text }] }] } }] }]
      ), format: :json
    end

    # Save a minute after the editor loaded, so this save's own write lands on a
    # later second than the snapshot the session is holding.
    travel 1.minute
    save.call("First save")
    assert_response :success

    # The session still echoes the snapshot it was served on load — it never
    # adopted the timestamp the first save handed back. The stored row is now
    # newer, so with enforcement on this second save is rejected and refreshing
    # does not help: this is the retry-storm shape sellers were stuck in.
    save.call("Second save")

    assert_response :success
    assert_equal [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Second save" }] }], @version1_page.reload.description
  end

  test "PUT update still reports a stale snapshot to Sentry when enforcement is off, under an observe-only message" do
    setup_guarded_version!
    stale_snapshot = @version1_page.updated_at.as_json
    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    travel 1.minute
    @version1_page.update!(description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newer" }] }])

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: stale_snapshot, description: { type: "doc", content: guard_content_description } }] }]
    ), format: :json

    assert_response :success
    message, context = notified.find { |m, _| m == Product::StaleContentWriteGuard::OBSERVED_MESSAGE }
    assert_not_nil message, "Expected the observe-only stale-snapshot notification (got: #{notified.map(&:first).inspect})"
    assert_equal @product.id, context[:product_id]
    assert_equal [@version1_page.external_id], context[:stale_page_external_ids]
    # The blocking message must not be sent while the flag is off — the two are
    # separate Sentry issues and the blocking one has to stay at zero events.
    assert_nil notified.find { |m, _| m == Product::StaleContentWriteGuard::BLOCKED_MESSAGE }
  end

  # The two deletion guards (#6178, #6244) are what actually stopped the July
  # 13/18/21 wipes, and gating the stale-write rejection must not weaken them.
  # These re-assert both malformed-payload shapes with enforcement OFF, so a
  # future change that accidentally routes the deletion guards through the same
  # flag fails here.

  test "PUT update still blocks a payload missing a content-bearing page when stale-write enforcement is off" do
    setup_guarded_version!
    # A stale snapshot AND an omitted page: the stale-write guard stays silent
    # (enforcement off) and the deletion guard has to catch the omission.
    stale_snapshot = @version1_page.updated_at.as_json
    travel 1.minute
    @version1_page.update!(description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newer" }] }])

    post :update, params: @params.merge(
      variants: [{ id: @version1.external_id, name: @version1.name, updated_at: stale_snapshot, rich_content: [] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_includes response.parsed_body["error_message"], "refresh the page"
    assert @version1_page.reload.alive?
  end

  test "PUT update still blocks a payload missing a content-bearing variant when stale-write enforcement is off" do
    setup_guarded_version!

    post :update, params: @params.merge(variants: [{ id: nil, name: "Brand new version" }]), format: :json

    assert_response :unprocessable_entity
    assert_includes response.parsed_body["error_message"], "refresh the page"
    assert @version1.reload.alive?
    assert @version1_page.reload.alive?
  end

  # The kill switch reads a Flipper flag, which is a Redis round trip, and it
  # runs inside the save's transaction while that transaction holds the product
  # row lock. If the feature store is unreachable the save must still go
  # through: a 500 here would recreate the failure this gate exists to remove.
  test "PUT update still saves when the enforcement flag lookup itself fails" do
    setup_guarded_version!
    stale_snapshot = @version1_page.updated_at.as_json
    seller_edit = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Saved despite a flag-store outage" }] }]
    # Simulate the feature store failing for THIS flag only, without mocha:
    # a `.with` matcher turns every OTHER flag lookup in the request into an
    # unexpected invocation (custom_html_pages, cancellation_discounts), so
    # override the singleton and restore it in an ensure block.
    original = Feature.method(:active?)
    Feature.define_singleton_method(:active?) do |name, actor = nil|
      raise Redis::CannotConnectError, "Error connecting to Redis" if name == Product::StaleContentWriteGuard::BLOCK_FEATURE_NAME

      original.call(name, actor)
    end

    begin
      travel 1.minute
      @version1_page.update!(description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newer" }] }])

      post :update, params: @params.merge(
        variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [{ id: @version1_page.external_id, title: "Page", updated_at: stale_snapshot, description: { type: "doc", content: seller_edit } }] }]
      ), format: :json
    ensure
      Feature.define_singleton_method(:active?, original)
    end

    assert_response :success
    assert_equal seller_edit, @version1_page.reload.description
  end

  # --- the July 21, 2026 incident shape (gumroad-private#1230) -----------------
  # Support restored a product's per-version pages while
  # has_same_rich_content_for_all_variants stayed on and a blank product-level
  # placeholder page existed. The editor resolves content through the flag, so
  # a fresh load received EMPTY variant content — the stored state itself
  # produced a blind payload. The seller then switched to per-version content
  # (which moved the blank placeholder onto the first version) and saved,
  # wiping every restored page. The exact request body was not retained, but
  # the audited state transitions and the deployed code tightly constrain it
  # to this shape.

  def setup_july_21_incident_state!
    @category = create_variant_category(link: @product, title: "Versions")
    @version1 = create_variant(variant_category: @category, name: "Version 1")
    @version2 = create_variant(variant_category: @category, name: "Version 2")
    file = @product.product_files.alive.first
    @restored_description1 = [
      { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Restored Version 1 content" }] },
      { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => "version1-file-uid" } },
    ]
    @restored_description2 = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Restored Version 2 content" }] }]
    @restored_page1 = create_rich_content(entity: @version1, description: @restored_description1)
    @restored_page2 = create_rich_content(entity: @version2, description: @restored_description2)
    @version1.product_files = [file]
    @placeholder_page = create_product_rich_content(entity: @product, description: [{ "type" => "paragraph" }])
    @product.update!(has_same_rich_content_for_all_variants: true)
  end

  test "PUT update blocks the July 21 blind-snapshot save and keeps every restored page and file intact" do
    setup_july_21_incident_state!
    file = @product.product_files.alive.first

    # The blind editor session switches to per-version content: the blank
    # product-level placeholder moves onto the first version (keeping its id —
    # the cross-entity placeholder), the other version gets an empty page
    # list, and none of the restored pages appear anywhere in the payload.
    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [
        { id: @version1.external_id, name: "Version 1", rich_content: [{ id: @placeholder_page.external_id, title: nil, description: { type: "doc", content: [{ type: "paragraph" }] } }] },
        { id: @version2.external_id, name: "Version 2", rich_content: [] },
      ]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal Product::RichContentDeletionGuard::HIDDEN_CONTENT_RECOVERABLE_MESSAGE, response.parsed_body["error_message"]

    # Every restored page — and the file the content embeds — survives untouched.
    assert_equal false, @restored_page1.reload.deleted?
    assert_equal false, @restored_page2.reload.deleted?
    assert_equal @restored_description1, @restored_page1.description
    assert_equal @restored_description2, @restored_page2.description
    assert_equal [file.id], @version1.reload.product_files.alive.ids
    assert_equal false, file.reload.deleted?
  end

  test "PUT update accepts the recovered per-version save a refreshed editor produces after the July 21 state" do
    setup_july_21_incident_state!

    # In this state the presenter now serves has_same_rich_content_for_all_variants
    # as false with each version's real pages (see ProductPresenter), so a
    # refreshed editor submits the restored content under its real ids. Saving
    # persists the flag as off and resolves the inconsistency for good.
    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: false,
      rich_content: [{ id: @placeholder_page.external_id, title: nil, description: { type: "doc", content: [{ type: "paragraph" }] } }],
      variants: [
        { id: @version1.external_id, name: "Version 1", rich_content: [{ id: @restored_page1.external_id, title: nil, description: { type: "doc", content: @restored_description1 } }] },
        { id: @version2.external_id, name: "Version 2", rich_content: [{ id: @restored_page2.external_id, title: nil, description: { type: "doc", content: @restored_description2 } }] },
      ]
    ), format: :json

    assert_response :success
    assert_equal false, @product.reload.has_same_rich_content_for_all_variants?
    assert_equal false, @restored_page1.reload.deleted?
    assert_equal false, @restored_page2.reload.deleted?
    assert_equal @restored_description1, @restored_page1.description
    assert_equal @restored_description2, @restored_page2.description
  end

  test "PUT update fails closed with an explicit-choice error when hidden version content conflicts with real product-level content" do
    setup_guarded_version!
    version2 = create_variant(variant_category: @category, name: "Winter Sale")
    version2_page = create_rich_content(entity: version2, title: "Winter guide", description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Winter content" }] }])
    product_page = create_product_rich_content(entity: @product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Product-level content" }] }])
    @product.update!(has_same_rich_content_for_all_variants: true)

    # An ordinary save of the shared-content view: the product-level page is
    # kept, and the (hidden) version pages are absent from the payload. Neither
    # side can be picked automatically — the save must fail closed and name
    # EVERY hidden page (across all versions, not only the first one the guard
    # inspected) so the editor can ask for one explicit choice covering all.
    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: true,
      rich_content: [{ id: product_page.external_id, title: nil, description: { type: "doc", content: product_page.description } }],
      variants: [
        { id: @version1.external_id, name: @version1.name, rich_content: [] },
        { id: version2.external_id, name: version2.name, rich_content: [] },
      ]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal Product::RichContentDeletionGuard::HIDDEN_CONTENT_CONFLICT_MESSAGE, response.parsed_body["error_message"]
    assert_equal "hidden_variant_content_conflict", response.parsed_body["error_code"]
    assert_equal [{ "id" => @version1_page.external_id, "title" => nil, "variant_name" => "Summer Sale" }, { "id" => version2_page.external_id, "title" => "Winter guide", "variant_name" => "Winter Sale" }].to_set,
                 response.parsed_body["hidden_variant_pages"].to_set
    assert_equal false, @version1_page.reload.deleted?
    assert_equal false, version2_page.reload.deleted?
  end

  test "PUT update classifies the conflict from the pre-save state when the same save clears the product-level content" do
    # Regression: the conflict/recoverable classification must come from the
    # pre-save state (deletion_guard_diagnostics), not the live rows. A save
    # that CLEARED the product-level content used to make the live rows look
    # blank by the time the per-variant guards ran, so a real conflict was
    # misclassified as "recoverable" — then the transaction rolled back,
    # restored the product-level content, and the advised refresh returned the
    # seller to the exact same broken state forever.
    setup_guarded_version!
    product_page = create_product_rich_content(entity: @product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Product-level content" }] }])
    @product.update!(has_same_rich_content_for_all_variants: true)

    # The seller clears the shared page's content in the editor and saves: the
    # page is still in the payload (emptied in place), so the product-level
    # rows are blank by the time the per-variant guards run.
    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: true,
      rich_content: [{ id: product_page.external_id, title: nil, description: { type: "doc", content: [{ type: "paragraph" }] } }],
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [] }]
    ), format: :json

    assert_response :unprocessable_entity
    assert_equal "hidden_variant_content_conflict", response.parsed_body["error_code"]
    assert_equal Product::RichContentDeletionGuard::HIDDEN_CONTENT_CONFLICT_MESSAGE, response.parsed_body["error_message"]

    # Both content sets remain intact — the rollback restored the cleared
    # product-level page (content included) and the hidden version page was
    # never touched.
    assert_equal false, product_page.reload.deleted?
    assert_equal [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Product-level content" }] }], product_page.description
    assert_equal false, @version1_page.reload.deleted?
    assert_equal guard_content_description, @version1_page.description
  end

  test "PUT update deletes the hidden version content once the seller makes the explicit choice" do
    setup_guarded_version!
    product_page = create_product_rich_content(entity: @product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Product-level content" }] }])
    @product.update!(has_same_rich_content_for_all_variants: true)

    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: true,
      rich_content: [{ id: product_page.external_id, title: nil, description: { type: "doc", content: product_page.description } }],
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [] }],
      confirmed_removed_rich_content_ids: [@version1_page.external_id]
    ), format: :json

    assert_response :success
    assert_equal true, @version1_page.reload.deleted?
    assert_equal false, product_page.reload.deleted?
    assert_equal true, @product.reload.has_same_rich_content_for_all_variants?
  end

  test "PUT update keeps the hidden version content and deletes the product-level pages when the seller chooses to keep version content" do
    # The "Keep version content" conflict choice: the hidden version pages
    # never made it into this editor session (the shared-content flag hid
    # them), so the payload carries them as preserved_rich_content_ids instead
    # of resubmitting them; the product-level pages are confirmed removed and
    # the shared-content flag turns off.
    setup_guarded_version!
    product_page = create_product_rich_content(entity: @product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Product-level content" }] }])
    @product.update!(has_same_rich_content_for_all_variants: true)

    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [{ id: @version1.external_id, name: @version1.name, rich_content: [] }],
      confirmed_removed_rich_content_ids: [product_page.external_id],
      preserved_rich_content_ids: [@version1_page.external_id]
    ), format: :json

    assert_response :success
    assert_equal true, product_page.reload.deleted?
    assert_equal false, @version1_page.reload.deleted?
    assert_equal guard_content_description, @version1_page.description
    assert_equal false, @product.reload.has_same_rich_content_for_all_variants?
  end

  # --- coffee products --------------------------------------------------------

  test "PUT update sets suggested_price_cents to the maximum price_difference_cents of variants for coffee products" do
    coffee_product = create_coffee_product
    sign_in coffee_product.user

    post :update, params: {
      id: coffee_product.unique_permalink,
      # Address the auto-created suggested amount by id, like the editor does —
      # blindly omitting it would trip the configured-variant deletion guard.
      variants: [{ id: coffee_product.alive_variants.first.external_id, price_difference_cents: 300 }, { price_difference_cents: 500 }, { price_difference_cents: 100 }]
    }, as: :json

    assert_response :success
    assert_equal 500, coffee_product.reload.suggested_price_cents
  end

  test "PUT update ignores variants with a nil price_difference_cents when computing suggested_price_cents for coffee products" do
    coffee_product = create_coffee_product
    sign_in coffee_product.user

    post :update, params: {
      id: coffee_product.unique_permalink,
      # Address the auto-created suggested amount by id, like the editor does.
      variants: [{ id: coffee_product.alive_variants.first.external_id, price_difference_cents: 10000 }, { price_difference_cents: nil }]
    }, as: :json

    assert_response :success
    assert_equal 10000, coffee_product.reload.suggested_price_cents
    assert_equal [10000], coffee_product.alive_variants.map(&:price_difference_cents)
  end

  # --- content_updated_at -----------------------------------------------------

  test "PUT update sets content_updated_at when a new file is uploaded" do
    freeze_time do
      url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png"
      post(:update, params: @params.merge!(files: [{ id: SecureRandom.uuid, url: }]), format: :json)

      @product.reload
      assert_equal Time.current, @product.content_updated_at
    end
  end

  test "PUT update does not set content_updated_at when irrelevant attributes are changed" do
    freeze_time do
      post(:update, params: @params.merge(description: "new description"), format: :json)

      assert_response :success
      @product.reload
      assert_nil @product.content_updated_at
    end
  end

  # --- invalidate_action ------------------------------------------------------

  test "PUT update invalidates the action" do
    Rails.cache.write("views/#{@product.cache_key_prefix}_en_displayed_switch_ids_.html", "<html>hello</html>")

    assert_not_nil Rails.cache.read("views/#{@product.cache_key_prefix}_en_displayed_switch_ids_.html")
    post :update, params: @params.merge(id: @product.unique_permalink)
    assert_nil Rails.cache.read("views/#{@product.cache_key_prefix}_en_displayed_switch_ids_.html")
  end

  # --- updates the product ----------------------------------------------------

  test "PUT update updates the product" do
    calls = spy_on_class_new(SaveContentUpsellsService) do
      put :update, params: @params, as: :json
    end
    assert calls.any? { |call|
      call[:kwargs][:seller] == @product.user &&
        call[:kwargs][:content] == "New description" &&
        call[:kwargs][:old_content] == "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes."
    }, "Expected SaveContentUpsellsService to be built for the description change"

    @product.reload
    assert_equal "sumlink", @product.name
    assert_equal "pay_prompt", @product.custom_button_text_option
    assert_equal "summary", @product.custom_summary
    assert_equal "Get Your Files", @product.custom_view_content_button_text
    assert_equal "Thank you for purchasing! Feel free to contact us any time for support.", @product.custom_receipt_text
    assert_equal [{ "name" => "name", "value" => "value" }], @product.custom_attributes
    assert_equal [:Size], @product.removed_file_info_attributes
    assert_equal false, @product.product_refund_policy_enabled
    assert_nil @product.product_refund_policy
  end

  test "PUT update updates the product refund policy when seller_refund_policy_disabled_for_all feature flag is set to true" do
    Feature.activate(:seller_refund_policy_disabled_for_all)

    put :update, params: @params, as: :json
    @product.reload
    assert_equal true, @product.product_refund_policy_enabled
    assert_equal "7-day money back guarantee", @product.product_refund_policy.title
    assert_equal "Sample fine print", @product.product_refund_policy.fine_print
  ensure
    Feature.deactivate(:seller_refund_policy_disabled_for_all)
  end

  test "PUT update updates the product refund policy when seller refund policy is set to false" do
    @product.user.update!(refund_policy_enabled: false)

    put :update, params: @params, as: :json
    @product.reload
    assert_equal true, @product.product_refund_policy_enabled
    assert_equal "7-day money back guarantee", @product.product_refund_policy.title
    assert_equal "Sample fine print", @product.product_refund_policy.fine_print
  end

  test "PUT update disables the product refund policy when seller refund policy is disabled and the param is false" do
    @product.user.update!(refund_policy_enabled: false)
    @product.update!(product_refund_policy_enabled: true)

    @params[:product_refund_policy_enabled] = false
    put :update, params: @params, as: :json
    @product.reload
    assert_equal false, @product.product_refund_policy_enabled
    assert_nil @product.product_refund_policy
  end

  test "PUT update updates a physical product" do
    product = create_physical_product(user: @seller, skus_enabled: true)
    shipping_destination = product.shipping_destinations.first
    post :update, params: {
      id: product.unique_permalink,
      name: "physical",
      shipping_destinations: [
        {
          id: shipping_destination.id,
          country_code: shipping_destination.country_code,
          one_item_rate_cents: shipping_destination.one_item_rate_cents,
          multiple_items_rate_cents: shipping_destination.multiple_items_rate_cents
        }
      ]
    }
    assert_response :success
    product.reload
    assert_equal "physical", product.name
    assert_equal false, product.skus_enabled
  end

  test "PUT update appends removed_file_info_attributes when additional keys are provided" do
    put :update, params: @params.merge(file_attributes: []), format: :json
    assert_equal %i[Size Length], @product.reload.removed_file_info_attributes
  end

  test "PUT update changes product from USD $10 to EUR €12 and back to USD $11" do
    @product.update!(price_currency_type: "usd", price_cents: 1000)
    assert_equal "usd", @product.price_currency_type
    assert_equal 1000, @product.price_cents

    put :update, params: { id: @product.unique_permalink, price_currency_type: "eur", price_cents: 1200 }, as: :json

    assert_response :success
    @product.reload
    assert_equal "eur", @product.price_currency_type
    assert_equal 1200, @product.price_cents

    put :update, params: { id: @product.unique_permalink, price_currency_type: "usd", price_cents: 1100 }, as: :json

    assert_response :success
    @product.reload
    assert_equal "usd", @product.price_currency_type
    assert_equal 1100, @product.price_cents
  end

  test "PUT update sets the correct value for removed_file_info_attributes if there are none" do
    post :update, params: @params.merge(file_attributes: [{ name: "Length", value: "10 sections" }, { name: "Size", value: "100 TB" }]), format: :json
    assert_equal [], @product.reload.removed_file_info_attributes
  end

  test "PUT update deletes custom attributes" do
    post :update, params: @params.merge(custom_attributes: []), format: :json
    assert_equal [], @product.reload.custom_attributes
  end

  test "PUT update ignores custom attributes with both blank name and blank value" do
    post :update, params: @params.merge(custom_attributes: [{ name: "", value: "" }]), format: :json
    assert_equal [], @product.reload.custom_attributes
  end

  test "PUT update marks the product as adult if the is_adult param is true" do
    post :update, params: @params.merge(is_adult: true), format: :json
    assert_equal true, @product.reload.is_adult
  end

  test "PUT update marks the product as non-adult if the is_adult param is false" do
    @product.update!(is_adult: true)
    post :update, params: @params.merge(is_adult: false), format: :json
    assert_equal false, @product.reload.is_adult
  end

  test "PUT update marks the product as allowing display of reviews if the display_product_reviews param is true" do
    post :update, params: @params.merge(display_product_reviews: true), format: :json
    assert_equal true, @product.reload.display_product_reviews
  end

  test "PUT update marks the product as not allowing display of reviews if the display_product_reviews param is false" do
    @product.update!(display_product_reviews: true)
    post :update, params: @params.merge(display_product_reviews: false), format: :json
    assert_equal false, @product.reload.display_product_reviews
  end

  test "PUT update marks the product as allowing display of sales count if the should_show_sales_count param is true" do
    post :update, params: @params.merge(should_show_sales_count: true), format: :json
    assert_equal true, @product.reload.should_show_sales_count
  end

  test "PUT update marks the product as not allowing display of sales count if the should_show_sales_count param is false" do
    @product.update!(should_show_sales_count: true)
    post :update, params: @params.merge(should_show_sales_count: false), format: :json
    assert_equal false, @product.reload.should_show_sales_count
  end

  # --- adding variants --------------------------------------------------------

  test "PUT update adds variants to the product" do
    variants = [
      { name: "red", price_difference_cents: 400, max_purchase_count: 100 },
      { name: "blue", price_difference_cents: 300 }
    ]
    post :update, params: { id: @product.unique_permalink, variants: }, as: :json

    variant1 = @product.alive_variants.first
    assert_equal "red", variant1.name
    assert_equal 400, variant1.price_difference_cents
    assert_equal 100, variant1.max_purchase_count
    variant2 = @product.alive_variants.second
    assert_equal "blue", variant2.name
    assert_equal 300, variant2.price_difference_cents
    assert_nil variant2.max_purchase_count
  end

  test "PUT update persists the variants correctly when removing a variant from an existing category" do
    category = create_variant_category(title: "sizes", link: @product)
    variant1 = create_variant(variant_category: category, name: "small", price_difference_cents: 200, max_purchase_count: 100)
    variant2 = create_variant(variant_category: category, name: "medium", price_difference_cents: 300)

    variants = [{ name: "small", id: variant1.external_id, price_difference_cents: 200, max_purchase_count: 100 }]
    # variant2 has a custom price, so its removal must be explicitly confirmed
    # (the configured-variant deletion guard blocks blind omissions).
    post :update, params: { id: @product.unique_permalink, variants:, confirmed_removed_variant_ids: [variant2.external_id] }, as: :json

    assert_equal 1, @product.reload.variant_categories.count
    assert_equal 1, @product.alive_variants.count

    assert variant1.reload.alive?
    assert_equal "small", variant1.name
    assert_equal 200, variant1.price_difference_cents
    assert_equal 100, variant1.max_purchase_count
    assert variant2.reload.deleted?
  end

  test "PUT update removes the category when all variants are removed" do
    category = create_variant_category(title: "sizes", link: @product)
    variant = create_variant(variant_category: category, name: "small", price_difference_cents: 200, max_purchase_count: 100)

    assert_difference -> { @product.reload.variant_categories_alive.count }, -1 do
      # The variant has a custom price and quantity cap, so removing it
      # requires explicit confirmation from the seller.
      post :update, params: { id: @product.unique_permalink, variants: [], confirmed_removed_variant_ids: [variant.external_id] }, as: :json
    end
  end

  test "PUT update updates profile sections" do
    product1 = create_product(user: @seller)
    product2 = create_product(user: @seller)
    section1 = create_seller_profile_products_section(seller: @seller, shown_products: [product1, product2].map(&:id))
    section2 = create_seller_profile_products_section(seller: @seller, shown_products: [product1.id])
    section3 = create_seller_profile_products_section(seller: @seller, shown_products: [product2.id])
    params = { id: product1.unique_permalink, section_ids: [section3.external_id] }
    put :update, params:, format: :json
    assert_equal [product2.id], section1.reload.shown_products
    assert_equal [], section2.reload.shown_products
    assert_equal [product2, product1].map(&:id), section3.reload.shown_products

    put :update, params: params.merge(section_ids: []), format: :json
    assert_equal [product2.id], section1.reload.shown_products
    assert_equal [], section2.reload.shown_products
    assert_equal [product2.id], section3.reload.shown_products
  end

  # --- subscription pricing ---------------------------------------------------

  test "PUT update enables existing membership price upgrades" do
    membership_product = create_membership_product(user: @seller)
    tier = membership_product.default_tier
    effective_date = 10.days.from_now.to_date

    post :update, params: {
      id: membership_product.unique_permalink,
      variants: [{
        id: tier.external_id,
        name: tier.name,
        apply_price_changes_to_existing_memberships: true,
        subscription_price_change_effective_date: effective_date.strftime("%Y-%m-%d"),
        subscription_price_change_message: "hello",
      }]
    }

    tier.reload
    assert_equal true, tier.apply_price_changes_to_existing_memberships
    assert_equal effective_date, tier.subscription_price_change_effective_date
    assert_equal "hello", tier.subscription_price_change_message
  end

  test "PUT update changes effective date to a later date and schedules emails to subscribers" do
    membership_product = create_membership_product(user: @seller)
    tier = membership_product.default_tier
    effective_date = 10.days.from_now.to_date
    tier.update!(apply_price_changes_to_existing_memberships: true, subscription_price_change_effective_date: effective_date, subscription_price_change_message: "hello")

    new_effective_date = 1.month.from_now.to_date
    post :update, params: {
      id: membership_product.unique_permalink,
      variants: [{
        id: tier.external_id,
        name: tier.name,
        apply_price_changes_to_existing_memberships: true,
        subscription_price_change_effective_date: new_effective_date.strftime("%Y-%m-%d"),
        subscription_price_change_message: "hello",
      }]
    }

    assert_equal new_effective_date, tier.reload.subscription_price_change_effective_date
    assert_enqueued_sidekiq_job(ScheduleMembershipPriceUpdatesJob, tier.id)
  end

  test "PUT update changes effective date to an earlier date and schedules emails to subscribers" do
    membership_product = create_membership_product(user: @seller)
    tier = membership_product.default_tier
    effective_date = 10.days.from_now.to_date
    tier.update!(apply_price_changes_to_existing_memberships: true, subscription_price_change_effective_date: effective_date, subscription_price_change_message: "hello")

    new_effective_date = 7.days.from_now.to_date
    post :update, params: {
      id: membership_product.unique_permalink,
      variants: [{
        id: tier.external_id,
        name: tier.name,
        apply_price_changes_to_existing_memberships: true,
        subscription_price_change_effective_date: new_effective_date.strftime("%Y-%m-%d"),
        subscription_price_change_message: "hello",
      }]
    }

    assert_equal new_effective_date, tier.reload.subscription_price_change_effective_date
    assert_enqueued_sidekiq_job(ScheduleMembershipPriceUpdatesJob, tier.id)
  end

  test "PUT update disables existing membership price upgrades" do
    membership_product = create_membership_product(user: @seller)
    tier = membership_product.default_tier
    effective_date = 10.days.from_now.to_date
    tier.update!(apply_price_changes_to_existing_memberships: true, subscription_price_change_effective_date: effective_date, subscription_price_change_message: "hello")

    post :update, params: {
      id: membership_product.unique_permalink,
      variants: [{ id: tier.external_id, name: tier.name, apply_price_changes_to_existing_memberships: false }]
    }, as: :json

    tier.reload
    assert_equal false, tier.apply_price_changes_to_existing_memberships
    assert_nil tier.subscription_price_change_effective_date
    assert_nil tier.subscription_price_change_message
    refute_enqueued_sidekiq_job(ScheduleMembershipPriceUpdatesJob, tier.id)
  end

  # --- setting recurring prices on a variant ----------------------------------

  def setup_recurring_prices!
    @product = create_membership_product(user: @seller)
    @tier_category = @product.tier_category
    @params.delete(:files)
    @params.merge!(
      id: @product.unique_permalink,
      variants: [
        {
          name: "First Tier",
          # Update the auto-created default tier in place — it carries a
          # recurring price, so blindly omitting its id would trip the
          # configured-variant deletion guard.
          id: @product.default_tier.external_id,
          recurrence_price_values: {
            monthly: { enabled: true, price_cents: 2000 },
            quarterly: { enabled: true, price_cents: 4500 },
            yearly: { enabled: true, price_cents: 12000 },
            biannually: { enabled: false },
            every_two_years: { enabled: true, price_cents: 20000 }
          },
        },
        {
          name: "Second Tier",
          recurrence_price_values: {
            monthly: { enabled: true, price_cents: 1000 },
            quarterly: { enabled: true, price_cents: 2500 },
            yearly: { enabled: true, price_cents: 6000 },
            biannually: { enabled: false },
            every_two_years: { enabled: true, price_cents: 10000 }
          }
        }
      ]
    )
  end

  test "PUT update sets the prices on the variants" do
    setup_recurring_prices!
    post :update, params: @params, format: :json

    variants = @tier_category.reload.variants
    first_tier_prices = variants.find_by!(name: "First Tier").prices
    second_tier_prices = variants.find_by!(name: "Second Tier").prices

    assert_equal 2000, first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).price_cents
    assert_equal 4500, first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).price_cents
    assert_equal 12000, first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY).price_cents
    assert_equal 20000, first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS).price_cents
    assert_nil first_tier_prices.find_by(recurrence: BasePrice::Recurrence::BIANNUALLY)

    assert_equal 1000, second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).price_cents
    assert_equal 2500, second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).price_cents
    assert_equal 6000, second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY).price_cents
    assert_equal 10000, second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS).price_cents
    assert_nil second_tier_prices.find_by(recurrence: BasePrice::Recurrence::BIANNUALLY)
  end

  def cancellation_discount_params
    ActionController::Parameters.new(
      discount: ActionController::Parameters.new(type: "fixed", cents: "100").permit!,
      duration_in_billing_cycles: "3"
    ).permit!
  end

  test "PUT update does not update the cancellation discount when cancellation_discounts feature flag is off" do
    setup_recurring_prices!
    @params[:cancellation_discount] = cancellation_discount_params
    Product::SaveCancellationDiscountService.expects(:new).never
    post :update, params: @params, format: :json
  end

  test "PUT update updates the cancellation discount when cancellation_discounts feature flag is on" do
    setup_recurring_prices!
    @params[:cancellation_discount] = cancellation_discount_params
    Feature.activate_user(:cancellation_discounts, @product.user)

    calls = spy_on_class_new(Product::SaveCancellationDiscountService) do
      post :update, params: @params, format: :json
    end
    # Mirror the original's `.with(@product, @params[:cancellation_discount])`: verify the
    # service is built with the product AND the exact cancellation-discount params, not
    # merely a present second argument.
    assert calls.any? { |call|
      call[:args].first == @product &&
        call[:args].second.to_unsafe_h.deep_stringify_keys == cancellation_discount_params.to_unsafe_h.deep_stringify_keys
    }, "Expected Product::SaveCancellationDiscountService to be built with the product and the cancellation discount params"
  end

  # --- default discount code --------------------------------------------------

  test "PUT update sets the default offer code when a valid product offer code is provided" do
    setup_recurring_prices!
    offer_code = create_offer_code(user: @product.user, products: [@product])
    @params[:default_offer_code_id] = offer_code.external_id
    post :update, params: @params, format: :json

    assert_equal offer_code, @product.reload.default_offer_code
  end

  test "PUT update sets the default offer code when a valid universal offer code is provided" do
    setup_recurring_prices!
    universal_offer_code = create_universal_offer_code(user: @product.user)
    @params[:default_offer_code_id] = universal_offer_code.external_id
    post :update, params: @params, format: :json

    assert_equal universal_offer_code, @product.reload.default_offer_code
  end

  test "PUT update does not set the default offer code when offer code belongs to another user" do
    setup_recurring_prices!
    other_user_offer_code = create_offer_code(products: [create_product])
    @params[:default_offer_code_id] = other_user_offer_code.external_id
    post :update, params: @params, format: :json

    assert_nil @product.reload.default_offer_code
  end

  test "PUT update does not set the default offer code when a universal offer code excludes the product" do
    setup_recurring_prices!
    universal_offer_code = create_universal_offer_code(user: @product.user)
    universal_offer_code.update!(excluded_products: [@product])
    @params[:default_offer_code_id] = universal_offer_code.external_id
    post :update, params: @params, format: :json

    assert_nil @product.reload.default_offer_code
  end

  test "PUT update does not set the default offer code when offer code is not associated with the product" do
    setup_recurring_prices!
    unassociated_offer_code = create_offer_code(user: @product.user, products: [create_product(user: @product.user)])
    @params[:default_offer_code_id] = unassociated_offer_code.external_id
    post :update, params: @params, format: :json

    assert_nil @product.reload.default_offer_code
  end

  test "PUT update does not set the default offer code when offer code is expired" do
    setup_recurring_prices!
    expired_offer_code = create_offer_code(user: @product.user, products: [@product], valid_at: 2.days.ago, expires_at: 1.day.ago)
    @params[:default_offer_code_id] = expired_offer_code.external_id
    post :update, params: @params, format: :json

    assert_nil @product.reload.default_offer_code
  end

  test "PUT update clears the default offer code when nil is provided" do
    setup_recurring_prices!
    offer_code = create_offer_code(user: @product.user, products: [@product])
    @product.update!(default_offer_code: offer_code)
    @params[:default_offer_code_id] = nil
    post :update, params: @params, format: :json

    assert_nil @product.reload.default_offer_code
  end

  test "PUT update clears the default offer code when empty string is provided" do
    setup_recurring_prices!
    offer_code = create_offer_code(user: @product.user, products: [@product])
    @product.update!(default_offer_code: offer_code)
    @params[:default_offer_code_id] = ""
    post :update, params: @params, format: :json

    assert_nil @product.reload.default_offer_code
  end

  test "PUT update sets the suggested prices with pay-what-you-want pricing" do
    setup_recurring_prices!
    @params.merge!(
      id: @product.unique_permalink,
      variants: [
        {
          name: "First Tier",
          # Update the auto-created default tier in place (see setup_recurring_prices!).
          id: @product.default_tier.external_id,
          customizable_price: true,
          recurrence_price_values: {
            monthly: { enabled: true, price_cents: 2000, suggested_price_cents: 2200 },
            quarterly: { enabled: true, price_cents: 4500, suggested_price_cents: 4700 },
            yearly: { enabled: true, price_cents: 12000, suggested_price_cents: 12200 },
            biannually: { enabled: false },
            every_two_years: { enabled: true, price_cents: 20000, suggested_price_cents: 21000 }
          }
        }
      ]
    )

    post :update, params: @params, format: :json

    first_tier = @tier_category.reload.variants.find_by(name: "First Tier")
    first_tier_prices = first_tier.prices

    assert_equal true, first_tier.customizable_price
    assert_equal 2200, first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).suggested_price_cents
    assert_equal 4700, first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).suggested_price_cents
    assert_equal 12200, first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY).suggested_price_cents
    assert_equal 21000, first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS).suggested_price_cents
  end

  # --- shipping ---------------------------------------------------------------

  def make_product_shippable!
    @product.is_physical = true
    @product.require_shipping = true
    @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)
    @product.save!
  end

  test "PUT update sets the shipping rates as configured with no duplicates on the product" do
    make_product_shippable!
    post :update, params: {
      id: @product.unique_permalink,
      shipping_destinations: [
        { country_code: "US", one_item_rate_cents: 1200, multiple_items_rate_cents: 600 },
        { country_code: "DE", one_item_rate_cents: 1000, multiple_items_rate_cents: 500 }
      ]
    }, format: :json

    assert_response :success
    assert_equal 2, @product.reload.shipping_destinations.alive.size
    assert_equal "US", @product.shipping_destinations.alive.first.country_code
    assert_equal 1200, @product.shipping_destinations.alive.first.one_item_rate_cents
    assert_equal 600, @product.shipping_destinations.alive.first.multiple_items_rate_cents
    assert_equal "DE", @product.shipping_destinations.alive.second.country_code
    assert_equal 1000, @product.shipping_destinations.alive.second.one_item_rate_cents
    assert_equal 500, @product.shipping_destinations.alive.second.multiple_items_rate_cents
  end

  test "PUT update does not accept duplicate submission for the same country for a product" do
    make_product_shippable!
    post :update, params: {
      id: @product.unique_permalink,
      shipping_destinations: [
        { country_code: "US", one_item_rate_cents: 1200, multiple_items_rate_cents: 600 },
        { country_code: "US", one_item_rate_cents: 1000, multiple_items_rate_cents: 500 }
      ]
    }, format: :json

    assert_not response.successful?
    assert_equal "Sorry, shipping destinations have to be unique.", response.parsed_body["error_message"]
  end

  test "PUT update does not allow link to be saved if there are no shipping destinations" do
    make_product_shippable!
    post :update, params: { id: @product.unique_permalink, shipping_destinations: [] }, format: :json

    assert_not response.successful?
    assert_equal "The product needs to be shippable to at least one destination.", response.parsed_body["error_message"]
    assert_equal 1, @product.reload.shipping_destinations.alive.size
  end

  test "PUT update sets the shipping rates for virtual countries with no duplicates on the product" do
    make_product_shippable!
    post :update, params: {
      id: @product.unique_permalink,
      shipping_destinations: [
        { country_code: "EUROPE", one_item_rate_cents: 1200, multiple_items_rate_cents: 600 },
        { country_code: "ASIA", one_item_rate_cents: 1000, multiple_items_rate_cents: 500 }
      ]
    }, format: :json

    assert_response :success
    assert_equal 2, @product.reload.shipping_destinations.alive.size
    assert_equal "EUROPE", @product.shipping_destinations.alive.first.country_code
    assert_equal 1200, @product.shipping_destinations.alive.first.one_item_rate_cents
    assert_equal 600, @product.shipping_destinations.alive.first.multiple_items_rate_cents
    assert_equal "ASIA", @product.shipping_destinations.alive.second.country_code
    assert_equal 1000, @product.shipping_destinations.alive.second.one_item_rate_cents
    assert_equal 500, @product.shipping_destinations.alive.second.multiple_items_rate_cents
  end

  test "PUT update does not accept duplicate submission for the same virtual country for a product" do
    make_product_shippable!
    post :update, params: {
      id: @product.unique_permalink,
      shipping_destinations: [
        { country_code: "EUROPE", one_item_rate_cents: 1200, multiple_items_rate_cents: 600 },
        { country_code: "EUROPE", one_item_rate_cents: 1000, multiple_items_rate_cents: 500 }
      ]
    }, format: :json

    assert_not response.successful?
    assert_equal "Sorry, shipping destinations have to be unique.", response.parsed_body["error_message"]
  end

  # --- Tags and Categories ----------------------------------------------------

  test "PUT update adds tags when there are none" do
    tags = ["some sort of tàg!", "tagme", "🐗🐗"]
    assert_difference -> { Tag.count }, 3 do
      post(:update, params: { id: @product.unique_permalink, tags: })
    end
    assert_equal tags, @product.tags.pluck(:name)
  end

  test "PUT update adds tags when they exist" do
    tags = ["some sort of tàg!", "tagme", "🐗🐗"]
    create_tag(name: "tagme")
    @product.tag!("🐗🐗")
    assert_difference -> { Tag.count }, 1 do
      post(:update, params: { id: @product.unique_permalink, tags: })
    end
    assert_equal 3, @product.reload.tags.length
    assert_equal true, @product.has_tag?("some sort of tàg!")
  end

  test "PUT update removes all tags" do
    @product.tag!("one tag")
    @product.tag!("another tag")
    assert_difference -> { @product.reload.tags.length }, -2 do
      post(:update, params: { id: @product.unique_permalink, tags: [] })
    end
  end

  test "PUT update does not remove tags if unchanged" do
    @product.tag!("one tag")
    @product.tag!("another tag")
    assert_no_difference -> { @product.reload.tags.length } do
      post(:update, params: { id: @product.unique_permalink, tags: @product.tags.pluck(:name) })
    end
    assert_equal ["one tag", "another tag"], @product.tags.pluck(:name)
  end

  # --- custom attributes ------------------------------------------------------

  test "PUT update saves the custom attributes properly" do
    custom_attributes = [{ name: "author", value: "amir" }, { name: "chapters", value: "2" }]
    post :update, params: { id: @product.unique_permalink, custom_attributes: }
    assert_equal custom_attributes.as_json, @product.reload.custom_attributes
  end

  # --- without files ----------------------------------------------------------

  test "PUT update allows updating a published product to have no files" do
    assert_difference -> { Link.find(@product.id).alive_product_files.count }, -1 do
      post :update, params: { id: @product.unique_permalink, files: [] }, format: :json
    end
    assert_response :success
  end

  # --- public files -----------------------------------------------------------

  def public_files_description(file1, file2)
    <<~HTML
      <p>Some text</p>
      <public-file-embed id="#{file1.public_id}"></public-file-embed>
      <p>Hello world!</p>
      <public-file-embed id="#{file2.public_id}"></public-file-embed>
      <p>More text</p>
    HTML
  end

  test "PUT update updates existing public files and the product description appropriately" do
    public_file1 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 1")
    public_file2 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 2")
    description = public_files_description(public_file1, public_file2)
    @product.update!(description:)

    files_params = [
      { "id" => public_file1.public_id, "name" => "Updated Audio 1", "status" => { "type" => "saved" } },
      { "id" => public_file2.public_id, "name" => "Updated Audio 2", "status" => { "type" => "saved" } },
      { "id" => "blob:http://example.com/audio.mp3", "name" => "Audio 3", "status" => { "type" => "uploading" } }
    ]

    post :update, params: { id: @product.unique_permalink, description:, public_files: files_params }, format: :json

    assert_response :success
    assert_equal ["Updated Audio 1", nil], public_file1.reload.attributes.values_at("display_name", "scheduled_for_deletion_at")
    assert_equal ["Updated Audio 2", nil], public_file2.reload.attributes.values_at("display_name", "scheduled_for_deletion_at")
    assert_equal 2, @product.public_files.alive.count
    assert_equal description, @product.reload.description
  end

  test "PUT update schedules unused public files for deletion" do
    public_file1 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 1")
    public_file2 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 2")
    description = public_files_description(public_file1, public_file2)
    @product.update!(description:)

    unused_file = create_public_file(with_audio: true, resource: @product)
    files_params = [{ "id" => public_file1.public_id, "name" => "Audio 1", "status" => { "type" => "saved" } }]

    post :update, params: { id: @product.unique_permalink, description:, public_files: files_params }, format: :json

    assert_response :success
    assert_equal 3, @product.public_files.alive.count
    assert_includes @product.reload.description, public_file1.public_id
    assert_not_includes @product.description, public_file2.public_id
    assert_not_includes @product.description, unused_file.public_id
    assert_in_delta 10.days.from_now, unused_file.reload.scheduled_for_deletion_at, 5.seconds
    assert_nil public_file1.reload.scheduled_for_deletion_at
    assert_in_delta 10.days.from_now, public_file2.reload.scheduled_for_deletion_at, 5.seconds
  end

  test "PUT update removes invalid file embeds from content" do
    public_file1 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 1")
    public_file2 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 2")
    @product.update!(description: public_files_description(public_file1, public_file2))

    content_with_invalid_embeds = <<~HTML
      <p>Some text</p>
      <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
      <p>Middle text</p>
      <public-file-embed id="nonexistent"></public-file-embed>
      <public-file-embed></public-file-embed>
      <p>More text</p>
    HTML
    files_params = [
      { "id" => public_file1.public_id, "name" => "Audio 1", "status" => { "type" => "saved" } },
      { "id" => public_file2.public_id, "name" => "Audio 2", "status" => { "type" => "saved" } },
    ]

    post :update, params: { id: @product.unique_permalink, description: content_with_invalid_embeds, public_files: files_params }, format: :json

    assert_response :success
    assert_equal(<<~HTML, @product.reload.description)
      <p>Some text</p>
      <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
      <p>Middle text</p>


      <p>More text</p>
    HTML
    assert_equal 2, @product.public_files.alive.count
    assert_nil public_file1.reload.scheduled_for_deletion_at
    assert_in_delta 10.days.from_now, public_file2.reload.scheduled_for_deletion_at, 5.seconds
  end

  test "PUT update handles missing public_files params" do
    public_file1 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 1")
    public_file2 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 2")
    description = public_files_description(public_file1, public_file2)
    @product.update!(description:)

    post :update, params: { id: @product.unique_permalink, description: }, format: :json

    assert_response :success
    assert_equal(<<~HTML, @product.reload.description)
      <p>Some text</p>

      <p>Hello world!</p>

      <p>More text</p>
    HTML
    assert public_file1.reload.scheduled_for_deletion_at.present?
    assert public_file2.reload.scheduled_for_deletion_at.present?
  end

  test "PUT update handles empty description with public files" do
    public_file1 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 1")
    public_file2 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 2")
    @product.update!(description: public_files_description(public_file1, public_file2))

    files_params = [{ "id" => public_file1.public_id, "status" => { "type" => "saved" } }]

    post :update, params: { id: @product.unique_permalink, description: "", public_files: files_params }, format: :json

    assert_response :success
    assert_equal "", @product.reload.description
    assert public_file1.reload.scheduled_for_deletion_at.present?
    assert public_file2.reload.scheduled_for_deletion_at.present?
  end

  test "PUT update rolls back public files on error" do
    public_file1 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 1")
    public_file2 = create_public_file(with_audio: true, resource: @product, display_name: "Audio 2")
    description = public_files_description(public_file1, public_file2)
    @product.update!(description:)

    files_params = [{ "id" => public_file1.public_id, "name" => "Updated Audio 1", "status" => { "type" => "saved" } }]
    PublicFile.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(public_file1))

    post :update, params: { id: @product.unique_permalink, description:, public_files: files_params }, format: :json

    assert_not response.successful?
    assert_equal "Audio 1", public_file1.reload.display_name
    assert_nil public_file1.reload.scheduled_for_deletion_at
    assert_nil public_file2.reload.scheduled_for_deletion_at
    assert_equal description, @product.reload.description
  end

  # --- multiple files ---------------------------------------------------------

  def files_data_from_urls(urls)
    urls.map { { id: SecureRandom.uuid, url: _1 } }
  end

  def stub_s3_etags(etags_by_key)
    requested_keys = []
    s3_object = Struct.new(:etag)
    bucket = Object.new
    bucket.define_singleton_method(:object) do |key|
      requested_keys << key
      s3_object.new(etags_by_key.fetch(key))
    end
    resource = Object.new
    resource.define_singleton_method(:bucket) do |bucket_name|
      raise "Unexpected bucket #{bucket_name}" unless bucket_name == S3_BUCKET

      bucket
    end
    Aws::S3::Resource.stubs(:new).returns(resource)
    requested_keys
  end

  def s3_key_for(url)
    ProductFile.new(url:).s3_key
  end

  def clear_setup_files
    @product.product_files.alive.each(&:mark_deleted!)
    @product.cached_alive_product_files = nil
  end

  test "PUT update reuses the same file row across repeated identical editor retry requests" do
    Feature.activate_user(Product::SaveContract::FEATURE_NAME, @seller)
    clear_setup_files
    rich_content = create_product_rich_content(entity: @product, description: [{ "type" => "paragraph" }])
    url = "#{S3_BASE_URL}attachments/retry/original/guide.pdf"

    5.times do
      temporary_id = SecureRandom.uuid
      post :update, params: @params.merge(
        files: [{ id: temporary_id, url:, size: 123 }],
        rich_content: [{ id: rich_content.external_id, title: "Files", description: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: temporary_id, uid: SecureRandom.uuid } }] } }]
      ), format: :json

      assert_response :success
      product_file = @product.product_files.alive.sole
      assert_equal product_file.external_id, response.parsed_body.dig("file_id_mappings", temporary_id)
      assert_equal [product_file.id], rich_content.reload.embedded_product_file_ids_in_order
    end

    assert_equal 1, @product.product_files.alive.count
  end

  test "PUT update returns file id mappings and a consecutive save without reload reuses the file row" do
    Feature.activate_user(Product::SaveContract::FEATURE_NAME, @seller)
    clear_setup_files
    rich_content = create_product_rich_content(entity: @product, description: [{ "type" => "paragraph" }])
    url = "#{S3_BASE_URL}attachments/consecutive/original/guide.pdf"
    temporary_id = SecureRandom.uuid

    post :update, params: @params.merge(
      files: [{ id: temporary_id, url:, size: 123 }],
      rich_content: [{ id: rich_content.external_id, title: "Files", description: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: temporary_id, uid: "file-uid" } }] } }]
    ), format: :json

    assert_response :success
    product_file = @product.product_files.alive.sole
    canonical_id = response.parsed_body.dig("file_id_mappings", temporary_id)
    assert_equal product_file.external_id, canonical_id

    post :update, params: @params.merge(
      files: [{ id: canonical_id, url:, size: 123 }],
      rich_content: [{ id: rich_content.external_id, title: "Files", description: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: canonical_id, uid: "file-uid" } }] } }]
    ), format: :json

    assert_response :success
    assert_equal [product_file.id], @product.reload.product_files.alive.ids
    assert_equal [product_file.id], rich_content.reload.embedded_product_file_ids_in_order
  end

  test "PUT update dedupes different urls when S3 ETag and size match" do
    clear_setup_files
    original_url = "#{S3_BASE_URL}attachments/fingerprint/original/guide.pdf"
    retried_url = "#{S3_BASE_URL}attachments/fingerprint-retry/original/guide.pdf"
    product_file = create_product_file(link: @product, url: original_url, size: 123, display_name: "Guide")
    temporary_id = SecureRandom.uuid
    requested_keys = stub_s3_etags(
      s3_key_for(original_url) => "\"same-etag\"",
      s3_key_for(retried_url) => "\"same-etag\"",
    )

    assert_no_difference -> { @product.product_files.alive.count } do
      post :update, params: @params.merge(
        files: [
          { id: temporary_id, url: retried_url, size: 123, display_name: "Guide" },
        ]
      ), format: :json
    end

    assert_response :success
    assert_equal product_file.external_id, response.parsed_body.dig("file_id_mappings", temporary_id)
    assert_includes requested_keys, s3_key_for(original_url)
    assert_includes requested_keys, s3_key_for(retried_url)
  end

  test "PUT update keeps same-name same-size files with different S3 fingerprints separate" do
    clear_setup_files
    original_url = "#{S3_BASE_URL}attachments/fingerprint-a/original/guide.pdf"
    new_url = "#{S3_BASE_URL}attachments/fingerprint-b/original/guide.pdf"
    product_file = create_product_file(link: @product, url: original_url, size: 123, display_name: "Guide")
    temporary_id = SecureRandom.uuid
    requested_keys = stub_s3_etags(
      s3_key_for(original_url) => "\"first-etag\"",
      s3_key_for(new_url) => "\"second-etag\"",
    )

    assert_difference -> { @product.product_files.alive.count }, 1 do
      post :update, params: @params.merge(
        files: [
          { id: product_file.external_id, url: original_url, size: 123, display_name: "Guide" },
          { id: temporary_id, url: new_url, size: 123, display_name: "Guide" },
        ]
      ), format: :json
    end

    assert_response :success
    new_file = @product.product_files.alive.find_by!(url: new_url)
    assert_equal new_file.external_id, response.parsed_body.dig("file_id_mappings", temporary_id)
    assert_not_equal product_file.external_id, response.parsed_body.dig("file_id_mappings", temporary_id)
    # The payload names the original by its canonical id, so it is excluded
    # from the candidate pool and never fingerprinted.
    assert_not_includes requested_keys, s3_key_for(original_url)
  end

  test "PUT update keeps a deliberate second embed of an already-attached url" do
    clear_setup_files
    url = "#{S3_BASE_URL}attachments/deliberate/original/guide.pdf"
    product_file = create_product_file(link: @product, url:, size: 123, display_name: "Guide")
    temporary_id = SecureRandom.uuid

    # The "Existing product files" picker names the canonical row AND adds a
    # second entry for the same url. A retry can never name an id the client
    # never received, so naming it means the seller wants both rows.
    assert_difference -> { @product.product_files.alive.count }, 1 do
      post :update, params: @params.merge(
        files: [
          { id: product_file.external_id, url:, size: 123, display_name: "Guide" },
          { id: temporary_id, url:, size: 123, display_name: "Guide" },
        ]
      ), format: :json
    end

    assert_response :success
    assert_not_equal product_file.external_id, response.parsed_body.dig("file_id_mappings", temporary_id)
  end

  test "PUT update preserves correct s3 key for s3 files containing percent and ampersand" do
    urls = ["#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test file %26 & ) %29.txt"]
    post :update, params: @params.merge!(files: files_data_from_urls(urls)), format: :json
    assert_response :success
    product_file = @product.alive_product_files.first
    assert_equal "specs/test file %26 & ) %29.txt", product_file.s3_key
  end

  test "PUT update saves the files properly" do
    urls = ["#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png", "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf"]
    post :update, params: @params.merge!(files: files_data_from_urls(urls)), format: :json
    assert_response :success
    assert_equal 2, @product.alive_product_files.count
    assert_equal "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png", @product.alive_product_files[0].url
    assert_equal "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf", @product.alive_product_files[1].url
  end

  test "PUT update has pdf filetype" do
    urls = ["#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png", "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf"]
    post :update, params: @params.merge!(files: files_data_from_urls(urls)), format: :json
    assert_equal true, @product.has_filetype?("pdf")
  end

  test "PUT update supports deleting and adding files" do
    @product.product_files << create_product_file(link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
    @product.save!

    urls = ["#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf"]
    post :update, params: @params.merge!(files: files_data_from_urls(urls)), format: :json
    assert_response :success
    assert_equal 1, @product.reload.alive_product_files.count
    assert_equal "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf", @product.alive_product_files.first.url
  end

  test "PUT update allows 0 files for unpublished product" do
    @product.purchase_disabled_at = Time.current
    @product.product_files << create_product_file(link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
    @product.save!

    post :update, params: @params.merge!(files: {}), format: :json
    assert_response :success
  end

  test "PUT update updates product's rich content when file embed IDs exist in product_rich_content" do
    urls = %W[#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png #{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf]
    files_data = files_data_from_urls(urls)
    rich_content = create_product_rich_content(entity: @product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
    old_rich_content = rich_content.description
    product_rich_content = [{ id: rich_content.external_id, title: "Page title", description: { type: "doc", content: old_rich_content.dup.concat([{ "type" => "fileEmbed", "attrs" => { "id" => files_data[0][:id], "uid" => "64e84875-c795-567c-d2dd-96336ab093d5" } }, { "type" => "fileEmbed", "attrs" => { "id" => files_data[1][:id], "uid" => "0c042930-2df1-4583-82ef-a6317213868d" } }]) } }]

    post :update, params: @params.merge!(rich_content: product_rich_content, files: files_data), format: :json

    new_external_id_1, new_external_id_2 = @product.product_files.alive.map(&:external_id)
    assert_equal([{ id: rich_content.external_id, page_id: rich_content.external_id, variant_id: nil, title: "Page title", description: { type: "doc", content: old_rich_content.dup.concat([{ "type" => "fileEmbed", "attrs" => { "id" => new_external_id_1, "uid" => "64e84875-c795-567c-d2dd-96336ab093d5" } }, { "type" => "fileEmbed", "attrs" => { "id" => new_external_id_2, "uid" => "0c042930-2df1-4583-82ef-a6317213868d" } }]) }, updated_at: rich_content.reload.updated_at }], @product.reload.rich_content_json)
  end

  test "PUT update does not produce transitive ID collisions when a new file's external_id matches another file's placeholder ID" do
    rich_content_node = {
      "type" => "doc",
      "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => "placeholder_a" } },
        { "type" => "fileEmbed", "attrs" => { "id" => "placeholder_b" } },
      ],
    }
    mappings = { "placeholder_a" => "placeholder_b", "placeholder_b" => "real_b" }

    @product.send(:apply_rich_content_id_mappings, rich_content_node, mappings)

    embed_ids = rich_content_node["content"].map { |node| node["attrs"]["id"] }
    assert_equal ["placeholder_b", "real_b"], embed_ids
  end

  test "PUT update handles nil nodes in rich content without crashing" do
    rich_content_node = {
      "type" => "doc",
      "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => "placeholder_a" } },
        nil,
        { "type" => "paragraph", "content" => nil },
        { "type" => "paragraph", "content" => [nil, { "type" => "text", "text" => "hello" }] },
        { "type" => "fileEmbed", "attrs" => nil },
      ]
    }
    mappings = { "placeholder_a" => "real_a" }

    @product.send(:apply_rich_content_id_mappings, rich_content_node, mappings)
    assert_equal "real_a", rich_content_node["content"][0]["attrs"]["id"]
  end

  test "PUT update saves variant-level rich content containing file embeds with the persisted IDs" do
    external_id1 = "ext1"
    external_id2 = "ext2"
    category = create_variant_category(link: @product, title: "Versions")
    version1 = create_variant(variant_category: category, name: "Version 1")
    version2 = create_variant(variant_category: category, name: "Version 2")
    version1_rich_content1 = create_rich_content(entity: version1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
    version1_rich_content2 = create_rich_content(entity: version1, deleted_at: 1.day.ago)
    version1_rich_content3 = create_rich_content(entity: version1)
    another_product_version_rich_content = create_rich_content(entity: create_variant)
    version1_rich_content1_updated_description = [{ "type" => "fileEmbed", "attrs" => { "id" => external_id1, "uid" => "64e84875-c795-567c-d2dd-96336ab093d5" } }, { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }]
    version1_new_rich_content_description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newly added version 1 content" }] }]
    version2_new_rich_content_description = [{ "type" => "fileEmbed", "attrs" => { "id" => external_id2, "uid" => "0c042930-2df1-4583-82ef-a6317213868d" } }]

    post :update, params: @params.merge!(
      files: [{ id: external_id1, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/#{external_id1}/original/pencil.png" }, { id: external_id2, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/#{external_id2}/original/manual.pdf" }],
      variants: [{ id: version1.external_id, name: version1.name, rich_content: [{ id: version1_rich_content1.external_id, title: "Version 1 - Page 1", description: { type: "doc", content: version1_rich_content1_updated_description } }, { id: nil, title: "Version 1 - Page 2", description: { type: "doc", content: version1_new_rich_content_description } }] }, { id: version2.external_id, name: version2.name, rich_content: [{ id: nil, title: "Version 2 - Page 1", description: { type: "doc", content: version2_new_rich_content_description } }] }]
    ), format: :json

    assert_equal false, version1_rich_content1.reload.deleted?
    assert_equal true, version1_rich_content2.reload.deleted?
    assert_equal true, version1_rich_content3.reload.deleted?
    assert_equal 4, version1.rich_contents.count
    assert_equal 2, version1.alive_rich_contents.count
    version1_new_rich_content = version1.alive_rich_contents.last
    assert_equal version1_new_rich_content_description, version1_new_rich_content.description
    assert_equal 1, version2.rich_contents.count
    assert_equal 1, version2.alive_rich_contents.count
    assert_equal false, another_product_version_rich_content.reload.deleted?
  end

  test "PUT update calls SaveContentUpsellsService when rich content or description changes" do
    rich_content = create_product_rich_content(entity: @product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Original content" }] }])
    product_rich_content = [{ id: rich_content.external_id, title: "Page title", description: { type: "doc", content: [{ "type" => "paragraph", "content": [{ "type" => "text", "text" => "New content" }] }] } }]

    calls = spy_on_class_new(SaveContentUpsellsService) do
      post :update, params: @params.merge(rich_content: product_rich_content), format: :json
    end
    assert_response :success

    assert calls.any? { |call|
      call[:kwargs][:seller] == @product.user &&
        call[:kwargs][:content] == "New description" &&
        call[:kwargs][:old_content] == "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes."
    }, "Expected SaveContentUpsellsService to be built for the description change"

    assert calls.any? { |call|
      next false unless call[:kwargs][:content].is_a?(Array)
      call[:kwargs][:seller] == @product.user &&
        call[:kwargs][:content].as_json == [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "New content" }] }] &&
        call[:kwargs][:old_content] == [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Original content" }] }]
    }, "Expected SaveContentUpsellsService to be built for the rich-content change"
  end

  test "PUT update saves the product file thumbnails" do
    product_file1 = create_streamable_video(link: @product)
    product_file2 = create_readable_document(link: @product)
    @product.product_files << product_file1
    @product.product_files << product_file2
    blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"), filename: "smilie.png")
    blob.analyze
    files_data = [{ id: product_file1.external_id, url: product_file1.url, thumbnail: { signed_id: blob.signed_id } }, { id: product_file2.external_id, url: product_file2.url }]

    assert_changes -> { product_file1.reload.thumbnail.blob }, from: nil, to: blob do
      post :update, params: @params.merge!(files: files_data), format: :json
    end

    assert_nil product_file2.reload.thumbnail.blob
    assert_response :success

    assert_no_changes -> { product_file1.reload.thumbnail.blob } do
      post :update, params: { id: @product.unique_permalink, link: @params.merge!(files: files_data), format: :json }
    end
  end

  # --- adding integrations ----------------------------------------------------
  #
  # These replace the shared "manages integrations" examples (four per
  # integration). The RSpec `:vcr` metadata auto-wrapped every example; only the
  # discord/google "modifies an existing integration" paths actually hit the
  # network (they reconcile members on the changed server/calendar), so only those
  # get an explicit VCR cassette here — the rest either make no request or stub it.

  def create_integration(integration_name)
    send("create_#{integration_name}_integration")
  end

  def flatten_integration_params(params)
    params.except("integration_details").merge(params["integration_details"])
  end

  def manages_integrations_adds_new(integration_name, new_params)
    assert_difference ["Integration.count", "ProductIntegration.count"], 1 do
      post :update, params: @params.merge(integrations: { integration_name => new_params }), as: :json
    end

    product_integration = ProductIntegration.last
    integration = Integration.last
    assert_equal integration, product_integration.integration
    assert_equal @product, product_integration.product
    assert_equal Integration.type_for(integration_name), integration.type
    flatten_integration_params(new_params).each { |key, value| assert_equal value, integration.send(key) }
  end

  def manages_integrations_modifies_existing(integration_name, modified_params)
    @product.active_integrations << create_integration(integration_name)

    assert_no_difference ["Integration.count", "ProductIntegration.count"] do
      post :update, params: @params.merge(integrations: { integration_name => modified_params }), as: :json
    end

    product_integration = ProductIntegration.last
    integration = Integration.last
    assert_equal integration, product_integration.integration
    assert_equal @product, product_integration.product
    assert_equal Integration.type_for(integration_name), integration.type
    flatten_integration_params(modified_params).each { |key, value| assert_equal value, integration.send(key) }
  end

  def manages_integrations_variants_adds_new(integration_name, new_params)
    assert_difference ["Integration.count", "ProductIntegration.count", "BaseVariantIntegration.count"], 1 do
      post :update, params: @params.merge(
        integrations: { integration_name => new_params },
        variants: [
          { name: "PC", price_difference_cents: 100, max_purchase_count: 100 },
          { name: "Mac", price_difference_cents: 10000, max_purchase_count: 100, integrations: { integration_name => true } },
        ]
      ), as: :json
    end

    base_variant_integration = BaseVariantIntegration.last
    product_integration = ProductIntegration.last
    integration = Integration.last
    mac_variant = @product.alive_variants.find_by(name: "mac")

    assert_equal integration, product_integration.integration
    assert_equal integration, base_variant_integration.integration
    assert_equal mac_variant, base_variant_integration.base_variant
    assert_equal 1, mac_variant.active_integrations.count
    assert_equal @product, product_integration.product
    assert_equal Integration.type_for(integration_name), integration.type
    flatten_integration_params(new_params).each { |key, value| assert_equal value, integration.send(key) }
  end

  def manages_integrations_variants_modifies_existing(integration_name, modified_params)
    category = create_variant_category(title: "versions", link: @product)
    variant_1 = create_variant(variant_category: category, name: "pc")
    integration = create_integration(integration_name)
    variant_2 = create_variant(variant_category: category, name: "mac", active_integrations: [integration])
    @product.active_integrations << integration

    assert_difference "BaseVariantIntegration.count", 1 do
      assert_no_difference ["Integration.count", "ProductIntegration.count"] do
        post :update, params: @params.merge(
          integrations: { integration_name => modified_params },
          variants: [
            { id: variant_1.external_id, name: variant_1.name, price_difference_cents: 1000, max_purchase_count: 100 },
            { id: variant_2.external_id, name: variant_2.name, price_difference_cents: 10000, integrations: { integration_name => true } },
            { name: "linux", price_difference_cents: 0, integrations: { integration_name => true } },
          ]
        ), as: :json
      end
    end

    base_variant_integrations = BaseVariantIntegration.all[-2, 2]
    product_integration = ProductIntegration.last
    integration.reload

    assert_equal integration, product_integration.integration
    assert_equal integration, base_variant_integrations[0].integration
    assert_equal @product.variant_categories_alive.find_by(title: "versions").alive_variants.find_by(name: "mac"), base_variant_integrations[0].base_variant
    assert_equal integration, base_variant_integrations[1].integration
    assert_equal @product.variant_categories_alive.find_by(title: "versions").alive_variants.find_by(name: "linux"), base_variant_integrations[1].base_variant
    assert_equal @product, product_integration.product
    assert_equal Integration.type_for(integration_name), integration.type
    flatten_integration_params(modified_params).each { |key, value| assert_equal value, integration.send(key) }
  end

  def circle_new_params
    { "api_key" => GlobalConfig.get("CIRCLE_API_KEY"), "keep_inactive_members" => false, "integration_details" => { "community_id" => "0", "space_group_id" => "0" } }
  end

  def circle_modified_params
    { "api_key" => "modified_api_key", "keep_inactive_members" => true, "integration_details" => { "community_id" => "1", "space_group_id" => "1" } }
  end

  def discord_new_params
    { "keep_inactive_members" => false, "integration_details" => { "server_id" => "0", "server_name" => "Gaming", "username" => "gumbot" } }
  end

  def discord_modified_params
    { "keep_inactive_members" => true, "integration_details" => { "server_id" => "1", "server_name" => "Tech", "username" => "techuser" } }
  end

  def zoom_new_params
    { "keep_inactive_members" => false, "integration_details" => { "user_id" => "0", "email" => "test@zoom.com", "access_token" => "test_access_token", "refresh_token" => "test_refresh_token" } }
  end

  def zoom_modified_params
    { "keep_inactive_members" => true, "integration_details" => { "user_id" => "1", "email" => "test2@zoom.com", "access_token" => "modified_access_token", "refresh_token" => "modified_refresh_token" } }
  end

  def google_calendar_new_params
    { "keep_inactive_members" => false, "integration_details" => { "calendar_id" => "0", "calendar_summary" => "Holidays", "access_token" => "test_access_token", "refresh_token" => "test_refresh_token" } }
  end

  def google_calendar_modified_params
    { "keep_inactive_members" => true, "integration_details" => { "calendar_id" => "1", "calendar_summary" => "Meetings", "access_token" => "modified_access_token", "refresh_token" => "modified_refresh_token" } }
  end

  test "PUT update circle integration adds a new integration" do
    manages_integrations_adds_new("circle", circle_new_params)
  end

  test "PUT update circle integration modifies an existing integration" do
    manages_integrations_modifies_existing("circle", circle_modified_params)
  end

  test "PUT update circle integration adds a new integration for variants" do
    manages_integrations_variants_adds_new("circle", circle_new_params)
  end

  test "PUT update circle integration modifies an existing integration for variants" do
    manages_integrations_variants_modifies_existing("circle", circle_modified_params)
  end

  test "PUT update discord integration adds a new integration" do
    manages_integrations_adds_new("discord", discord_new_params)
  end

  test "PUT update discord integration modifies an existing integration" do
    VCR.use_cassette("LinksController/within_seller_area/PUT_update/adding_integrations/discord_integration/behaves_like_manages_integrations/modifies_an_existing_integration") do
      manages_integrations_modifies_existing("discord", discord_modified_params)
    end
  end

  test "PUT update discord integration adds a new integration for variants" do
    manages_integrations_variants_adds_new("discord", discord_new_params)
  end

  test "PUT update discord integration modifies an existing integration for variants" do
    VCR.use_cassette("LinksController/within_seller_area/PUT_update/adding_integrations/discord_integration/behaves_like_manages_integrations/variants/modifies_an_existing_integration") do
      manages_integrations_variants_modifies_existing("discord", discord_modified_params)
    end
  end

  test "PUT update discord integration disconnection succeeds if bot is successfully removed from server" do
    server_id = "0"
    request_header = { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }
    discord_integration = create_discord_integration(server_id:)
    @product.active_integrations << discord_integration

    WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}")
           .with(headers: request_header)
           .to_return(status: 204)

    assert_difference -> { @product.active_integrations.count }, -1 do
      post :update, params: { id: @product.unique_permalink, link: @params.merge(integrations: {}) }, as: :json
    end

    assert_equal [], @product.live_product_integrations.pluck(:integration_id)
  end

  test "PUT update discord integration disconnection fails if removing bot from server fails" do
    server_id = "0"
    request_header = { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" }
    discord_integration = create_discord_integration(server_id:)
    @product.active_integrations << discord_integration

    WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}")
           .with(headers: request_header)
           .to_return(status: 404, body: { code: Discordrb::Errors::UnknownMember.code }.to_json)

    assert_no_difference -> { @product.active_integrations.count } do
      post :update, params: { id: @product.unique_permalink, link: @params.merge(integrations: {}) }, as: :json
    end

    assert_equal [discord_integration.id], @product.live_product_integrations.pluck(:integration_id)
    assert_equal "Could not disconnect the discord integration, please try again.", response.parsed_body["error_message"]
  end

  test "PUT update zoom integration adds a new integration" do
    manages_integrations_adds_new("zoom", zoom_new_params)
  end

  test "PUT update zoom integration modifies an existing integration" do
    manages_integrations_modifies_existing("zoom", zoom_modified_params)
  end

  test "PUT update zoom integration adds a new integration for variants" do
    manages_integrations_variants_adds_new("zoom", zoom_new_params)
  end

  test "PUT update zoom integration modifies an existing integration for variants" do
    manages_integrations_variants_modifies_existing("zoom", zoom_modified_params)
  end

  test "PUT update google calendar integration adds a new integration" do
    manages_integrations_adds_new("google_calendar", google_calendar_new_params)
  end

  test "PUT update google calendar integration modifies an existing integration" do
    VCR.use_cassette("LinksController/within_seller_area/PUT_update/adding_integrations/google_calendar_integration/behaves_like_manages_integrations/modifies_an_existing_integration") do
      manages_integrations_modifies_existing("google_calendar", google_calendar_modified_params)
    end
  end

  test "PUT update google calendar integration adds a new integration for variants" do
    manages_integrations_variants_adds_new("google_calendar", google_calendar_new_params)
  end

  test "PUT update google calendar integration modifies an existing integration for variants" do
    VCR.use_cassette("LinksController/within_seller_area/PUT_update/adding_integrations/google_calendar_integration/behaves_like_manages_integrations/variants/modifies_an_existing_integration") do
      manages_integrations_variants_modifies_existing("google_calendar", google_calendar_modified_params)
    end
  end

  test "PUT update google calendar integration disconnection succeeds if the gumroad app is successfully disconnected from google account" do
    google_calendar_integration = create_google_calendar_integration
    @product.active_integrations << google_calendar_integration

    WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/revoke")
           .with(query: { token: google_calendar_integration.access_token })
           .to_return(status: 200)

    assert_difference -> { @product.active_integrations.count }, -1 do
      post :update, params: { id: @product.unique_permalink, link: @params.merge(integrations: {}) }, as: :json
    end

    assert_equal [], @product.live_product_integrations.pluck(:integration_id)
  end

  test "PUT update google calendar integration disconnection fails if disconnecting the gumroad app from google fails" do
    google_calendar_integration = create_google_calendar_integration
    @product.active_integrations << google_calendar_integration

    WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/revoke")
           .with(query: { token: google_calendar_integration.access_token })
           .to_return(status: 404)

    assert_no_difference -> { @product.active_integrations.count } do
      post :update, params: { id: @product.unique_permalink, link: @params.merge(integrations: {}) }, as: :json
    end

    assert_equal [google_calendar_integration.id], @product.live_product_integrations.pluck(:integration_id)
    assert_equal "Could not disconnect the google calendar integration, please try again.", response.parsed_body["error_message"]
  end

  # --- custom domains ---------------------------------------------------------

  test "PUT update updates the custom_domain when product has an existing custom domain" do
    create_custom_domain(user: nil, product: @product, domain: "example-domain.com")

    assert_changes -> { @product.reload.custom_domain.domain }, from: "example-domain.com", to: "example2.com" do
      post(:update, params: @params.merge(custom_domain: "example2.com"), format: :json)
    end

    assert_response :success
  end

  test "PUT update does not increment the failed verification attempts count when domain verification fails" do
    create_custom_domain(user: nil, product: @product, domain: "example-domain.com")
    @product.custom_domain.update!(failed_verification_attempts_count: 2)
    CustomDomainVerificationService.any_instance.stubs(:process).returns(false)

    assert_no_changes -> { @product.reload.custom_domain.failed_verification_attempts_count } do
      post(:update, params: @params.merge(custom_domain: "invalid.example.com"), format: :json)
    end
  end

  test "PUT update creates a new custom_domain when the product doesn't have an existing custom_domain" do
    assert_difference -> { CustomDomain.alive.count }, 1 do
      post(:update, params: @params.merge(custom_domain: "example2.com"), format: :json)
    end

    assert_equal "example2.com", @product.reload.custom_domain.domain
    assert_response :success
  end

  # --- RenameProductFileWorker ------------------------------------------------

  test "PUT update enqueues a RenameProductFileWorker job" do
    @product.product_files << create_product_file(link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
    @product.save!
    post :update, params: {
      id: @product.unique_permalink,
      files: [{ id: @product.product_files.last.external_id, display_name: "sample", description: "new description", url: @product.product_files.last.url }],
      rich_content: [],
    }
    assert_response :success
    product_file = @product.alive_product_files.last.reload

    assert_equal "sample", product_file.display_name
    assert_equal "new description", product_file.description
    assert_enqueued_sidekiq_job(RenameProductFileWorker, product_file.id)
  end

  # --- rich content -----------------------------------------------------------

  test "PUT update saves the rich content pages in the given order" do
    product = create_product(user: @seller)
    updated_rich_content1_description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }, { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "World" }] }]
    new_rich_content_description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newly added" }] }]
    rich_content1 = create_product_rich_content(title: "p1", position: 0, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
    rich_content2 = create_product_rich_content(title: "p2", position: 1, entity: product, deleted_at: 1.day.ago)
    rich_content3 = create_product_rich_content(title: "p3", position: 2, entity: product)
    rich_content4 = create_product_rich_content(title: "p4", position: 3, entity: product)
    another_product_rich_content = create_product_rich_content

    assert_equal [["p1", 0], ["p3", 2], ["p4", 3]], product.alive_rich_contents.sort_by(&:position).pluck(:title, :position)

    post :update, params: {
      id: product.unique_permalink,
      rich_content: [
        { id: rich_content4.external_id, title: "Intro", description: { type: "doc", content: [{ "type" => "paragraph" }] } },
        { id: rich_content1.external_id, title: "Page 1", description: { type: "doc", content: updated_rich_content1_description } },
        { title: "Page 2", description: { type: "doc", content: new_rich_content_description } },
        { title: "Page 3", description: nil },
      ],
      # The omitted "p3" page is titled, and a title counts as seller-authored
      # content — dropping it from the payload needs explicit deletion intent.
      confirmed_removed_rich_content_ids: [rich_content3.external_id],
    }, format: :json

    assert_equal false, rich_content1.reload.deleted?
    assert_equal updated_rich_content1_description, rich_content1.description
    assert_equal true, rich_content2.reload.deleted?
    assert_equal true, rich_content3.reload.deleted?
    assert_equal false, rich_content4.reload.deleted?
    assert_equal false, another_product_rich_content.reload.deleted?
    assert_equal 6, product.reload.rich_contents.count
    assert_equal 4, product.alive_rich_contents.count
    new_rich_content = product.alive_rich_contents.second_to_last
    assert_equal new_rich_content_description, new_rich_content.description
    assert_equal [["Intro", 0], ["Page 1", 1], ["Page 2", 2], ["Page 3", 3]], product.alive_rich_contents.sort_by(&:position).pluck(:title, :position)

    # A save with no rich content and no confirmed removals would wipe
    # content-bearing pages — the deletion guard now blocks it (see the
    # "content deletion guards" tests above).
    assert_no_difference -> { product.reload.alive_rich_contents.count } do
      post :update, params: { id: product.unique_permalink, rich_content: [] }, format: :json
    end
    assert_response :unprocessable_entity

    # Deletes all existing rich content pages when the seller confirmed
    # removing each of them.
    assert_difference -> { product.reload.alive_rich_contents.count }, -4 do
      assert_no_difference -> { product.rich_contents.count } do
        post :update, params: {
          id: product.unique_permalink,
          rich_content: [],
          confirmed_removed_rich_content_ids: product.alive_rich_contents.map(&:external_id),
        }, format: :json
      end
    end
  end

  # --- product_files_archive generation ---------------------------------------

  test "PUT update deletes all product-level archives when switching to variant-level archives" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2]
    folder1_id = SecureRandom.uuid
    description = [
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
      ] }
    ]
    files = [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }]

    assert_difference -> { @product.product_files_archives.alive.count }, 1 do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ title: "Page 1", description: { type: "doc", content: description } }],
        files:,
      }, format: :json
    end
    archives = @product.product_files_archives.alive.to_a
    archives.each do |archive|
      archive.mark_in_progress!
      archive.mark_ready!
    end

    assert_no_difference -> { ProductFilesArchive.count } do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: @product.alive_rich_contents.find_by(position: 0).external_id, title: "Page 1", description: { type: "doc", content: description } }],
        files:,
      }, format: :json
    end
    assert_equal true, archives.all?(&:alive?)

    assert_difference -> { ProductFilesArchive.where.not(variant_id: nil).alive.count }, 1 do
      assert_difference -> { @product.product_files_archives.alive.count }, -1 do
        post :update, params: {
          id: @product.unique_permalink,
          has_same_rich_content_for_all_variants: false,
          # The page moves from the product level to the variant, keeping its
          # id — mirroring what the editor sends when un-toggling "use the same
          # content for all versions" (an outdated payload without the id would be
          # blocked by the content deletion guard).
          variants: [{ name: "Version 1", rich_content: [{ id: @product.alive_rich_contents.find_by(position: 0).external_id, title: "Version 1 - Page 1", description: { type: "doc", content: description } }] }],
          files:,
        }, format: :json
      end
    end
  end

  test "PUT update deletes all variant-level archives when switching to product-level archives" do
    category = create_variant_category(link: @product, title: "Versions")
    version1 = create_variant(variant_category: category, name: "Version 1")

    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2]
    version1.product_files = [file1, file2]
    version1_rich_content_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }]

    assert_difference -> { version1.product_files_archives.alive.count }, 1 do
      assert_no_difference -> { @product.product_files_archives.alive.count } do
        post :update, params: {
          id: @product.unique_permalink,
          has_same_rich_content_for_all_variants: false,
          files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }],
          variants: [{ id: version1.external_id, name: version1.name, rich_content: [{ id: nil, title: "Version 1 - Page 1", description: { type: "doc", content: version1_rich_content_description } }] }]
        }, format: :json
      end
    end

    assert_difference -> { version1.product_files_archives.alive.count }, -1 do
      assert_difference -> { @product.product_files_archives.alive.count }, 1 do
        post :update, params: {
          id: @product.unique_permalink,
          has_same_rich_content_for_all_variants: true,
          # The page keeps its id as it moves from the variant to the product
          # level — mirroring what the editor sends when toggling "use the same
          # content for all versions" (an outdated payload without the id would be
          # blocked by the content deletion guard).
          rich_content: [{ id: version1.reload.alive_rich_contents.first.external_id, title: "Version 1 - Page 1", description: { type: "doc", content: version1_rich_content_description } }],
          files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }],
          variants: [{ id: version1.external_id, name: version1.name }]
        }, format: :json
      end
    end
  end

  test "PUT update does not generate a folder archive when nothing has changed" do
    assert_no_difference -> { @product.product_files_archives.folder_archives.alive.count } do
      post :update, params: { id: @product.unique_permalink, name: @product.name }, format: :json
    end
    assert_equal 0, @product.product_files_archives.folder_archives.alive.count
  end

  test "PUT update does not generate a folder archive when there are no folders" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    @product.product_files = [file1]
    description = [{ "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => "file1" } }]

    assert_no_difference -> { @product.product_files_archives.folder_archives.alive.count } do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
        files: [{ id: file1.external_id, url: file1.url }]
      }, format: :json
    end
  end

  test "PUT update does not generate a folder archive when a folder only contains 1 file" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    @product.product_files = [file1]
    description = [
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => SecureRandom.uuid }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } }] },
    ]

    assert_no_difference -> { @product.product_files_archives.folder_archives.alive.count } do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
        files: [{ id: file1.external_id, url: file1.url }]
      }, format: :json
    end
  end

  test "PUT update does not generate an updated folder archive when the product name or page name is changed" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2]

    folder1_id = SecureRandom.uuid
    folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: [folder1] } }],
      files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }]
    }, format: :json

    folder1_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)
    folder1_archive.mark_in_progress!
    folder1_archive.mark_ready!

    assert_no_difference -> { @product.product_files_archives.folder_archives.alive.count } do
      post :update, params: {
        id: @product.unique_permalink,
        name: "New product name",
        # Reuse the existing page's id — the editor renames a page in place
        # rather than replacing it with a brand-new one (a payload dropping the
        # id would be blocked by the content deletion guard).
        rich_content: [{ id: @product.alive_rich_contents.first.external_id, title: "New page title", description: { type: "doc", content: [folder1] } }],
        files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }],
      }, format: :json
    end
    assert_equal true, folder1_archive.reload.alive?
    assert_equal 1, @product.product_files_archives.folder_archives.alive.count
    assert_equal "New page title", @product.alive_rich_contents.first["title"]
    assert_equal "New product name", @product.reload.name
  end

  test "PUT update does not generate an updated folder archive when top-level files are modified" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    file3 = create_product_file(link: @product, display_name: "File 2")
    file4 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2, file3, file4]
    folder1_id = SecureRandom.uuid
    page1_description = [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => "file1" } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => "file2" } },
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
      ] }]

    assert_difference -> { @product.product_files_archives.folder_archives.alive.count }, 1 do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: page1_description } }],
        files: [file1, file2, file3, file4].map { { id: _1.external_id, url: _1.url } }
      }, format: :json
    end

    folder1_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)
    folder1_archive.mark_in_progress!
    folder1_archive.mark_ready!

    file2.update!(display_name: "New file name")
    file5 = create_product_file(link: @product, display_name: "File 3")
    @product.product_files << file5
    updated_description = [
      { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => "file2" } },
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
      ] },
      { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => "file5" } }]
    page1 = @product.alive_rich_contents.find_by(position: 0)

    assert_no_difference -> { @product.product_files_archives.folder_archives.alive.count } do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: updated_description } }],
        files: [file2, file3, file4, file5].map { { id: _1.external_id, url: _1.url } }
      }, format: :json
    end
    assert_equal true, folder1_archive.reload.alive?

    new_description = @product.alive_rich_contents.first.description
    assert_equal false, new_description.any? { |node| node.dig("attrs", "id") == file1.external_id }
    assert_equal true, new_description.any? { |node| node.dig("attrs", "id") == file2.external_id }
    assert_equal true, new_description.any? { |node| node.dig("attrs", "id") == file5.external_id }
  end

  test "PUT update generates a folder archive for every valid folder on a page" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    file3 = create_product_file(link: @product, display_name: "File 3")
    file4 = create_product_file(link: @product, display_name: "File 4")
    file5 = create_product_file(link: @product, display_name: "File 5")
    file6 = create_product_file(link: @product, display_name: "File 6")
    @product.product_files = [file1, file2, file3, file4, file5, file6]
    folder1_id = SecureRandom.uuid
    folder2_id = SecureRandom.uuid
    folder3_id = SecureRandom.uuid
    description = [
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
      ] },
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 2", "uid" => folder2_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
      ] },
      { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => folder3_id }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file6.external_id, "uid" => SecureRandom.uuid } },
      ] }]

    assert_difference -> { @product.product_files_archives.folder_archives.alive.count }, 3 do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
        files: [file1, file2, file3, file4, file5, file6].map { { id: _1.external_id, url: _1.url } }
      }, format: :json
    end

    folder1_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)
    folder1_archive.mark_in_progress!
    folder1_archive.mark_ready!
    assert_equal Digest::SHA1.hexdigest(["#{folder1_id}/folder 1/#{file1.external_id}/File 1", "#{folder1_id}/folder 1/#{file2.external_id}/File 2"].sort.join("\n")), folder1_archive.digest
    assert_equal "folder_1.zip", folder1_archive.url.split("/").last

    folder2_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder2_id)
    folder2_archive.mark_in_progress!
    folder2_archive.mark_ready!
    assert_equal Digest::SHA1.hexdigest(["#{folder2_id}/folder 2/#{file3.external_id}/File 3", "#{folder2_id}/folder 2/#{file4.external_id}/File 4"].sort.join("\n")), folder2_archive.digest
    assert_equal "folder_2.zip", folder2_archive.url.split("/").last

    folder3_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder3_id)
    folder3_archive.mark_in_progress!
    folder3_archive.mark_ready!
    assert_equal Digest::SHA1.hexdigest(["#{folder3_id}/Untitled 1/#{file5.external_id}/File 5", "#{folder3_id}/Untitled 1/#{file6.external_id}/File 6"].sort.join("\n")), folder3_archive.digest
    assert_equal "Untitled.zip", folder3_archive.url.split("/").last

    page1 = @product.alive_rich_contents.find_by(position: 0)
    assert_no_difference -> { @product.product_files_archives.folder_archives.count } do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: page1.description } }],
        files: [file1, file2, file3, file4, file5, file6].map { { id: _1.external_id, url: _1.url } }
      }, format: :json
    end

    assert_equal true, [folder1_archive.reload, folder2_archive.reload, folder3_archive.reload].all?(&:alive?)
  end

  test "PUT update generates a folder archive when a folder is added to an existing page" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2]
    folder1_id = SecureRandom.uuid
    folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => folder1_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }

    assert_difference -> { @product.product_files_archives.folder_archives.alive.count }, 1 do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: [folder1] } }],
        files: [file1, file2].map { { id: _1.external_id, url: _1.url } }
      }, format: :json
    end
    archive = @product.product_files_archives.folder_archives.alive.last
    archive.mark_in_progress!
    archive.mark_ready!
    assert_equal Digest::SHA1.hexdigest(["#{folder1_id}/Untitled 1/#{file1.external_id}/File 1", "#{folder1_id}/Untitled 1/#{file2.external_id}/File 2"].sort.join("\n")), archive.digest
    assert_equal "Untitled.zip", archive.url.split("/").last

    folder2_id = SecureRandom.uuid
    page1 = @product.alive_rich_contents.find_by(position: 0)
    file3_id = SecureRandom.uuid
    file4_id = SecureRandom.uuid
    updated_page1_description = [folder1,
                                 { "type" => "fileEmbedGroup", "attrs" => { "name" => "Folder 2", "uid" => folder2_id }, "content" => [
                                   { "type" => "fileEmbed", "attrs" => { "id" => file3_id, "uid" => SecureRandom.uuid } },
                                   { "type" => "fileEmbed", "attrs" => { "id" => file4_id, "uid" => SecureRandom.uuid } },
                                 ] },
    ]
    assert_difference -> { @product.product_files_archives.folder_archives.alive.count }, 1 do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: updated_page1_description } }],
        files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }, { id: file3_id, display_name: "File 3", url: "#{S3_BASE_URL}specs/#{unique_suffix}.pdf" }, { id: file4_id, display_name: "File 4", url: "#{S3_BASE_URL}specs/#{unique_suffix}.pdf" }],
      }, format: :json
    end
    assert_equal false, archive.needs_updating?(@product.product_files)
    assert_equal true, archive.reload.alive?
    assert_equal 2, @product.product_files_archives.folder_archives.alive.count

    new_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.last
    new_archive.mark_in_progress!
    new_archive.mark_ready!

    file3 = @product.product_files.find_by(display_name: "File 3")
    file4 = @product.product_files.find_by(display_name: "File 4")
    assert_equal Digest::SHA1.hexdigest(["#{folder2_id}/Folder 2/#{file3.external_id}/File 3", "#{folder2_id}/Folder 2/#{file4.external_id}/File 4"].sort.join("\n")), new_archive.digest
    assert_equal "Folder_2.zip", new_archive.url.split("/").last
  end

  test "PUT update generates a new folder archive and deletes the old archive for an existing folder that gets modified" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2]
    folder1_id = SecureRandom.uuid
    folder1_name = "folder 1"
    folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => folder1_name, "uid" => folder1_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }
    description = [folder1]

    assert_difference -> { @product.product_files_archives.folder_archives.alive.count }, 1 do
      post :update, params: {
        id: @product.unique_permalink,
        rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
        files: [file1, file2].map { { id: _1.external_id, url: _1.url } }
      }, format: :json
    end

    old_archive = @product.product_files_archives.folder_archives.alive.last
    old_archive.mark_in_progress!
    old_archive.mark_ready!

    assert_equal Digest::SHA1.hexdigest(["#{folder1_id}/#{folder1_name}/#{file1.external_id}/File 1", "#{folder1_id}/#{folder1_name}/#{file2.external_id}/File 2"].sort.join("\n")), old_archive.digest
    assert_equal "folder_1.zip", old_archive.url.split("/").last

    folder1_name = "New folder name"
    folder1["attrs"]["name"] = folder1_name
    page1 = @product.alive_rich_contents.find_by(position: 0)

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: description } }],
      files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
    }, format: :json

    assert_equal false, old_archive.reload.alive?
    assert_equal 1, @product.product_files_archives.folder_archives.alive.count

    new_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.last
    new_archive.mark_in_progress!
    new_archive.mark_ready!

    assert_equal Digest::SHA1.hexdigest(["#{folder1_id}/#{folder1_name}/#{file1.external_id}/File 1", "#{folder1_id}/#{folder1_name}/#{file2.external_id}/File 2"].sort.join("\n")), new_archive.digest
    assert_equal "New_folder_name.zip", new_archive.url.split("/").last
  end

  test "PUT update generates new folder archives when a file is moved from one folder to another folder" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    file3 = create_product_file(link: @product, display_name: "File 3")
    file4 = create_product_file(link: @product, display_name: "File 4")
    file5 = create_product_file(link: @product, display_name: "File 5")
    @product.product_files = [file1, file2, file3, file4, file5]

    folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }
    folder2 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 2", "uid" => SecureRandom.uuid }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
    ] }
    description = [folder1, folder2]

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
      files: [file1, file2, file3, file4, file5].map { { id: _1.external_id, url: _1.url } }
    }, format: :json

    folder1_archive = @product.product_files_archives.create!(folder_id: folder1.dig("attrs", "uid"))
    folder1_archive.product_files = @product.product_files
    folder1_archive.mark_in_progress!
    folder1_archive.mark_ready!

    folder2_archive = @product.product_files_archives.create!(folder_id: folder2.dig("attrs", "uid"))
    folder2_archive.product_files = @product.product_files
    folder2_archive.mark_in_progress!
    folder2_archive.mark_ready!

    new_folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => folder1.dig("attrs", "name"), "uid" => folder1.dig("attrs", "uid") }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
    ] }
    new_folder2 = { "type" => "fileEmbedGroup", "attrs" => { "name" => folder2.dig("attrs", "name"), "uid" => folder2.dig("attrs", "uid") }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
    ] }
    new_description = [new_folder1, new_folder2]
    page1 = @product.alive_rich_contents.find_by(position: 0)

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: new_description } }],
      files: [file1, file2, file3, file4, file5].map { { id: _1.external_id, url: _1.url } },
    }, format: :json

    assert_equal false, folder1_archive.reload.alive?
    assert_equal false, folder2_archive.reload.alive?
    assert_equal 2, @product.product_files_archives.folder_archives.alive.count

    new_folder1_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: new_folder1.dig("attrs", "uid"))
    new_folder1_archive.mark_in_progress!
    new_folder1_archive.mark_ready!

    new_folder2_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: new_folder2.dig("attrs", "uid"))
    new_folder2_archive.mark_in_progress!
    new_folder2_archive.mark_ready!

    assert_equal Digest::SHA1.hexdigest(["#{new_folder1.dig("attrs", "uid")}/#{new_folder1.dig("attrs", "name")}/#{file1.external_id}/File 1", "#{new_folder1.dig("attrs", "uid")}/#{new_folder1.dig("attrs", "name")}/#{file2.external_id}/File 2", "#{new_folder1.dig("attrs", "uid")}/#{new_folder1.dig("attrs", "name")}/#{file3.external_id}/File 3"].sort.join("\n")), new_folder1_archive.digest
    assert_equal Digest::SHA1.hexdigest(["#{new_folder2.dig("attrs", "uid")}/#{new_folder2.dig("attrs", "name")}/#{file4.external_id}/File 4", "#{new_folder2.dig("attrs", "uid")}/#{new_folder2.dig("attrs", "name")}/#{file5.external_id}/File 5"].sort.join("\n")), new_folder2_archive.digest
  end

  test "PUT update deletes the corresponding folder archive when a folder gets deleted" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2]
    folder_id = SecureRandom.uuid
    description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }]

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
      files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
    }, format: :json
    assert_equal 1, @product.product_files_archives.folder_archives.alive.count

    old_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id:)
    old_archive.mark_in_progress!
    old_archive.mark_ready!

    new_description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }]
    page1 = @product.alive_rich_contents.find_by(position: 0)

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: new_description } }],
      files: [],
    }, format: :json

    assert_equal false, old_archive.reload.alive?
    assert_equal 0, @product.product_files_archives.folder_archives.alive.count
  end

  test "PUT update deletes a folder archive if the folder is updated to contain only 1 file" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2]
    folder_id = SecureRandom.uuid
    description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }]

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
      files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
    }, format: :json
    assert_equal 1, @product.product_files_archives.folder_archives.alive.count

    old_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id:)
    old_archive.product_files = @product.product_files
    old_archive.mark_in_progress!
    old_archive.mark_ready!

    new_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }]
    page1 = @product.alive_rich_contents.find_by(position: 0)

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: new_description } }],
      files: [{ id: file1.external_id, url: file1.url }]
    }, format: :json

    assert_equal false, old_archive.reload.alive?
    assert_equal 0, @product.product_files_archives.folder_archives.alive.count
  end

  test "PUT update updates all folder archives when multiple changes occur to a product's rich content across multiple pages" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    file3 = create_product_file(link: @product, display_name: "File 3")
    file4 = create_product_file(link: @product, display_name: "File 4")
    @product.product_files = [file1, file2, file3, file4]

    folder1_id = SecureRandom.uuid
    folder1_name = "folder 1"
    page1_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => folder1_name, "uid" => folder1_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }]

    folder2_id = SecureRandom.uuid
    folder2_name = "SECOND folder"
    page2_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => folder2_name, "uid" => folder2_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
    ] }]

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: page1_description } }, { id: nil, title: "Page 2", description: { type: "doc", content: page2_description } }],
      files: [file1, file2, file3, file4].map { { id: _1.external_id, url: _1.url } },
    }, format: :json

    folder1_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)
    folder1_archive.mark_in_progress!
    folder1_archive.mark_ready!

    folder2_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id: folder2_id)
    folder2_archive.mark_in_progress!
    folder2_archive.mark_ready!

    updated_page1_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => folder1_name, "uid" => folder1_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
    ] }]

    file5 = create_product_file(link: @product, display_name: "File 5")
    @product.product_files << file5
    updated_page2_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => folder2_name, "uid" => folder2_id }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
    ] }]

    updated_page1_description << { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ignore me" }] }
    updated_page2_description << { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "A paragraph" }] }

    page1 = @product.alive_rich_contents.find_by(position: 0)
    page2 = @product.alive_rich_contents.find_by(position: 1)

    post :update, params: {
      id: @product.unique_permalink,
      rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: updated_page1_description } }, { id: page2.external_id, title: page2.title, description: { type: "doc", content: updated_page2_description } }],
      files: [file1, file3, file4, file5].map { { id: _1.external_id, url: _1.url } },
    }, format: :json

    assert_equal false, folder1_archive.reload.alive?
    assert_equal false, folder2_archive.reload.alive?
    assert_equal 1, @product.product_files_archives.folder_archives.alive.count
    assert_nil @product.product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)

    new_folder2_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder2_id)
    new_folder2_archive.mark_in_progress!
    new_folder2_archive.mark_ready!
    assert_equal Digest::SHA1.hexdigest(["#{folder2_id}/#{folder2_name}/#{file3.external_id}/File 3", "#{folder2_id}/#{folder2_name}/#{file4.external_id}/File 4", "#{folder2_id}/#{folder2_name}/#{file5.external_id}/File 5"].sort.join("\n")), new_folder2_archive.digest
  end

  test "PUT update generates folder archives for a new variant when has_same_rich_content_for_all_variants is false" do
    category = create_variant_category(link: @product, title: "Versions")
    version1 = create_variant(variant_category: category, name: "Version 1")

    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2]
    version1.product_files = [file1, file2]
    version1_rich_content_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }]

    assert_difference -> { version1.product_files_archives.folder_archives.alive.count }, 1 do
      assert_no_difference -> { @product.product_files_archives.folder_archives.alive.count } do
        post :update, params: {
          id: @product.unique_permalink,
          has_same_rich_content_for_all_variants: false,
          files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
          variants: [{ id: version1.external_id, name: version1.name, rich_content: [{ id: nil, title: "Version 1 - Page 1", description: { type: "doc", content: version1_rich_content_description } }] }]
        }, format: :json
      end
    end
  end

  test "PUT update generates folder archives for the file embed groups in product-level content when has_same_rich_content_for_all_variants is true" do
    file1 = create_product_file(link: @product, display_name: "File 1")
    file2 = create_product_file(link: @product, display_name: "File 2")
    @product.product_files = [file1, file2]
    variant_category = create_variant_category(title: "versions", link: @product)
    variant = create_variant(variant_category:, name: "mac")
    variant.product_files = [file1, file2]

    folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
      { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
      { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
    ] }

    assert_difference -> { @product.product_files_archives.folder_archives.alive.count }, 1 do
      assert_no_difference -> { variant.product_files_archives.folder_archives.alive.count } do
        post :update, params: {
          id: @product.unique_permalink,
          has_same_rich_content_for_all_variants: true,
          rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: [folder1] } }],
          variants: [{ "id" => variant.external_id, "name" => "linux", "price" => "2" }],
          files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
        }, format: :json
      end
    end
  end

  # --- error handling on save -------------------------------------------------

  test "PUT update logs and renders error message when Link::LinkInvalid is raised" do
    Link.any_instance.stubs(:save!).raises(Link::LinkInvalid)

    post :update, params: @params, as: :json

    assert_response :unprocessable_entity
  end

  # --- installment plans ------------------------------------------------------

  test "PUT update creates a new installment plan when product is eligible and has no existing plans" do
    product = create_product(user: @seller, price_cents: 1000)
    assert_difference -> { ProductInstallmentPlan.alive.count }, 1 do
      post :update, params: { id: product.unique_permalink, installment_plan: { number_of_installments: 3, recurrence: "monthly" } }, as: :json
    end

    plan = product.reload.installment_plan
    assert_equal 3, plan.number_of_installments
    assert_equal "monthly", plan.recurrence
  end

  test "PUT update soft deletes the existing plan and creates a new plan when there are existing payment_options" do
    product = create_product(user: @seller, price_cents: 1000)
    existing_plan = create_product_installment_plan(link: product, number_of_installments: 2, recurrence: "monthly")
    create_payment_option(installment_plan: existing_plan)
    create_installment_plan_purchase(link: product)

    assert_changes -> { existing_plan.reload.deleted_at }, from: nil do
      post :update, params: { id: product.unique_permalink, installment_plan: { number_of_installments: 4, recurrence: "monthly" } }, as: :json
    end

    new_plan = product.reload.installment_plan
    assert_equal 4, new_plan.number_of_installments
    assert_equal "monthly", new_plan.recurrence
    assert_not_equal existing_plan, new_plan

    assert_no_changes -> { new_plan.reload.deleted_at } do
      post :update, params: { id: product.unique_permalink, installment_plan: { number_of_installments: 4, recurrence: "monthly" } }, as: :json
    end
    assert_equal new_plan, product.reload.installment_plan
  end

  test "PUT update destroys the existing plan and creates a new plan when there are no existing payment_options" do
    product = create_product(user: @seller, price_cents: 1000)
    existing_plan = create_product_installment_plan(link: product, number_of_installments: 2, recurrence: "monthly")

    assert_no_difference -> { ProductInstallmentPlan.count } do
      post :update, params: { id: product.unique_permalink, installment_plan: { number_of_installments: 4, recurrence: "monthly" } }, as: :json
    end

    assert_raises(ActiveRecord::RecordNotFound) { existing_plan.reload }
    new_plan = product.reload.installment_plan
    assert_equal 4, new_plan.number_of_installments
    assert_equal "monthly", new_plan.recurrence

    assert_no_changes -> { new_plan.reload.deleted_at } do
      post :update, params: { id: product.unique_permalink, installment_plan: { number_of_installments: 4, recurrence: "monthly" } }, as: :json
    end
    assert_equal new_plan, product.reload.installment_plan
  end

  test "PUT update soft deletes the existing plan even if product is no longer eligible for installment plans" do
    product = create_product(user: @seller, price_cents: 1000)
    existing_plan = create_product_installment_plan(link: product, number_of_installments: 2, recurrence: "monthly")
    create_payment_option(installment_plan: existing_plan)
    create_installment_plan_purchase(link: product)

    assert_changes -> { existing_plan.reload.deleted_at }, from: nil do
      post :update, params: { id: product.unique_permalink, price_cents: 0, installment_plan: nil }, as: :json
    end

    assert_nil product.reload.installment_plan
  end

  test "PUT update destroys the existing plan when removing it and there are no existing payment_options" do
    product = create_product(user: @seller, price_cents: 1000)
    existing_plan = create_product_installment_plan(link: product, number_of_installments: 2, recurrence: "monthly")

    assert_difference -> { ProductInstallmentPlan.count }, -1 do
      post :update, params: { id: product.unique_permalink, installment_plan: nil }, as: :json
    end

    assert_raises(ActiveRecord::RecordNotFound) { existing_plan.reload }
    assert_nil product.reload.installment_plan
  end

  test "PUT update does not create an installment plan when product is not eligible" do
    membership_product = create_membership_product(user: @seller)
    assert_no_difference -> { ProductInstallmentPlan.count } do
      post :update, params: { id: membership_product.unique_permalink, installment_plan: { number_of_installments: 3, recurrence: "monthly" } }, as: :json
    end
  end

  # --- community chat ---------------------------------------------------------

  test "PUT update enables community chat when requested" do
    post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json

    assert_response :success
    assert_equal true, @product.reload.community_chat_enabled?
    assert @product.reload.active_community.present?
  end

  test "PUT update disables community chat when requested" do
    @product.update!(community_chat_enabled: true)

    post :update, params: { id: @product.unique_permalink, community_chat_enabled: false }, as: :json

    assert_response :success
    assert_equal false, @product.reload.community_chat_enabled?
    assert_nil @product.reload.active_community
  end

  test "PUT update does not enable community chat for coffee products" do
    @seller.update!(created_at: (User::MIN_AGE_FOR_SERVICE_PRODUCTS + 1.day).ago)
    product = create_product(user: @seller, native_type: Link::NATIVE_TYPE_COFFEE, price_cents: 1000)

    # Address the auto-created suggested amount by id, like the editor does.
    post :update, params: { id: product.unique_permalink, community_chat_enabled: true, variants: [{ id: product.alive_variants.first.external_id, price_difference_cents: 1000 }] }, as: :json
    assert_response :success
    assert_equal false, product.reload.community_chat_enabled?
    assert_nil product.reload.active_community
  end

  test "PUT update does not enable community chat for bundle products" do
    @product.update!(native_type: Link::NATIVE_TYPE_BUNDLE)

    post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json
    assert_response :success
    assert_equal false, @product.reload.community_chat_enabled?
    assert_nil @product.reload.active_community
  end

  test "PUT update reactivates existing community when enabling chat" do
    community = create_community(resource: @product, seller: @seller)
    community.mark_deleted!
    @product.update!(community_chat_enabled: false)

    post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json

    assert_response :success
    assert_equal true, @product.reload.community_chat_enabled?
    assert community.reload.alive?
  end
end

class LinksControllerShowTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers

  # The consumer-area "GET show" block reassigns @user to an eligible service
  # seller and pins the request host to that seller's subdomain, so a product
  # created for @user resolves by subdomain instead of 404ing.
  setup do
    @user = create_eligible_seller
    @request.host = URI.parse(@user.subdomain_with_protocol).host
    # The controller builds og:image blob URLs while rendering the product page;
    # ActiveStorage::Current is a per-request CurrentAttribute reset inside the
    # request's executor, so the value set in the global setup doesn't survive.
    # Stubbing the reader keeps url generation working across the request.
    ActiveStorage::Current.stubs(:url_options).returns(protocol: "https", host: "localhost", port: nil)
  end

  def product
    @product_memo ||= create_product(user: @user)
  end

  test "GET show 404s when link isn't found" do
    assert_raises(ActionController::RoutingError) { get :show, params: { id: "NOT real" } }
  end

  ["preview_url", "description"].each do |attribute|
    test "GET show renders when no #{attribute}" do
      Rails.cache.clear
      link = create_product(user: @user, attribute => nil)
      get :show, params: { id: link.to_param }
      assert_response :success
    end
  end

  # --- layout variants --------------------------------------------------------

  test "GET show renders Products/Show with product props for default layout" do
    link = create_product(user: @user)
    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: link.to_param }
    assert_response :success
    page = inertia_page
    assert_equal "Products/Show", page["component"]
    assert page["props"]["product"].present?
    assert_equal link.name, page["props"]["product"]["name"]
  end

  test "GET show renders Products/Profile/Show with creator_profile for profile layout" do
    link = create_product(user: @user)
    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: link.to_param, layout: "profile" }
    assert_response :success
    page = inertia_page
    assert_equal "Products/Profile/Show", page["component"]
    assert page["props"]["creator_profile"].present?
    assert page["props"]["product"].present?
  end

  test "GET show renders Products/Profile/Show when the seller has the product page storefront enabled" do
    seller = create_user(product_page_storefront_enabled: true)
    link = create_product(user: seller)
    @request.host = URI.parse(seller.subdomain_with_protocol).host
    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: link.to_param }
    assert_response :success
    page = inertia_page
    assert_equal "Products/Profile/Show", page["component"]
    assert page["props"]["creator_profile"].present?
    assert page["props"]["product"].present?
  end

  test "GET show keeps the standalone page when the seller turned the product page storefront off" do
    seller = create_user(product_page_storefront_enabled: false)
    link = create_product(user: seller)
    @request.host = URI.parse(seller.subdomain_with_protocol).host
    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: link.to_param }
    assert_response :success
    assert_equal "Products/Show", inertia_page["component"]
  end

  test "GET show keeps the standalone page for the storefront-enabled seller's own view" do
    seller = create_user(product_page_storefront_enabled: true)
    link = create_product(user: seller)
    sign_in seller
    @request.host = URI.parse(seller.subdomain_with_protocol).host
    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: link.to_param }
    assert_response :success
    assert_equal "Products/Show", inertia_page["component"]
  end

  test "GET show renders Products/Discover/Show with taxonomy props for discover layout" do
    link = create_product(user: @user)
    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: link.to_param, layout: "discover" }
    assert_response :success
    page = inertia_page
    assert_equal "Products/Discover/Show", page["component"]
    assert page["props"].key?("taxonomy_path")
    assert page["props"].key?("taxonomies_for_nav")
    assert page["props"]["product"].present?
  end

  test "GET show renders Products/Iframe/Show with product props for embed param" do
    link = create_product(user: @user)
    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: link.to_param, embed: "true" }
    assert_response :success
    page = inertia_page
    assert_equal "Products/Iframe/Show", page["component"]
    assert page["props"]["product"].present?
  end

  test "GET show renders Products/Iframe/Show with product props for overlay param" do
    link = create_product(user: @user)
    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: link.to_param, overlay: "true" }
    assert_response :success
    page = inertia_page
    assert_equal "Products/Iframe/Show", page["component"]
    assert page["props"]["product"].present?
  end

  # --- json format ------------------------------------------------------------

  test "GET show returns the public product JSON representation" do
    link = create_product(user: @user, name: "Public API Product", price_cents: 600)

    get :show, params: { id: link.to_param }, format: :json

    assert_response :success
    body = response.parsed_body
    assert_equal ProductPresenter::PublicApiProps::API_VERSION, body["api_version"]
    assert_equal link.external_id, body["id"]
    assert_equal link.unique_permalink, body["permalink"]
    assert_equal "Public API Product", body["name"]
    assert_equal 600, body["price_cents"]
    assert_equal "usd", body["currency_code"]
    assert_equal @user.name_or_username, body["seller"]["name"]
  end

  test "GET show does not leak buyer, admin, or analytics fields" do
    link = create_product(user: @user)

    get :show, params: { id: link.to_param }, format: :json

    body = response.parsed_body
    %w[purchase buyer wishlists can_edit analytics has_third_party_analytics is_compliance_blocked admin_info].each do |forbidden|
      assert_not body.key?(forbidden)
    end
  end

  test "GET show omits sales_count unless the creator opts in" do
    link = create_product(user: @user, should_show_sales_count: false)

    get :show, params: { id: link.to_param }, format: :json

    assert_nil response.parsed_body["sales_count"]
  end

  test "GET show returns JSON (not the custom-HTML landing page) for products with custom HTML" do
    link = create_product(user: @user, name: "Custom HTML Product")
    link.update!(custom_html: "<h1>My custom landing page</h1>")
    Feature.activate_user(:custom_html_pages, @user)

    get :show, params: { id: link.to_param }, format: :json

    assert_response :success
    assert_equal "application/json", response.media_type
    body = response.parsed_body
    assert_equal ProductPresenter::PublicApiProps::API_VERSION, body["api_version"]
    assert_equal link.external_id, body["id"]
    assert_not_includes response.body, "My custom landing page"
  end

  # --- wanted=true parameter --------------------------------------------------

  test "GET show passes pay_in_installments parameter to checkout when wanted=true" do
    get :show, params: { id: product.to_param, wanted: "true", pay_in_installments: "true" }

    assert_response :redirect
    redirect_url = URI.parse(response.location)
    assert_equal "/checkout", redirect_url.path

    query_params = Rack::Utils.parse_query(redirect_url.query)
    assert_equal product.unique_permalink, query_params["product"]
    assert_equal product.price_cents.to_s, query_params["price"]
    assert_equal "true", query_params["pay_in_installments"]
  end

  test "GET show doesn't redirect to checkout for PWYW products without price" do
    pwyw_product = create_product(user: @user, customizable_price: true, price_cents: 1000)

    get :show, params: { id: pwyw_product.to_param, wanted: "true" }

    assert_response :success
    assert_not response.redirect?
  end

  test "GET show uses the URL code in checkout redirect when URL code has better discount than default code" do
    product.update!(default_offer_code: create_offer_code(products: [product], code: "DEFAULT10", amount_cents: 200, currency_type: product.price_currency_type))
    url_offer_code = create_offer_code(products: [product], code: "URL10", amount_cents: 400, currency_type: product.price_currency_type)

    get :show, params: { id: product.to_param, wanted: "true", code: url_offer_code.code }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal url_offer_code.code, query_params["code"]
  end

  test "GET show uses the default code in checkout redirect when default code has better discount than URL code" do
    default_offer_code = create_offer_code(products: [product], code: "DEFAULT10", amount_cents: 400, currency_type: product.price_currency_type)
    product.update!(default_offer_code:)
    url_offer_code = create_offer_code(products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type)

    get :show, params: { id: product.to_param, wanted: "true", code: url_offer_code.code }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal default_offer_code.code, query_params["code"]
  end

  test "GET show uses the URL code in checkout redirect when only URL code is provided" do
    product.update!(default_offer_code: nil)
    url_offer_code = create_offer_code(products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type)

    get :show, params: { id: product.to_param, wanted: "true", code: url_offer_code.code }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal url_offer_code.code, query_params["code"]
  end

  test "GET show uses the default code in checkout redirect when only default code is provided" do
    default_offer_code = create_offer_code(products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type)
    product.update!(default_offer_code:)

    get :show, params: { id: product.to_param, wanted: "true" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal default_offer_code.code, query_params["code"]
  end

  test "GET show uses the default code in checkout redirect when URL code is invalid and default code is valid" do
    default_offer_code = create_offer_code(products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type)
    product.update!(default_offer_code:)

    get :show, params: { id: product.to_param, wanted: "true", code: "INVALID" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal default_offer_code.code, query_params["code"]
  end

  test "GET show does not include code in checkout redirect when both codes are invalid" do
    product.update!(default_offer_code: nil)

    get :show, params: { id: product.to_param, wanted: "true", code: "INVALID" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_nil query_params["code"]
  end

  test "GET show picks up offer_code and uses the better of URL code and default in checkout redirect" do
    default_offer_code = create_offer_code(products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type)
    product.update!(default_offer_code:)
    url_offer_code = create_offer_code(products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type)

    get :show, params: { id: product.to_param, wanted: "true", offer_code: url_offer_code.code }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    # Default (300) is better than URL code (200), so redirect uses default
    assert_equal default_offer_code.code, query_params["code"]
  end

  test "GET show includes code exactly once in redirect query string when code param is passed" do
    product.update!(default_offer_code: create_offer_code(products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type))
    url_offer_code = create_offer_code(products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type)

    get :show, params: { id: product.to_param, wanted: "true", code: url_offer_code.code }

    assert_response :redirect
    query_string = URI.parse(response.location).query
    code_param_count = query_string.split("&").count { |param| param.start_with?("code=") }
    assert_equal 1, code_param_count, "Expected code to appear exactly once in query string, got: #{query_string}"
  end

  test "GET show includes code exactly once in redirect query string when offer_code param is passed" do
    product.update!(default_offer_code: create_offer_code(products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type))
    url_offer_code = create_offer_code(products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type)

    get :show, params: { id: product.to_param, wanted: "true", offer_code: url_offer_code.code }

    assert_response :redirect
    query_string = URI.parse(response.location).query
    code_param_count = query_string.split("&").count { |param| param.start_with?("code=") }
    assert_equal 1, code_param_count, "Expected code to appear exactly once in query string, got: #{query_string}"
  end

  # --- buyer-input round trip -------------------------------------------------

  test "GET show resolves a variant name to its option id in the checkout redirect" do
    product = create_product_with_digital_versions_with_price_difference_cents(user: @user)
    variant = product.alive_variants.find_by(name: "Untitled 2")

    get :show, params: { id: product.to_param, wanted: "true", variant: "Untitled 2" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal product.unique_permalink, query_params["product"]
    assert_equal variant.external_id, query_params["option"]
    assert_equal "300", query_params["price"]
  end

  test "GET show passes a quantity prefill straight through to checkout" do
    product = create_product(user: @user, quantity_enabled: true, price_cents: 100)

    get :show, params: { id: product.to_param, wanted: "true", quantity: "3" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal "3", query_params["quantity"]
  end

  test "GET show honors a PWYW price prefill at or above the minimum" do
    product = create_product(user: @user, customizable_price: true, price_cents: 100)

    get :show, params: { id: product.to_param, wanted: "true", price: "19.99" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal ["1999"], Array(query_params["price"]).uniq
  end

  test "GET show preserves whole-unit PWYW prefills for a single-unit currency" do
    product = create_product(user: @user, customizable_price: true, price_cents: 100, price_currency_type: "jpy")

    get :show, params: { id: product.to_param, wanted: "true", price: "199" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal ["199"], Array(query_params["price"]).uniq
  end

  test "GET show rounds PWYW prefills to the product currency precision" do
    product = create_product(user: @user, customizable_price: true, price_cents: 100)

    get :show, params: { id: product.to_param, wanted: "true", price: "19.995" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal ["2000"], Array(query_params["price"]).uniq

    jpy_product = create_product(user: @user, customizable_price: true, price_cents: 100, price_currency_type: "jpy")
    get :show, params: { id: jpy_product.to_param, wanted: "true", price: "199.5" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal ["200"], Array(query_params["price"]).uniq
  end

  test "GET show safely rejects non-decimal and out-of-range PWYW prefills" do
    product = create_product(user: @user, customizable_price: true, price_cents: 0)

    ["not-a-price", "Infinity", "NaN", "1e1000000", "9" * 65, "-0.001", "-1"].each do |price|
      get :show, params: { id: product.to_param, wanted: "true", price: }

      assert_response :success, "Expected #{price.inspect} to render the product page"
    end

    get :show, params: { id: product.to_param, wanted: "true", price: "0" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal ["0"], Array(query_params["price"]).uniq
  end

  test "GET show accepts the maximum PWYW prefill and rejects the next currency unit" do
    product = create_product(user: @user, customizable_price: true, price_cents: 100)

    get :show, params: { id: product.to_param, wanted: "true", price: "21474836.47" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal [BasePrice::Shared::MAX_PRICE_CENTS.to_s], Array(query_params["price"]).uniq

    get :show, params: { id: product.to_param, wanted: "true", price: "21474836.48" }
    assert_response :success

    jpy_product = create_product(user: @user, customizable_price: true, price_cents: 100, price_currency_type: "jpy")
    get :show, params: { id: jpy_product.to_param, wanted: "true", price: "2147483647" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal [BasePrice::Shared::MAX_PRICE_CENTS.to_s], Array(query_params["price"]).uniq

    get :show, params: { id: jpy_product.to_param, wanted: "true", price: "2147483648" }
    assert_response :success
  end

  test "GET show resolves a recurrence prefill on a membership product" do
    product = create_membership_product_with_preset_tiered_pricing(user: @user)
    variant = product.alive_variants.first

    get :show, params: { id: product.to_param, wanted: "true", option: variant.external_id, recurrence: "monthly" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert(Array(query_params["recurrence"]).all? { |value| value == "monthly" })
    assert_equal variant.external_id, query_params["option"]
  end

  test "GET show redirects to a valid checkout when no selection is prefilled" do
    product = create_product_with_digital_versions_with_price_difference_cents(user: @user)

    get :show, params: { id: product.to_param, wanted: "true" }

    assert_response :redirect
    redirect_url = URI.parse(response.location)
    assert_equal "/checkout", redirect_url.path
    query_params = Rack::Utils.parse_query(redirect_url.query)
    assert_equal product.unique_permalink, query_params["product"]
  end

  test "GET show fills the unspecified keys with defaults when only a partial selection is prefilled" do
    product = create_product_with_digital_versions_with_price_difference_cents(user: @user, quantity_enabled: true)
    variant = product.alive_variants.find_by(name: "Untitled 1")

    get :show, params: { id: product.to_param, wanted: "true", variant: "Untitled 1" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal variant.external_id, query_params["option"]
    assert_nil query_params["quantity"]
    assert(Array(query_params["price"]).all? { |value| value == "200" })
  end

  test "GET show does not resolve an unknown variant name but still redirects to a valid checkout" do
    product = create_product_with_digital_versions_with_price_difference_cents(user: @user)

    get :show, params: { id: product.to_param, wanted: "true", variant: "Does Not Exist" }

    assert_response :redirect
    redirect_url = URI.parse(response.location)
    assert_equal "/checkout", redirect_url.path
    query_params = Rack::Utils.parse_query(redirect_url.query)
    assert_equal product.unique_permalink, query_params["product"]
    assert_nil query_params["option"]
  end

  # --- with user signed in ----------------------------------------------------

  test "GET show assigns the correct props with user signed in" do
    visitor = create_user
    purchase = create_purchase(purchaser: visitor, link: product)
    sign_in(visitor)

    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: product.to_param }

    assert_response :success
    page = inertia_page
    assert_equal product.external_id, page["props"]["product"]["id"]
    assert_equal purchase.external_id, page["props"]["purchase"]["id"]
  end

  # --- logged-out buyer arriving from a review reminder email -----------------

  test "GET show recognizes the purchase when the purchase id and email digest match" do
    purchase = create_purchase(link: product)

    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: product.to_param, purchase_id: purchase.external_id, purchase_email_digest: purchase.email_digest }

    assert_response :success
    assert_equal purchase.external_id, inertia_page["props"]["purchase"]["id"]
  end

  test "GET show ignores the purchase when the email digest doesn't match" do
    purchase = create_purchase(link: product)

    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: product.to_param, purchase_id: purchase.external_id, purchase_email_digest: "wrong-digest" }

    assert_response :success
    assert_nil inertia_page["props"]["purchase"]
  end

  test "GET show ignores the purchase when the email digest is missing" do
    purchase = create_purchase(link: product)

    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: product.to_param, purchase_id: purchase.external_id }

    assert_response :success
    assert_nil inertia_page["props"]["purchase"]
  end

  test "GET show recognizes a review-eligible not_charged free trial purchase" do
    trial_product = create_membership_product(user: @user, free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
    trial_purchase = create_free_trial_membership_purchase(link: trial_product)
    trial_purchase.update!(should_exclude_product_review: false)
    assert_equal true, trial_purchase.allows_review_to_be_counted?

    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: trial_purchase.link.to_param, purchase_id: trial_purchase.external_id, purchase_email_digest: trial_purchase.email_digest }

    assert_response :success
    assert_equal trial_purchase.external_id, inertia_page["props"]["purchase"]["id"]
  end

  test "GET show ignores an unconverted free trial purchase that can't yet leave a review" do
    trial_product = create_membership_product(user: @user, free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
    trial_purchase = create_free_trial_membership_purchase(link: trial_product)
    assert_equal false, trial_purchase.allows_review_to_be_counted?

    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: trial_purchase.link.to_param, purchase_id: trial_purchase.external_id, purchase_email_digest: trial_purchase.email_digest }

    assert_response :success
    assert_nil inertia_page["props"]["purchase"]
  end

  test "GET show ignores a gift-sender purchase even with a matching email digest" do
    gift = create_gift(link: product)
    gifter_purchase = create_purchase(link: product, is_gift_sender_purchase: true, gift_given: gift)
    create_purchase(link: product, is_gift_receiver_purchase: true, gift_received: gift, purchase_state: "gift_receiver_purchase_successful")

    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: product.to_param, purchase_id: gifter_purchase.external_id, purchase_email_digest: gifter_purchase.email_digest }

    assert_response :success
    assert_nil inertia_page["props"]["purchase"]
  end

  # --- meta tags sanitization -------------------------------------------------

  test "GET show properly escapes double quote in meta content" do
    link = create_product(user: @user, description: 'I like pie."')
    get :show, params: { id: link.to_param }
    assert_response :success

    html_doc = Nokogiri::HTML(response.body)
    assert_not html_doc.css("meta[name='description'][content='I like pie.\"']").empty?
  end

  test "GET show scrubs tags in meta content" do
    link = create_product(user: @user, description: "I like pie.&nbsp; <br/>")
    get :show, params: { id: link.to_param }
    assert_response :success

    html_doc = Nokogiri::HTML(response.body)
    assert_not html_doc.css("meta[name='description'][content='I like pie.']").empty?
  end

  test "GET show escapes new lines and html tags in meta content" do
    link = create_product(user: @user, description: "I like pie.\n\r This is not <br/> what we had estimated! ~")
    get :show, params: { id: link.to_param }
    assert_response :success

    html_doc = Nokogiri::HTML(response.body)
    assert_not html_doc.css("meta[name='description'][content='I like pie. This is not what we had estimated! ~']").empty?
  end

  # --- asset previews ---------------------------------------------------------

  test "GET show includes asset preview data in Inertia props" do
    asset_product = create_product_with_file_and_preview(user: @user)
    @request.headers["X-Inertia"] = "true"
    get(:show, params: { id: asset_product.to_param })

    assert_response :success
    page = inertia_page
    assert_equal "Products/Show", page["component"]
    assert page["props"]["product"].present?
  end

  test "GET show redirects from unique_permalink to custom_permalink URL preserving the original query parameter string" do
    custom_product = create_product(user: @user, custom_permalink: "custom")
    get :show, params: { id: custom_product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

    assert_redirected_to short_link_url(custom_product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: custom_product.user.subdomain_with_protocol)
  end

  # --- redirection to creator's subdomain -------------------------------------

  test "GET show redirects to the subdomain product URL with original query params when custom permalink is not present" do
    @request.host = DOMAIN
    product = create_product
    get :show, params: { id: product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

    assert_redirected_to short_link_url(product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol)
    assert_response :moved_permanently
  end

  test "GET show redirects to the subdomain product URL using custom permalink with original query params (unique lookup)" do
    @request.host = DOMAIN
    product = create_product(custom_permalink: "abcd")
    get :show, params: { id: product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

    assert_redirected_to short_link_url(product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol)
    assert_response :moved_permanently
  end

  test "GET show redirects to subdomain product URL with offer code and original query params (unique lookup)" do
    @request.host = DOMAIN
    product = create_product
    get :show, params: { id: product.unique_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

    assert_redirected_to short_link_offer_code_url(product.unique_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol)
    assert_response :moved_permanently
  end

  test "GET show redirects to the subdomain product URL using custom permalink with original query params (custom lookup)" do
    @request.host = DOMAIN
    product = create_product(custom_permalink: "abcd")
    get :show, params: { id: product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

    assert_redirected_to short_link_url(product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol)
    assert_response :moved_permanently
  end

  test "GET show redirects to subdomain product URL with offer code and original query params (custom lookup)" do
    @request.host = DOMAIN
    product = create_product(custom_permalink: "abcd")
    get :show, params: { id: product.custom_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

    assert_redirected_to short_link_offer_code_url(product.custom_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol)
    assert_response :moved_permanently
  end

  test "GET show returns 404 when the product is deleted" do
    deleted_product = create_product(user: @user, deleted_at: 2.days.ago)
    assert_raises(ActionController::RoutingError) do
      get :show, params: { id: deleted_product.to_param }
    end
  end

  test "GET show redirects to the coffee page when the product is a coffee product" do
    coffee = create_product(user: @user, native_type: Link::NATIVE_TYPE_COFFEE)
    get :show, params: { id: coffee.to_param }
    assert_redirected_to custom_domain_coffee_url
  end

  test "GET show responds with 404 when the user is deleted" do
    deleted_user = create_user(deleted_at: 2.days.ago)
    deleted_user_product = create_product(custom_permalink: "moohat", user: deleted_user)
    assert_raises(ActionController::RoutingError) do
      get :show, params: { id: deleted_user_product.to_param }
    end
  end

  test "GET show does not 404 if user is not suspended" do
    link = create_product(user: @user)
    get :show, params: { id: link.to_param }
    assert_response :success
  end

  test "GET show 404s on an unsupported format" do
    link = create_product(user: @user)
    assert_raises(ActionController::RoutingError) do
      get(:show, params: { id: link.to_param, format: :php })
    end
  end

  # --- canonical urls ---------------------------------------------------------

  test "GET show renders the canonical meta tag" do
    product = create_product(user: @user)
    get :show, params: { id: product.unique_permalink }
    assert_select "link[rel='canonical'][href='#{product.long_url}']", visible: false, count: 1
  end

  # --- product information markup ---------------------------------------------

  test "GET show sets server-side meta tags for classic product" do
    product = create_product(user: @user, price_currency_type: "usd", price_cents: 525)
    create_asset_preview(link: product, unsplash_url: "https://images.unsplash.com/example.jpeg", attach: false)

    get :show, params: { id: product.unique_permalink }

    assert_response :success
    html_doc = Nokogiri::HTML(response.body)
    assert html_doc.css("meta[content='#{product.long_url}'][property='og:url']").present?
    assert html_doc.css("meta[property='product:retailer_item_id'][content='#{product.unique_permalink}']").present?
    assert html_doc.css("meta[property='product:price:amount'][content='5.25']").present?
    assert html_doc.css("meta[property='product:price:currency'][content='USD']").present?
    assert html_doc.css("meta[content='#{product.preview_url}'][property='og:image']").present?
    assert html_doc.css("link[rel='canonical'][href='#{product.long_url}']").present?
  end

  test "GET show renders Open Graph / Twitter meta tags with the content attribute (not value)" do
    product = create_product(user: @user, name: "My OG Product")

    get :show, params: { id: product.unique_permalink }

    assert_response :success
    html_doc = Nokogiri::HTML(response.body)

    assert html_doc.css("meta[property='og:title'][content='#{product.name}']").present?
    assert html_doc.css("meta[property='og:description']").map { |tag| tag["content"] }.compact.present?
    assert html_doc.css("meta[property='twitter:title'][content='#{product.name}']").present?

    value_keyed = html_doc.css("meta[property^='og:'], meta[property^='twitter:'], meta[property^='fb:'], meta[property^='gr:']")
      .filter_map { |tag| tag["property"] if tag["value"].present? }
    assert value_keyed.empty?, "These meta tags still render value= instead of content=: #{value_keyed.inspect}"

    assert html_doc.css("meta[property='stripe:pk']").first&.[]("value").present?
    assert_nil html_doc.css("meta[property='stripe:pk']").first&.[]("content")
    assert html_doc.css("meta[property='stripe:api_version']").first&.[]("value").present?
  end

  test "GET show sets server-side meta tags for product over $1000" do
    product = create_product(user: @user, price_cents: 1_000_00)

    get :show, params: { id: product.unique_permalink }

    assert_response :success
    html_doc = Nokogiri::HTML(response.body)
    assert_not html_doc.css("meta[property='product:retailer_item_id'][content='#{product.unique_permalink}']").empty?
    assert_not html_doc.css("meta[content='#{product.long_url}'][property='og:url']").empty?
    assert_not html_doc.css("meta[property='product:price:amount'][content='1000.0']").empty?
    assert_not html_doc.css("meta[property='product:price:currency'][content='USD']").empty?
  end

  test "GET show renders the page without price meta tags when the product has no live price" do
    product = create_product(user: @user)
    product.prices.alive.each(&:mark_deleted!)
    assert_nil product.reload.price_cents

    get :show, params: { id: product.unique_permalink }

    assert_response :success
    html_doc = Nokogiri::HTML(response.body)
    assert html_doc.css("meta[property='product:price:amount']").empty?
    assert html_doc.css("meta[property='product:price:currency']").empty?
    assert html_doc.css("meta[property='product:retailer_item_id'][content='#{product.unique_permalink}']").present?
  end

  test "GET show keeps the price meta tags for a free (zero-priced) product" do
    product = create_product(user: @user, price_cents: 0)

    get :show, params: { id: product.unique_permalink }

    assert_response :success
    html_doc = Nokogiri::HTML(response.body)
    assert_not html_doc.css("meta[property='product:price:amount'][content='0.0']").empty?
    assert_not html_doc.css("meta[property='product:price:currency'][content='USD']").empty?
  end

  test "GET show emits product:price:amount in major units for a zero-decimal currency" do
    product = create_product(user: @user, price_currency_type: "jpy", price_cents: 14_800)

    get :show, params: { id: product.unique_permalink }

    assert_response :success
    html_doc = Nokogiri::HTML(response.body)
    assert_not html_doc.css("meta[property='product:price:amount'][content='14800.0']").empty?
    assert_not html_doc.css("meta[property='product:price:currency'][content='JPY']").empty?
  end

  test "GET show sets canonical and og:url meta tags for product without reviews" do
    product = create_product(user: @user)
    get :show, params: { id: product.unique_permalink }

    assert_response :success
    html_doc = Nokogiri::HTML(response.body)
    assert_not html_doc.css("meta[content='#{product.long_url}'][property='og:url']").empty?
    assert_not html_doc.css("link[rel='canonical'][href='#{product.long_url}']").empty?
  end

  test "GET show sets server-side meta tags for membership product" do
    product = create_membership_product(user: @user)
    get :show, params: { id: product.unique_permalink }

    assert_response :success
    html_doc = Nokogiri::HTML(response.body)
    assert html_doc.css("meta[property='product:retailer_item_id'][content='#{product.unique_permalink}']").present?
    assert html_doc.css("meta[content='#{product.long_url}'][property='og:url']").present?
    assert html_doc.css("link[rel='canonical'][href='#{product.long_url}']").present?
  end

  test "GET show includes product data in Inertia props" do
    product = create_product(user: @user, price_currency_type: "usd", price_cents: 525)
    @request.headers["X-Inertia"] = "true"
    get :show, params: { id: product.unique_permalink }

    assert_response :success
    page = inertia_page
    assert page["props"]["product"].present?
    assert_equal product.name, page["props"]["product"]["name"]
  end

  test "GET show renders seller custom_styles in the head as a style tag" do
    @user.seller_profile.update!(highlight_color: "#00ff00", background_color: "#0000ff")
    product = create_product(user: @user)

    get :show, params: { id: product.unique_permalink }

    assert_response :success
    html_doc = Nokogiri::HTML(response.body)
    style_tags = html_doc.css("head style")
    assert(style_tags.any? { |tag| tag.text.include?("--accent:") && tag.text.include?("background-color:") })
  end

  test "GET show does not set no index header by default" do
    product = create_product(user: @user)
    get :show, params: { id: product.unique_permalink }
    assert_nil response.headers["X-Robots-Tag"]
  end

  test "GET show does not set the noindex header for adult products" do
    product = create_product(user: @user, is_adult: true)

    get :show, params: { id: product.unique_permalink }

    assert_not_includes response.headers.keys, "X-Robots-Tag"
  end

  test "GET show sets the noindex header for non-alive products" do
    product = create_product(user: @user)
    Link.any_instance.expects(:alive?).at_least_once.returns(false)

    get :show, params: { id: product.unique_permalink }

    assert_equal "noindex", response.headers["X-Robots-Tag"]
  end

  test "GET show sets paypal_merchant_currency as merchant account's currency if native paypal payments are enabled else as usd" do
    product = create_product(user: @user)

    get :show, params: { id: product.unique_permalink }
    assert_equal "USD", assigns[:paypal_merchant_currency]

    create_merchant_account_paypal(user: product.user, currency: "GBP")
    get :show, params: { id: product.unique_permalink }
    assert_equal "GBP", assigns[:paypal_merchant_currency]
  end

  # --- custom domains ---------------------------------------------------------

  test "GET show assigns the product and renders the Inertia page when the custom domain matches a product's custom domain" do
    product = create_product
    create_custom_domain(domain: "www.example1.com", user: nil, product:)
    @request.host = "www.example1.com"

    @request.headers["X-Inertia"] = "true"
    get :show
    assert_response :success
    assert_equal product, assigns[:product]
    assert_equal "Products/Show", inertia_page["component"]
  end

  test "GET show raises RoutingError when the custom domain matches a deleted product" do
    product = create_product
    create_custom_domain(domain: "www.example1.com", user: nil, product:)
    @request.host = "www.example1.com"
    product.mark_deleted!

    assert_raises(ActionController::RoutingError) { get :show }
  end

  test "GET show assigns the product when the same domain name is used for a deleted user custom domain and an active product custom domain" do
    product = create_product
    custom_domain = create_custom_domain(domain: "www.example1.com", user: nil, product:)
    @request.host = "www.example1.com"
    custom_domain.update!(product: nil, user: create_user, deleted_at: DateTime.parse("2020-01-01"))
    create_custom_domain(domain: "www.example1.com", user: nil, product:)

    @request.headers["X-Inertia"] = "true"
    get :show
    assert_response :success
    assert_equal product, assigns[:product]
    assert_equal "Products/Show", inertia_page["component"]
  end

  test "GET show raises RoutingError when a product's custom domain is deleted" do
    product = create_product
    custom_domain = create_custom_domain(domain: "www.example1.com", user: nil, product:)
    @request.host = "www.example1.com"
    custom_domain.mark_deleted!

    assert_raises(ActionController::RoutingError) { get :show }
  end

  test "GET show assigns the product when a product's saved custom domain does not use the www prefix" do
    product = create_product
    custom_domain = create_custom_domain(domain: "www.example1.com", user: nil, product:)
    @request.host = "www.example1.com"
    custom_domain.update!(domain: "example1.com")

    @request.headers["X-Inertia"] = "true"
    get :show
    assert_response :success
    assert_equal product, assigns[:product]
    assert_equal "Products/Show", inertia_page["component"]
  end

  # --- subdomains -------------------------------------------------------------

  test "GET show assigns the product and renders the Inertia page when the subdomain and unique permalink are valid and present" do
    with_const(:ROOT_DOMAIN, "test.gumroad.com") do
      user = create_user(username: "testuser")
      @request.host = "#{user.username}.test.gumroad.com"
      product = create_product(user:)

      @request.headers["X-Inertia"] = "true"
      get :show, params: { id: product.unique_permalink }
      assert_response :success
      assert_equal product, assigns[:product]
      assert_equal "Products/Show", inertia_page["component"]
    end
  end

  test "GET show redirects unique permalink to custom permalink when the product has custom permalink but accessed through unique permalink" do
    with_const(:ROOT_DOMAIN, "test.gumroad.com") do
      user = create_user(username: "testuser")
      @request.host = "#{user.username}.test.gumroad.com"
      product = create_product(user:, custom_permalink: "onetwothree")

      get :show, params: { id: product.unique_permalink }
      assert_redirected_to product.long_url
    end
  end

  test "GET show assigns the product and renders the Inertia page when the subdomain and custom permalink are valid and present" do
    with_const(:ROOT_DOMAIN, "test.gumroad.com") do
      user = create_user(username: "testuser")
      @request.host = "#{user.username}.test.gumroad.com"
      product = create_product(user:, custom_permalink: "test-link")

      @request.headers["X-Inertia"] = "true"
      get :show, params: { id: product.custom_permalink }
      assert_response :success
      assert_equal product, assigns[:product]
      assert_equal "Products/Show", inertia_page["component"]
    end
  end

  test "GET show raises RoutingError when the seller from subdomain is different from product's seller" do
    with_const(:ROOT_DOMAIN, "test.gumroad.com") do
      user = create_user(username: "testuser")
      @request.host = "#{user.username}.test.gumroad.com"
      product = create_product(user: create_user(username: "anotheruser"))

      assert_raises(ActionController::RoutingError) { get :show, params: { id: product.unique_permalink } }
    end
  end

  # --- legacy product URL -----------------------------------------------------

  test "GET show redirects to a product URL with subdomain and custom permalink when looked up by unique permalink" do
    @request.host = DOMAIN
    product_1 = create_product(unique_permalink: "abc", custom_permalink: "custom")
    create_product(unique_permalink: "xyz", custom_permalink: "custom")

    get :show, params: { id: "abc" }

    assert_redirected_to product_1.long_url
  end

  test "GET show redirects to a full product URL of the oldest product matched by custom permalink" do
    @request.host = DOMAIN
    product_1 = create_product(unique_permalink: "abc", custom_permalink: "custom")
    create_product(unique_permalink: "xyz", custom_permalink: "custom")

    get :show, params: { id: "custom" }

    assert_redirected_to product_1.long_url
  end

  # --- legacy products lookup -------------------------------------------------

  def setup_legacy_products
    @legacy_user = create_user
    @other_product = create_product(user: create_user, custom_permalink: "custom")
    @product_with_legacy_mapping = create_product(user: create_user, custom_permalink: "custom")
    create_legacy_permalink(permalink: "custom", product: @product_with_legacy_mapping)
    @legacy_product = create_product(user: @legacy_user, custom_permalink: "custom")
  end

  test "GET show serves the oldest live product over a legacy mapping on the bare domain" do
    setup_legacy_products
    @request.host = DOMAIN

    get :show, params: { id: "custom" }

    # @other_product is the oldest live holder, so the mapping must not override it.
    assert_redirected_to @other_product.long_url
  end

  test "GET show redirects via a legacy mapping on the bare domain when no live product holds the slug" do
    setup_legacy_products
    @request.host = DOMAIN
    [@other_product, @legacy_product].each { _1.update!(custom_permalink: "moved-#{_1.id}") }
    @product_with_legacy_mapping.update!(custom_permalink: "mapped-moved")

    get :show, params: { id: "custom" }

    assert_redirected_to @product_with_legacy_mapping.long_url
  end

  test "GET show 404s on the bare domain when the only mapping points at a deleted product" do
    setup_legacy_products
    @request.host = DOMAIN
    # Clear the live holders first, or the live-first read answers before the
    # mapping is ever consulted and the deleted target is never exercised.
    [@other_product, @legacy_product].each { _1.update!(custom_permalink: "moved-#{_1.id}") }
    @product_with_legacy_mapping.mark_deleted!

    # `e404` raises rather than rendering, so this is the file's convention for a
    # missed `GET show` lookup (see the "NOT real" case above).
    assert_raises(ActionController::RoutingError) { get :show, params: { id: "custom" } }
  end

  test "GET show renders the user's product when request comes from a custom domain (legacy lookup)" do
    setup_legacy_products
    CustomDomain.create(domain: "www.example1.com", user: @legacy_user)
    @request.host = "www.example1.com"

    get :show, params: { id: "custom" }

    assert_response :success
    assert_equal @legacy_product, assigns[:product]
  end

  test "GET show renders the user's product when request comes from a subdomain URL (legacy lookup)" do
    setup_legacy_products
    with_const(:ROOT_DOMAIN, "test.gumroad.com") do
      @request.host = "#{@legacy_user.username}.test.gumroad.com"

      get :show, params: { id: "custom" }

      assert_response :success
      assert_equal @legacy_product, assigns[:product]
    end
  end

  # --- setting affiliate cookie -----------------------------------------------

  Affiliate::QUERY_PARAMS.each do |query_param|
    test "GET show sets affiliate cookie with `#{query_param}` query param" do
      frozen_time = Time.current
      travel_to(frozen_time) do
        affiliate_product = create_product
        direct_affiliate = create_direct_affiliate(seller: affiliate_product.user, products: [affiliate_product])
        @request.host = URI.parse(affiliate_product.user.subdomain_with_protocol).host
        get :show, params: { id: affiliate_product.unique_permalink, query_param => direct_affiliate.external_id_numeric }

        expected_cookie_options = {
          expires: direct_affiliate.class.cookie_lifetime.from_now.utc,
          value: frozen_time.to_i.to_s,
          httponly: true,
          domain: determine_domain(request.url)
        }
        cookie = parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate.cookie_key)
        expected_cookie_options.each { |key, value| assert_equal value, cookie.send(key) }
      end
    end

    test "GET show does not set affiliate cookie if affiliate is not alive and is affiliated to other creators with `#{query_param}` query param" do
      frozen_time = Time.current
      travel_to(frozen_time) do
        affiliate_product = create_product
        direct_affiliate = create_direct_affiliate(seller: affiliate_product.user, products: [affiliate_product])
        direct_affiliate_2 = create_direct_affiliate(affiliate_user: direct_affiliate.affiliate_user, seller: create_user)
        direct_affiliate_3 = create_direct_affiliate(affiliate_user: direct_affiliate.affiliate_user, seller: create_user)
        direct_affiliate.mark_deleted!

        @request.host = URI.parse(affiliate_product.user.subdomain_with_protocol).host
        get :show, params: { id: affiliate_product.unique_permalink, query_param => direct_affiliate.external_id_numeric }

        assert_nil parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate.cookie_key)
        assert_nil parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate_2.cookie_key)
        assert_nil parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate_3.cookie_key)
      end
    end

    test "GET show sets affiliate cookie to last alive direct affiliate when direct affiliate is deleted and other direct affiliates exist with `#{query_param}` query param" do
      frozen_time = Time.current
      travel_to(frozen_time) do
        affiliate_product = create_product
        direct_affiliate = create_direct_affiliate(seller: affiliate_product.user, products: [affiliate_product])
        direct_affiliate.update!(deleted_at: Time.current)
        direct_affiliate_2 = create_direct_affiliate(affiliate_user: direct_affiliate.affiliate_user, seller: direct_affiliate.seller, created_at: 1.hour.ago)
        create_product_affiliate(product: direct_affiliate.products.last, affiliate: direct_affiliate_2, affiliate_basis_points: 20_00)

        @request.host = URI.parse(affiliate_product.user.subdomain_with_protocol).host
        get :show, params: { id: affiliate_product.unique_permalink, query_param => direct_affiliate.external_id_numeric }

        expected_cookie_options = {
          expires: direct_affiliate_2.class.cookie_lifetime.from_now.utc,
          value: frozen_time.to_i.to_s,
          httponly: true,
          domain: determine_domain(request.url)
        }
        cookie = parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate_2.cookie_key)
        expected_cookie_options.each { |key, value| assert_equal value, cookie.send(key) }
      end
    end
  end

  test "GET show adds X-Robots-Tag response header to avoid page indexing only if the url contains an offer code" do
    product = create_product(unique_permalink: "abc", user: @user)

    get :show, params: { id: product.unique_permalink, code: "10off" }
    assert_equal "noindex", response.headers["X-Robots-Tag"]

    get :show, params: { id: product.unique_permalink }
    assert_not_includes response.headers.keys, "X-Robots-Tag"

    get :show, params: { id: product.unique_permalink, code: "20off" }
    assert_equal "noindex", response.headers["X-Robots-Tag"]
  end

  # --- Discover tracking ------------------------------------------------------

  test "GET show stores click when coming from discover" do
    cookies[:_gumroad_guid] = "custom_guid"
    taxonomy = Taxonomy.find_or_create_by(slug: "fonts")
    product.update!(taxonomy:)

    assert_difference -> { DiscoverSearch.count }, 1 do
      get :show, params: { id: product.to_param, recommended_by: "search", query: "something", autocomplete: "true" }
    end

    assert_includes_attributes DiscoverSearch.last!.attributes, {
      "query" => "something",
      "ip_address" => "0.0.0.0",
      "browser_guid" => "custom_guid",
      "autocomplete" => true,
      "clicked_resource_type" => product.class.name,
      "clicked_resource_id" => product.id,
      "taxonomy_id" => taxonomy.id,
    }

    assert_difference -> { DiscoverSearch.count }, 1 do
      get :show, params: { id: product.to_param, recommended_by: "discover", query: "something" }
    end

    assert_includes_attributes DiscoverSearch.last!.attributes, {
      "query" => "something",
      "ip_address" => "0.0.0.0",
      "browser_guid" => "custom_guid",
      "autocomplete" => false,
      "clicked_resource_type" => product.class.name,
      "clicked_resource_id" => product.id,
      "taxonomy_id" => taxonomy.id,
    }
  end

  test "GET show stores click with no taxonomy when the clicked product is uncategorized" do
    cookies[:_gumroad_guid] = "custom_guid"
    product.update!(taxonomy: nil)

    assert_difference -> { DiscoverSearch.count }, 1 do
      get :show, params: { id: product.to_param, recommended_by: "discover", query: "something" }
    end

    click = DiscoverSearch.last!
    assert_nil click.taxonomy_id
    assert_equal product.id, click.clicked_resource_id
  end

  test "GET show does not store click when not coming from discover" do
    assert_no_difference -> { DiscoverSearch.count } do
      get :show, params: { id: product.to_param }
    end
  end
end

class LinksControllerConsumerTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers

  setup { @user = create_user }

  # --- GET cart_items_count ---------------------------------------------------

  test "GET cart_items_count returns 0 when no cart exists" do
    get :cart_items_count

    page = inertia_page_from_html
    assert_equal "Products/CartItemsCount", page["component"]
    assert_equal 0, page["props"]["cart_items_count"]

    html = Nokogiri::HTML.parse(response.body)
    [
      "gr:google_analytics:enabled",
      "gr:fb_pixel:enabled",
      "gr:tiktok_pixel:enabled",
    ].each do |property|
      assert_equal "false", html.xpath("//meta[@property='#{property}']/@content").text
    end
  end

  test "GET cart_items_count returns the count of alive cart products" do
    sign_in @user
    product = create_product
    cart = create_cart(user: @user, email: @user.email)
    create_cart_product(cart:, product:)

    @request.headers["X-Inertia"] = "true"
    get :cart_items_count

    page = inertia_page
    assert_equal "Products/CartItemsCount", page["component"]
    assert_equal 1, page["props"]["cart_items_count"]
  end

  test "GET cart_items_count does not count deleted cart products" do
    sign_in @user
    product = create_product
    cart = create_cart(user: @user, email: @user.email)
    create_cart_product(cart:, product:)
    create_cart_product(cart:, product: create_product, deleted_at: Time.current)

    @request.headers["X-Inertia"] = "true"
    get :cart_items_count

    assert_equal 1, inertia_page["props"]["cart_items_count"]
  end

  # --- POST track_user_action -------------------------------------------------

  test "POST track_user_action writes the event to the events table with a product" do
    sign_in @user
    product = create_product
    post :track_user_action, params: { id: product.to_param, event_name: "link_view" }
    event = Event.last!
    assert_equal "link_view", event.event_name
    assert_equal product.id, event.link_id
  end

  test "POST track_user_action writes the event to the events table when requests come from custom domains" do
    sign_in @user
    product = create_product
    @request.host = "www.example1.com"
    create_custom_domain(domain: "www.example1.com", user: nil, product:)
    post :track_user_action, params: { id: product.to_param, event_name: "link_view" }
    event = Event.last!
    assert_equal "link_view", event.event_name
    assert_equal product.id, event.link_id
  end

  # --- create_purchase_event --------------------------------------------------

  test "create_purchase_event creates a purchase event" do
    cookies[:_gumroad_guid] = "blahblahblah"
    product = create_product
    purchase = create_purchase(link: product)
    @controller.create_purchase_event(purchase)
    assert_equal "purchase", Event.order(:id).last.event_name
  end
end

class LinksControllerIncrementViewsTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers

  setup do
    @user = create_user
    @increment_product = create_product
    @request.env["HTTP_USER_AGENT"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_3) AppleWebKit/535.19 (KHTML, like Gecko) Chrome/18.0.1025.165 Safari/535.19"
    ElasticsearchIndexerWorker.jobs.clear
  end

  def assert_page_view_recorded
    post :increment_views, params: { id: @increment_product.to_param }
    assert ElasticsearchIndexerWorker.jobs.any? { |job| job["args"][0] == "index" && job["args"][1]["class_name"] == "ProductPageView" },
           "Expected ElasticsearchIndexerWorker to index a ProductPageView"
  end

  test "POST increment_views records page view with a logged out visitor" do
    sign_out @user
    assert_page_view_recorded
  end

  test "POST increment_views records page view with a logged out user" do
    assert_page_view_recorded
  end

  test "POST increment_views records page view when requests come from custom domains" do
    @request.host = "www.example1.com"
    create_custom_domain(domain: "www.example1.com", user: nil, product: create_product)
    assert_page_view_recorded
  end

  test "POST increment_views does not record page view for the seller of the product" do
    @controller.stubs(:current_user).returns(@increment_product.user)
    post :increment_views, params: { id: @increment_product.to_param }

    assert_equal 0, ElasticsearchIndexerWorker.jobs.size
  end

  test "POST increment_views does not record page view for an admin user" do
    @controller.stubs(:current_user).returns(create_admin_user)
    post :increment_views, params: { id: @increment_product.to_param }

    assert_equal 0, ElasticsearchIndexerWorker.jobs.size
  end

  test "POST increment_views does not record page view for an admin for seller" do
    sign_in_as_admin_for(@increment_product.user)
    post :increment_views, params: { id: @increment_product.to_param }

    assert_equal 0, ElasticsearchIndexerWorker.jobs.size
  end

  test "POST increment_views does not record page view for bots" do
    @request.env["HTTP_USER_AGENT"] = "EventMachine HttpClient"
    post :increment_views, params: { id: @increment_product.to_param }

    assert_equal 0, ElasticsearchIndexerWorker.jobs.size
  end

  test "POST increment_views does not record page view for an admin becoming user" do
    sign_in create_admin_user
    @controller.impersonate_user(@user)
    post :increment_views, params: { id: @increment_product.to_param }

    assert_equal 0, ElasticsearchIndexerWorker.jobs.size
  end

  test "GET increment_views.gif records a page view with the authenticated source URL" do
    sign_out @user
    source_url = "https://landing.example"
    @request.env["HTTP_REFERER"] = source_url
    get :increment_views, params: { id: @increment_product.to_param, format: :gif, analytics_token: @increment_product.analytics_view_token(source_url:) }

    assert_response :success
    assert_equal "image/gif", @response.media_type
    assert ElasticsearchIndexerWorker.jobs.any? { |job| job["args"][0] == "index" && job["args"][1]["class_name"] == "ProductPageView" },
           "Expected ElasticsearchIndexerWorker to index a ProductPageView"
    assert_equal source_url, ElasticsearchIndexerWorker.jobs.last["args"][1]["body"]["url"]
    assert_equal source_url, ElasticsearchIndexerWorker.jobs.last["args"][1]["body"]["referrer"]
  end

  test "GET increment_views.gif ignores spoofed attribution parameters" do
    sign_out @user
    source_url = "https://landing.example"
    @request.env["HTTP_REFERER"] = source_url
    get :increment_views, params: { id: @increment_product.to_param, format: :gif, analytics_token: @increment_product.analytics_view_token(source_url:), view_url: "https://evil.example/post", referrer: "https://evil.example/referrer" }

    assert_response :success
    assert_equal "image/gif", @response.media_type
    assert_equal source_url, ElasticsearchIndexerWorker.jobs.last["args"][1]["body"]["url"]
    assert_equal source_url, ElasticsearchIndexerWorker.jobs.last["args"][1]["body"]["referrer"]
  end

  test "GET increment_views.gif replays only the same script-load token into the same page view id" do
    sign_out @user
    source_url = "https://landing.example/post"
    token = @increment_product.analytics_view_token(source_url:, event_id: "script-load-1")

    @request.env["HTTP_REFERER"] = source_url
    get :increment_views, params: { id: @increment_product.to_param, format: :gif, analytics_token: token }
    first_id = ElasticsearchIndexerWorker.jobs.last["args"][1]["id"]

    @request.env["HTTP_REFERER"] = source_url
    get :increment_views, params: { id: @increment_product.to_param, format: :gif, analytics_token: token }
    second_id = ElasticsearchIndexerWorker.jobs.last["args"][1]["id"]

    assert_equal first_id, second_id

    get :increment_views, params: { id: @increment_product.to_param, format: :gif, analytics_token: @increment_product.analytics_view_token(source_url:, event_id: "script-load-2") }
    third_id = ElasticsearchIndexerWorker.jobs.last["args"][1]["id"]

    assert_not_equal first_id, third_id
  end

  test "GET increment_views.gif does not record page view without a valid analytics token" do
    sign_out @user
    get :increment_views, params: { id: @increment_product.to_param, format: :gif, analytics_token: "invalid" }

    assert_response :success
    assert_equal "image/gif", @response.media_type
    assert_equal 0, ElasticsearchIndexerWorker.jobs.size
  end

  test "GET increment_views.gif does not record page view with another product's analytics token" do
    sign_out @user
    other_product = create_product
    source_url = "https://landing.example/post"
    @request.env["HTTP_REFERER"] = source_url
    get :increment_views, params: { id: @increment_product.to_param, format: :gif, analytics_token: other_product.analytics_view_token(source_url:) }

    assert_response :success
    assert_equal "image/gif", @response.media_type
    assert_equal 0, ElasticsearchIndexerWorker.jobs.size
  end

  test "GET increment_views.gif does not record page view when the token is replayed from another source" do
    sign_out @user
    @request.env["HTTP_REFERER"] = "https://evil.example/post"
    get :increment_views, params: { id: @increment_product.to_param, format: :gif, analytics_token: @increment_product.analytics_view_token(source_url: "https://landing.example/post") }

    assert_response :success
    assert_equal "image/gif", @response.media_type
    assert_equal 0, ElasticsearchIndexerWorker.jobs.size
  end

  test "GET increment_views.gif does not record page view for bots" do
    @request.env["HTTP_USER_AGENT"] = "EventMachine HttpClient"
    source_url = "https://landing.example/post"
    @request.env["HTTP_REFERER"] = source_url
    get :increment_views, params: { id: @increment_product.to_param, format: :gif, analytics_token: @increment_product.analytics_view_token(source_url:) }

    assert_response :success
    assert_equal 0, ElasticsearchIndexerWorker.jobs.size
  end
end

class LinksControllerWithoutEmailTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers

  setup do
    @user = create_user(provider: :twitter, email: nil, unconfirmed_email: nil)
    sign_in @user
    @request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i
  end

  test "redirects authenticated seller actions to the settings page" do
    get :index
    assert_redirected_to settings_main_path
  end

  test "does not gate the public product page" do
    seller = create_eligible_seller
    product = create_product(user: seller)
    @request.host = URI.parse(seller.subdomain_with_protocol).host

    get :show, params: { id: product.to_param }

    assert_response :success
  end
end

class LinksControllerIncrementViewsDataRecordedTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers
  include RealElasticsearchBridge

  setup do
    @user = create_user
    @increment_product = create_product
    @request.env["HTTP_USER_AGENT"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_3) AppleWebKit/535.19 (KHTML, like Gecko) Chrome/18.0.1025.165 Safari/535.19"
    ElasticsearchIndexerWorker.jobs.clear
    install_real_elasticsearch!([ProductPageView])
    travel_to Time.utc(2021, 1, 1)
    sign_in @user
  end

  teardown { restore_fake_elasticsearch! }

  # The page-view indexer runs inline here (RSpec's :sidekiq_inline) and the
  # index write is followed by a refresh (RSpec's :elasticsearch_wait_for_refresh)
  # so the document is immediately searchable.
  def record_view(params = {})
    Sidekiq::Testing.inline! do
      post :increment_views, params: { id: @increment_product.to_param }.merge(params)
    end
  end

  def last_page_view_data
    ProductPageView.__elasticsearch__.refresh_index!
    ProductPageView.search({ sort: { timestamp: :desc }, size: 1 }).first["_source"]
  end

  test "POST increment_views sets basic data" do
    record_view
    assert_equal(
      {
        product_id: @increment_product.id,
        seller_id: @increment_product.user_id,
        country: nil,
        state: nil,
        referrer_domain: "direct",
        timestamp: "2021-01-01T00:00:00Z",
        user_id: @user.id,
        ip_address: "0.0.0.0",
        url: "/links/#{@increment_product.unique_permalink}/increment_views",
        browser_guid: cookies[:_gumroad_guid],
        browser_fingerprint: Digest::MD5.hexdigest(@request.env["HTTP_USER_AGENT"] + ","),
        referrer: nil,
      }.with_indifferent_access,
      last_page_view_data.with_indifferent_access
    )
  end

  test "POST increment_views sets country and state from custom IP address" do
    @request.remote_ip = "54.234.242.13"
    record_view
    assert_includes_attributes last_page_view_data.with_indifferent_access, {
      country: "United States",
      state: "VA",
      ip_address: "54.234.242.13",
    }.with_indifferent_access
  end

  test "POST increment_views sets referrer" do
    @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    record_view
    assert_includes_attributes last_page_view_data.with_indifferent_access, {
      referrer_domain: "youtube.com",
      referrer: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    }.with_indifferent_access
  end

  test "POST increment_views sets referrer via HTTP header" do
    @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    record_view
    assert_includes_attributes last_page_view_data.with_indifferent_access, {
      referrer_domain: "youtube.com",
      referrer: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    }.with_indifferent_access
  end

  test "POST increment_views sets referrer via params" do
    record_view(referrer: "https://gum.co/posts/news-新しい?#{"1" * 200}&extra")
    assert_includes_attributes last_page_view_data.with_indifferent_access, {
      referrer_domain: "gum.co",
      referrer: "https://gum.co/posts/news-?#{"1" * 164}",
    }.with_indifferent_access
  end

  test "POST increment_views sets custom browser_guid" do
    cookies[:_gumroad_guid] = "custom_guid"
    record_view
    assert_equal "custom_guid", last_page_view_data["browser_guid"]
  end

  test "POST increment_views sets user_id to nil when the user is signed out" do
    sign_out @user
    record_view
    assert_nil last_page_view_data["user_id"]
  end

  test "POST increment_views sets correct referrer_domain when product is not recommended" do
    @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    record_view(was_product_recommended: false)
    assert_equal "youtube.com", last_page_view_data["referrer_domain"]
  end

  test "POST increment_views sets correct referrer_domain when product is recommended" do
    @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    record_view(was_product_recommended: true)
    assert_equal "recommended_by_gumroad", last_page_view_data["referrer_domain"]
  end
end

class LinksControllerSearchTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers
  include RealElasticsearchBridge

  setup do
    @user = create_user
    @recommended_by = "search"
    @on_profile = false
    install_real_elasticsearch!([Link, Purchase])
  end

  teardown { restore_fake_elasticsearch! }

  # The :compliant_user factory carries the base :user factory's payment_address,
  # which Product#recommendable? requires; create_user doesn't set one, so spell
  # it out here to keep the creator's products discoverable.
  def create_compliant_user(**attrs)
    create_user(user_risk_state: "compliant", payment_address: "compliant-#{unique_suffix}@example.com", **attrs)
  end

  def product_json(product, target, query = @request.params["query"])
    ProductPresenter.card_for_web(product:, request: @request, recommended_by: @recommended_by, show_seller: !@on_profile, target:, query:).as_json
  end

  test "GET search accepts a string ids param when searching by user" do
    Link.__elasticsearch__.create_index!(force: true)
    creator = create_compliant_user(username: "creatordudey", name: "Creator Dudey")
    section = create_seller_profile_products_section(seller: creator)
    product = create_product(name: "Top quality weasel", user: creator)
    other_product = create_product(name: "First product", user: creator)
    section.update!(shown_products: [other_product, product].map(&:id))
    Link.import(force: true, refresh: true)

    @recommended_by = nil
    @on_profile = true

    get :search, params: { user_id: creator.external_id, section_id: section.external_id, ids: product.external_id }

    assert_response :success
    assert_equal [product_json(product, "profile")], response.parsed_body["products"]
  end

  test "GET search searches by explicit ids when the section is not persisted yet" do
    Link.__elasticsearch__.create_index!(force: true)
    creator = create_compliant_user(username: "creatordudey", name: "Creator Dudey")
    product = create_product(name: "Top quality weasel", user: creator)
    other_product = create_product(name: "First product", user: creator)
    Link.import(force: true, refresh: true)

    @recommended_by = nil
    @on_profile = true

    get :search, params: {
      user_id: creator.external_id,
      section_id: "0b8f3782-3a85-4f93-8e3c-2b1f5d3e8a90",
      ids: [other_product.external_id, product.external_id].join(","),
      sort: ProductSortKey::PAGE_LAYOUT,
    }

    assert_response :success
    assert_equal [product_json(other_product, "profile"), product_json(product, "profile")], response.parsed_body["products"]
  end

  def setting_and_ordering_setup
    Link.__elasticsearch__.create_index!(force: true)
    @creator = create_compliant_user(username: "creatordudey", name: "Creator Dudey")
    @section = create_seller_profile_products_section(seller: @creator)
    @sao_product = create_product(name: "Top quality weasel", user: @creator, taxonomy: Taxonomy.find_or_create_by(slug: "3d"))
    reviewed = create_purchase(link: @sao_product, created_at: 1.week.ago)
    create_product_review(purchase: reviewed, rating: 5)
    create_product_review(link: @sao_product)
    Link.import(force: true, refresh: true)
  end

  test "GET search returns the expected JSON response when no search parameters are specified" do
    setting_and_ordering_setup
    expected = {
      "total" => 1,
      "filetypes_data" => [],
      "tags_data" => [],
      "taxonomy_attributes_data" => [],
      "products" => [product_json(@sao_product, "discover")]
    }
    get :search
    assert_equal expected, response.parsed_body

    get :search, params: { query: "" }
    assert_equal expected, response.parsed_body
  end

  test "GET search returns the expected JSON response when searching by a user" do
    setting_and_ordering_setup
    @sao_product.tag!("mustelid")
    @on_profile = true
    @recommended_by = nil
    another_product = create_product(name: "Another product", user: @creator)
    products = create_list(:product, 20, user: @creator)
    product3 = create_product(user: @creator)
    create_product_file(link: another_product)
    create_product(name: "Bad product", user: @creator)
    shown_products = [@sao_product, product3, another_product] + products
    @section.update!(shown_products: shown_products.map(&:id))
    Link.import(force: true, refresh: true)

    get :search, params: { user_id: @creator.external_id, section_id: @section.external_id }

    assert_equal({
                   "total" => 23,
                   "filetypes_data" => [{ "doc_count" => 1, "key" => "pdf" }],
                   "tags_data" => [{ "doc_count" => 1, "key" => "mustelid" }],
                   "taxonomy_attributes_data" => [],
                   "products" => shown_products[0...9].map { |p| product_json(p, "profile") }
                 }, response.parsed_body)
  end

  test "GET search returns products in page layout order when applicable if searching by user" do
    setting_and_ordering_setup
    @recommended_by = nil
    @on_profile = true
    product_b = create_product(name: "First product", user: @creator)
    product_c = create_product(name: "Second product", user: @creator)
    create_product(name: "Hide me", user: @creator)
    @section.update!(shown_products: [product_b, product_c, @sao_product].map(&:id))
    Link.import(force: true, refresh: true)

    get :search, params: { user_id: @creator.external_id, section_id: @section.external_id }
    assert_equal [product_json(product_b, "profile"), product_json(product_c, "profile"), product_json(@sao_product, "profile")], response.parsed_body["products"]
  end

  test "GET search returns an empty response when searching by non-existent user" do
    setting_and_ordering_setup
    get :search, params: { user_id: 1640736000000, section_id: @section.id }
    assert_equal({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "taxonomy_attributes_data" => [], "products" => [] }, response.parsed_body)
  end

  test "GET search returns an empty response when searching by non-existent section" do
    setting_and_ordering_setup
    get :search, params: { user_id: @creator.external_id, section_id: 1640736000000 }
    assert_equal({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "taxonomy_attributes_data" => [], "products" => [] }, response.parsed_body)

    section = create_seller_profile_posts_section(seller: @creator)
    get :search, params: { user_id: @creator.external_id, section_id: section.id }
    assert_equal({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "taxonomy_attributes_data" => [], "products" => [] }, response.parsed_body)
  end

  test "GET search returns all the creator's live profile products for the virtual default products section" do
    setting_and_ordering_setup
    @recommended_by = nil
    @on_profile = true
    @section.destroy!
    another_product = create_product(name: "Another product", user: @creator)
    Link.import(force: true, refresh: true)

    get :search, params: { user_id: @creator.external_id, section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }

    assert_response :success
    assert_equal 2, response.parsed_body["total"]
    assert_equal [product_json(@sao_product, "profile"), product_json(another_product, "profile")].sort_by { |p| p["permalink"] }, response.parsed_body["products"].sort_by { |p| p["permalink"] }
  end

  test "GET search returns an empty response for the default products section id when the creator has saved sections" do
    setting_and_ordering_setup
    get :search, params: { user_id: @creator.external_id, section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }

    assert_equal({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "taxonomy_attributes_data" => [], "products" => [] }, response.parsed_body)
  end

  test "GET search accepts the default products section id when the creator has only non-product sections" do
    setting_and_ordering_setup
    @recommended_by = nil
    @on_profile = true
    @section.destroy!
    create_seller_profile_posts_section(seller: @creator)
    Link.import(force: true, refresh: true)

    get :search, params: { user_id: @creator.external_id, section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }

    assert_response :success
    assert_equal 1, response.parsed_body["total"]
    assert_equal [product_json(@sao_product, "profile")], response.parsed_body["products"]
  end

  test "GET search honors exclude_ids on the default products section" do
    setting_and_ordering_setup
    @recommended_by = nil
    @on_profile = true
    @section.destroy!
    create_seller_profile_posts_section(seller: @creator)
    Link.import(force: true, refresh: true)

    get :search, params: {
      user_id: @creator.external_id,
      section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID,
      exclude_ids: [@sao_product.external_id],
    }

    assert_response :success
    assert_equal 0, response.parsed_body["total"]
    assert_equal [], response.parsed_body["products"]
  end

  test "GET search ignores crafted nested exclude_ids instead of 500ing" do
    setting_and_ordering_setup
    @recommended_by = nil
    @on_profile = true
    @section.destroy!
    create_seller_profile_posts_section(seller: @creator)
    Link.import(force: true, refresh: true)

    get :search, params: {
      user_id: @creator.external_id,
      section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID,
      exclude_ids: { "a" => [@sao_product.external_id] },
    }

    assert_response :success
    assert_equal 1, response.parsed_body["total"]
  end

  test "GET search searches only for recommendable products" do
    setting_and_ordering_setup
    bad = create_product(name: "Previously-owned weasel")
    @sao_product.tag!("mustelid")
    bad.tag!("irrelevant")
    create_product_file(link: @sao_product)
    create_product_review(purchase: create_purchase(link: @sao_product, created_at: 1.month.ago))
    Link.import(force: true, refresh: true)

    get :search, params: { query: "weasel" }

    assert_equal({
                   "total" => 1,
                   "filetypes_data" => [{ "doc_count" => 1, "key" => "pdf" }],
                   "tags_data" => [{ "doc_count" => 1, "key" => "mustelid" }],
                   "taxonomy_attributes_data" => [],
                   "products" => [product_json(@sao_product, "discover")]
                 }, response.parsed_body)
  end

  test "GET search returns product in fee revenue order" do
    setting_and_ordering_setup
    products = %i[meh unpopular popular old].each_with_object({}) do |name, hash|
      hash[name] = create_product
      hash[name].tag!("ocelot")
      hash[name].expects(:recommendable?).at_least_once.returns(true)
    end
    travel_to(4.months.ago) { 4.times { create_purchase(link: products[:old]) } }
    3.times { create_purchase(link: products[:popular]) }
    2.times { create_purchase(link: products[:meh]) }
    create_purchase(link: products[:unpopular])
    index_model_records(Purchase)
    products.each do |_key, product|
      product.stubs(:reviews_count).returns(1)
      product.__elasticsearch__.index_document
      product.unstub(:reviews_count)
    end
    Link.__elasticsearch__.refresh_index!
    get :search, params: { query: "ocelot" }

    assert_equal [
      product_json(products[:popular], "discover"),
      product_json(products[:meh], "discover"),
      product_json(products[:unpopular], "discover"),
      product_json(products[:old], "discover")
    ], response.parsed_body["products"]
  end

  test "GET search searches successfully for a product with a regex character" do
    setting_and_ordering_setup
    @sao_product.update(name: "Top [quality weasel")
    Link.import(force: true, refresh: true)
    get :search, params: { query: "Top [quality" }
    assert_equal [product_json(@sao_product, "discover")], response.parsed_body["products"]
  end

  def loose_matching_setup
    Link.__elasticsearch__.create_index!(force: true)
    @loose_products = {
      name: create_product(name: "North American river otter"),
      desc: create_product(description: "The North American river otter, also known as the northern river otter or the common otter, is a semiaquatic mammal."),
      creator: create_product(user: create_user(name: "Brig. Gen. W. North American River Otter III")),
      inexact: create_product(description: "An American otter is found in the north river."),
      partial: create_product(name: "Just an ordinary otter"),
      cross_field: create_product(name: "River otter", description: "Animals of this description are common and live in the North and the South of the American and European continents."),
      tagged: create_product(name: "River otter")
    }
    @loose_products[:tagged].tag!("North American")
    @loose_products[:tagged].tag!("common")
    @loose_products.each do |_key, product|
      product.expects(:recommendable?).at_least_once.returns(true)
      product.stubs(:reviews_count).returns(1)
      product.__elasticsearch__.index_document
      product.unstub(:reviews_count)
    end
    Link.__elasticsearch__.refresh_index!
    sleep 0.5
  end

  test "GET search finds all matches if exact match not specified" do
    loose_matching_setup
    get :search, params: { query: "north american river otter" }
    assert_equal %i[name desc creator inexact cross_field tagged].map { |key| product_json(@loose_products[key], "discover") }.sort_by { |p| p["permalink"] },
                 response.parsed_body["products"].sort_by { |p| p["permalink"] }
  end

  test "GET search finds exact match if double-quotes used" do
    loose_matching_setup
    get :search, params: { query: '" north american river otter  "' }
    assert_equal %i[name desc creator].map { |key| product_json(@loose_products[key], "discover") }.sort_by { |p| p["permalink"] },
                 response.parsed_body["products"].sort_by { |p| p["permalink"] }
  end

  test "GET search finds compound match when double-quotes used in combination with another term" do
    loose_matching_setup
    get :search, params: { query: 'common "river otter"' }
    assert_equal %i[desc cross_field tagged].map { |key| product_json(@loose_products[key], "discover") }.sort_by { |p| p["permalink"] },
                 response.parsed_body["products"].sort_by { |p| p["permalink"] }
  end

  test "GET search finds results for a complex match across different fields" do
    loose_matching_setup
    get :search, params: { query: 'north "river otter" american' }
    assert_equal %i[name desc creator cross_field tagged].map { |key| product_json(@loose_products[key], "discover") }.sort_by { |p| p["permalink"] },
                 response.parsed_body["products"].sort_by { |p| p["permalink"] }
  end

  test "GET search handles potentially malformed query" do
    loose_matching_setup
    get :search, params: { query: "\\" }
    assert_equal [], response.parsed_body["products"]
  end

  test "GET search filters on discover for products with no reviews" do
    Link.__elasticsearch__.create_index!(force: true)
    user = create_recommendable_user
    create_seller_profile_products_section(seller: user)
    create_product(name: "sample 2", user:)
    product_with_review = create_product(name: "sample 1", user:, taxonomy: Taxonomy.find_or_create_by(slug: "films"))
    # ONE review, deliberately. The rspec original gave this product a single review (via
    # the :recommendable trait), and that was the point: one review is enough to clear the
    # discover filter. A second review would still pass today but would stop this test from
    # failing if the threshold ever regressed from one review to two.
    # rating: 5 is explicit because create_product_review defaults to 1 here, where the
    # rspec factory defaulted higher.
    create_product_review(purchase: create_purchase(link: product_with_review, created_at: 1.week.ago), rating: 5)
    Link.import(force: true, refresh: true)
    Link.__elasticsearch__.refresh_index!

    get :search, params: { query: "sample" }
    assert_equal [product_json(product_with_review, "discover")], response.parsed_body["products"]
  end

  test "GET search does not filter on profile for products with no reviews" do
    Link.__elasticsearch__.create_index!(force: true)
    user = create_recommendable_user
    section = create_seller_profile_products_section(seller: user)
    product_without_review = create_product(name: "sample 2", user:)
    product_with_review = create_product(name: "sample 1", user:, taxonomy: Taxonomy.find_or_create_by(slug: "films"))
    create_product_review(purchase: create_purchase(link: product_with_review, created_at: 1.week.ago), rating: 5)
    create_product_review(purchase: create_purchase(link: product_with_review))
    Link.import(force: true, refresh: true)
    Link.__elasticsearch__.refresh_index!

    @recommended_by = nil
    @on_profile = true
    get :search, params: { user_id: user.external_id, section_id: section.external_id }
    assert_equal [product_json(product_without_review, "profile"), product_json(product_with_review, "profile")], response.parsed_body["products"]
  end

  test "GET search stores the search query along with useful metadata" do
    Taxonomy.find_or_create_by(slug: "3d")
    cookies[:_gumroad_guid] = "custom_guid"
    sign_in @user

    assert_difference -> { DiscoverSearch.count }, 1 do
      get :search, params: { query: "something", taxonomy: "3d" }
    end

    assert_includes_attributes DiscoverSearch.last!.attributes, {
      "query" => "something",
      "user_id" => @user.id,
      "taxonomy_id" => Taxonomy.find_by_path(["3d"]).id,
      "ip_address" => "0.0.0.0",
      "browser_guid" => "custom_guid",
      "autocomplete" => false
    }
  end

  test "GET search does not store search when querying user products" do
    assert_no_difference -> { DiscoverSearch.count } do
      get :search, params: { query: "something", user_id: @user.id }
    end
  end
end

# Covers the deletion audit trail (ProductVariantDeletionAudit), added because a
# July 2026 production investigation of 55 candidate products could not tell
# whether a deleted version had been explicitly confirmed by the seller: the
# confirmation list arrives on the request and was never stored anywhere.
#
# These tests assert the audit records what actually happened, and — just as
# importantly — that it cannot alter or break the save it observes.
class LinksControllerDeletionAuditTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers

  setup do
    sign_in_seller_area!
    @product = create_product_with_pdf_file(user: @seller)
    product_file = @product.product_files.alive.first
    @params = {
      id: @product.unique_permalink,
      name: "sumlink",
      description: "New description",
      files: [{ id: product_file.external_id, url: product_file.url }],
    }
    @category = create_variant_category(link: @product, title: "Versions")
  end

  # The `options.nil?` branch: the category is submitted with no options, which
  # the save reads as "remove this whole grouping".
  test "a category submitted with no options records an audit for the variants it actually deleted" do
    variant = create_variant(variant_category: @category, name: "Plain version")

    assert_difference -> { ProductVariantDeletionAudit.count }, 1 do
      post :update, params: @params.merge(variants: []), format: :json
      assert_response :success
    end

    audit = ProductVariantDeletionAudit.last
    assert_equal ProductVariantDeletionAudit::EDITOR_CATEGORY_OMITTED, audit.route
    assert_equal @product.id, audit.product_id
    assert_equal @logged_in_user.id, audit.actor_user_id
    assert_equal [variant.external_id], audit.deleted_variant_external_ids
    assert_equal 1, audit.deleted_variant_count
    assert_equal ProductVariantDeletionAudit::PAYLOAD_OMISSION, audit.intent_source
    assert_equal 0, audit.confirmed_affected_variant_count
    assert_equal 1, audit.unconfirmed_affected_variant_count
    # The revision token does not exist yet (gumroad-private#1379).
    assert_nil audit.revision_token
  end

  # The diff branch: the category survives, one version is missing from the
  # submitted list AND was explicitly confirmed for removal.
  test "a confirmed removal from a surviving category records intent as confirmed ids" do
    kept = create_variant(variant_category: @category, name: "Kept")
    removed = create_variant(variant_category: @category, name: "Removed")

    assert_difference -> { ProductVariantDeletionAudit.count }, 1 do
      post :update, params: @params.merge(
        variants: [{ id: kept.external_id, name: "Kept" }],
        confirmed_removed_variant_ids: [removed.external_id],
      ), format: :json
      assert_response :success
    end

    audit = ProductVariantDeletionAudit.last
    assert_equal ProductVariantDeletionAudit::EDITOR_VARIANTS_DIFFED, audit.route
    assert_equal [removed.external_id], audit.deleted_variant_external_ids
    assert_equal [removed.external_id], audit.confirmed_affected_variant_external_ids
    assert_equal ProductVariantDeletionAudit::CONFIRMED_IDS, audit.intent_source
    assert_equal 0, audit.unconfirmed_affected_variant_count
    assert kept.reload.alive?
  end

  # The confirmation list can name rows this request never deleted. Only the
  # intersection with what was actually affected belongs in the audit, otherwise
  # the record overstates what the seller agreed to in this save.
  test "only confirmed ids that were actually deleted are recorded" do
    removed = create_variant(variant_category: @category, name: "Removed")
    already_gone = create_variant(variant_category: @category, name: "Already gone")
    already_gone_external_id = already_gone.external_id
    already_gone.mark_deleted!

    post :update, params: @params.merge(
      variants: [],
      confirmed_removed_variant_ids: [removed.external_id, already_gone_external_id],
    ), format: :json
    assert_response :success

    audit = ProductVariantDeletionAudit.last
    assert_equal [removed.external_id], audit.deleted_variant_external_ids
    assert_equal [removed.external_id], audit.confirmed_affected_variant_external_ids
    assert_not_includes audit.deleted_variant_external_ids, already_gone_external_id
  end

  # --- the outer category sweep (Product::VariantsUpdaterService) ---
  #
  # A whole grouping absent from the payload is swept after each submitted
  # grouping is processed. The sweep soft-deletes the grouping's versions with
  # it (gumroad-private#1784 — leaving them alive under a deleted grouping is a
  # state the editor cannot load or save back). Intent is still judged against
  # the versions the sweep authorised removing: judging it from the deleted set
  # would misreport a version an earlier save had already removed.

  test "a swept category whose children were all confirmed records intent as confirmed ids" do
    swept = create_variant_category(link: @product, title: "Swept")
    child = create_variant(variant_category: swept, name: "Confirmed child")
    kept_variant = create_variant(variant_category: @category, name: "Kept")

    post :update, params: @params.merge(
      variants: [{ id: kept_variant.external_id, name: "Kept" }],
      confirmed_removed_variant_ids: [child.external_id],
    ), format: :json
    assert_response :success

    audit = ProductVariantDeletionAudit.where(route: ProductVariantDeletionAudit::EDITOR_CATEGORY_SWEPT).last
    assert_not_nil audit, "expected an audit for the swept category"
    assert_equal [swept.external_id], audit.deleted_variant_category_external_ids
    assert_equal [child.external_id], audit.affected_variant_external_ids
    assert_equal [child.external_id], audit.deleted_variant_external_ids
    assert_equal ProductVariantDeletionAudit::CONFIRMED_IDS, audit.intent_source
    assert_equal 0, audit.unconfirmed_affected_variant_count
    # The sweep takes the versions with the grouping, so none stay alive under it.
    assert_equal 0, audit.alive_child_variant_count
    assert_equal true, child.reload.deleted?
  end

  test "a swept category with some children confirmed records intent as mixed" do
    swept = create_variant_category(link: @product, title: "Swept")
    confirmed_child = create_variant(variant_category: swept, name: "Confirmed child")
    unconfirmed_child = create_variant(variant_category: swept, name: "Unconfirmed child")
    kept_variant = create_variant(variant_category: @category, name: "Kept")

    post :update, params: @params.merge(
      variants: [{ id: kept_variant.external_id, name: "Kept" }],
      confirmed_removed_variant_ids: [confirmed_child.external_id],
    ), format: :json
    assert_response :success

    audit = ProductVariantDeletionAudit.where(route: ProductVariantDeletionAudit::EDITOR_CATEGORY_SWEPT).last
    assert_not_nil audit
    assert_equal ProductVariantDeletionAudit::MIXED, audit.intent_source
    assert_equal 2, audit.affected_variant_count
    assert_equal 1, audit.confirmed_affected_variant_count
    assert_equal 1, audit.unconfirmed_affected_variant_count
    assert_includes audit.affected_variant_external_ids, unconfirmed_child.external_id
  end

  test "a swept category with no confirmations records intent as payload omission" do
    swept = create_variant_category(link: @product, title: "Swept")
    create_variant(variant_category: swept, name: "Unconfirmed child")
    kept_variant = create_variant(variant_category: @category, name: "Kept")

    post :update, params: @params.merge(
      variants: [{ id: kept_variant.external_id, name: "Kept" }],
    ), format: :json
    assert_response :success

    audit = ProductVariantDeletionAudit.where(route: ProductVariantDeletionAudit::EDITOR_CATEGORY_SWEPT).last
    assert_not_nil audit
    assert_equal ProductVariantDeletionAudit::PAYLOAD_OMISSION, audit.intent_source
    assert_equal 0, audit.confirmed_affected_variant_count
  end

  # A blocked save deleted nothing, so there is nothing to audit. This also pins
  # that the audit did not weaken the guard.
  test "a save blocked by the deletion guard writes no audit and still fails" do
    protected_variant = create_variant(variant_category: @category, name: "Paid version", price_difference_cents: 500)

    assert_no_difference -> { ProductVariantDeletionAudit.count } do
      post :update, params: @params.merge(variants: []), format: :json
      assert_response :unprocessable_entity
    end

    assert protected_variant.reload.alive?
  end

  # The blocked-save test above raises BEFORE any audit is scheduled, so it says
  # nothing about rollback. This one lets the deletion and the audit scheduling
  # both happen, then fails the transaction afterwards: the after-commit callback
  # must not fire, because the deletion it would describe never committed.
  test "a real deletion rolled back writes no audit and leaves the variant alive" do
    variant = create_variant(variant_category: @category, name: "Plain version")

    assert_no_difference -> { ProductVariantDeletionAudit.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        ActiveRecord::Base.transaction do
          # A REAL deletion through the same service the editor uses, so this
          # exercises the actual audit scheduling rather than a bare call.
          Product::VariantCategoryUpdaterService.new(
            product: @product,
            category_params: { id: @category.external_id, options: nil },
            confirmed_removed_variant_ids: [variant.external_id],
            deletion_audit_context: { actor_user_id: @logged_in_user.id }
          ).perform

          # The deletion is real at this point...
          assert_not BaseVariant.find(variant.id).alive?

          # ...and then the transaction fails.
          raise ActiveRecord::RecordInvalid.new(Link.new)
        end
      end
    end

    # The deletion was rolled back, so the version is alive again and the audit
    # that would have described it was never written. This is why audits are
    # written after commit rather than inline.
    assert variant.reload.alive?
  end

  # Observability must never take down a save. This stubs `create!` to raise the
  # error a real database failure produces, rather than executing a genuinely
  # failing INSERT — the point being verified is that the rescue path swallows a
  # persistence error and leaves the deletion committed, not that any particular
  # SQL is rejected.
  test "a failing audit write does not stop the deletion" do
    variant = create_variant(variant_category: @category, name: "Plain version")

    ProductVariantDeletionAudit.stub(:create!, ->(**_args) { raise ActiveRecord::StatementInvalid, "simulated database failure" }) do
      assert_no_difference -> { ProductVariantDeletionAudit.count } do
        post :update, params: @params.merge(variants: []), format: :json
        assert_response :success
      end
    end

    # The deletion still happened and committed.
    assert_not variant.reload.alive?
  end

  # A broken notifier must not resurrect the exception it was called to swallow.
  test "a failing error notifier also cannot stop the deletion" do
    variant = create_variant(variant_category: @category, name: "Plain version")

    ProductVariantDeletionAudit.stub(:create!, ->(**_args) { raise ActiveRecord::StatementInvalid, "simulated database failure" }) do
      ErrorNotifier.stub(:notify, ->(*_args, **_kwargs) { raise "notifier is down" }) do
        post :update, params: @params.merge(variants: []), format: :json
        assert_response :success
      end
    end

    assert_not variant.reload.alive?
  end

  # Correlation logging used to run INSIDE the deletion's transaction, where a
  # raising logger propagated out, rolled the deletion back, and turned a full disk
  # into a save that silently did not delete. Proven empirically before the fix.
  #
  # It now runs in `after_commit`, after the row is written, so a raise can no
  # longer undo the deletion — it would instead 500 a request whose work had fully
  # succeeded. This asserts the weaker-but-still-required property that survives
  # the move: a broken logger costs the log line and nothing else.
  test "a broken correlation logger cannot stop an editor save" do
    variant = create_variant(variant_category: @category, name: "Plain version")

    AuditCorrelationId.stub(:log_pair, ->(**_args) { raise IOError, "log device full" }) do
      post :update, params: @params.merge(variants: []), format: :json
      assert_response :success
    end

    # The deletion still committed, and the audit row was still written: a missing
    # log line must not cost the row as well.
    assert_not variant.reload.alive?
    assert_equal 1, ProductVariantDeletionAudit.where(product_id: @product.id).count
  end

  # The real logger object raising, rather than the wrapper being stubbed out —
  # this exercises the rescue inside AuditCorrelationId.log_pair itself.
  test "a logger that raises is swallowed by log_pair" do
    broken = Object.new
    def broken.info(*) = raise(IOError, "log device full")

    assert_nothing_raised do
      assert_not AuditCorrelationId.log_pair(
        request_id: "req-1",
        correlation_id: AuditCorrelationId.for("req-1"),
        logger: broken
      )
    end
  end

  # The pair has to reach the log, or a correlation id that exists only in the
  # database cannot correlate anything.
  #
  # Asserted here on the CALL, not on the request id's value: `post` rebuilds the
  # rack env, so a request id pre-set on @request is wiped, and
  # ActionDispatch::RequestId is middleware that controller tests bypass entirely.
  # The end-to-end version with a real request id lives in
  # test/integration/product_variant_deletion_audit_request_id_test.rb.
  test "a successful deletion logs a correlation pair exactly once" do
    variant = create_variant(variant_category: @category, name: "Plain version")

    # Capture the pair as it is logged. The write is deferred to after_commit, so a
    # `Rails.stub(:logger)` block can close before it runs; recording the arguments
    # is both simpler and not timing-dependent.
    logged = []
    AuditCorrelationId.stub(:log_pair, ->(request_id:, correlation_id:, **) { logged << [request_id, correlation_id]; true }) do
      post :update, params: @params.merge(variants: []), format: :json
      assert_response :success
    end

    audit = ProductVariantDeletionAudit.where(product_id: @product.id).sole
    assert_not variant.reload.alive?

    # Exactly one pair, carrying the digest that was actually stored.
    assert_equal 1, logged.size
    assert_equal audit.correlation_id, logged.sole.last
  end

  # A correlation id in the log must always lead to an audit row. If the INSERT
  # fails, logging the pair anyway would leave a line pointing at a row that does
  # not exist — the exact false trail the correlation id is meant to prevent.
  test "a failed audit write logs no correlation pair" do
    create_variant(variant_category: @category, name: "Plain version")

    logged = []
    ProductVariantDeletionAudit.stub(:create!, ->(**_args) { raise ActiveRecord::StatementInvalid, "simulated database failure" }) do
      AuditCorrelationId.stub(:log_pair, ->(**kwargs) { logged << kwargs; true }) do
        assert_no_difference -> { ProductVariantDeletionAudit.count } do
          post :update, params: @params.merge(variants: []), format: :json
          assert_response :success
        end
      end
    end

    assert_empty logged, "no row was written, so no correlation line should exist"
  end

  # The real log line, end to end through the real logger, so the format itself is
  # covered rather than just the call.
  test "log_pair writes the request id and correlation id to the log" do
    log = StringIO.new

    assert AuditCorrelationId.log_pair(
      request_id: "req-abc",
      correlation_id: "digest-xyz",
      logger: ActiveSupport::Logger.new(log)
    )

    assert_match(/\[audit_correlation\] request_id=req-abc correlation_id=digest-xyz/, log.string)
  end

  # ...and only then. A save that deletes nothing must not emit a correlation
  # line, or the log fills with entries that lead to no audit row.
  test "a save that deletes nothing logs no correlation line" do
    # Submit the variant so the save KEEPS it. Note @params carries no `variants`
    # key at all, which the save reads as "remove everything" — reusing @params
    # unchanged would delete, not preserve, which is what made an earlier version
    # of this test pass for the wrong reason.
    variant = create_variant(variant_category: @category, name: "Plain version")
    keep = @params.merge(variants: [{ id: variant.external_id, name: variant.name }])

    logged = []
    AuditCorrelationId.stub(:log_pair, ->(**kwargs) { logged << kwargs; true }) do
      post :update, params: keep, format: :json
      assert_response :success
    end

    assert variant.reload.alive?, "the variant should have been kept, not deleted"
    assert_empty logged
    assert_equal 0, ProductVariantDeletionAudit.where(product_id: @product.id).count
  end

  # The audit is deliberately non-PII and its schema is fixed. If someone adds a
  # column that carries seller or buyer content, this fails.
  test "the audit stores no personal data" do
    create_variant(variant_category: @category, name: "Secret version name")

    post :update, params: @params.merge(variants: []), format: :json
    assert_response :success

    values = ProductVariantDeletionAudit.last.attributes.values.map(&:to_s).join(" ")
    assert_not_includes values, @seller.email
    assert_not_includes values, "Secret version name"
    assert_not_includes values, "New description"
    assert_not_includes values, "Versions"

    # No open-ended blob to smuggle content into later.
    assert_empty ProductVariantDeletionAudit.column_names & %w[metadata payload params_snapshot data]
  end

  # End-to-end proof that a hostile header never reaches the database lives in
  # test/integration/product_variant_deletion_audit_request_id_test.rb, because
  # ActionDispatch::RequestId is middleware and controller tests bypass the
  # middleware stack entirely (request_id is always nil here — verified, not
  # assumed).

  test "the correlation digest is stable for one request id and differs across them" do
    first = AuditCorrelationId.for("request-one")
    assert_equal first, AuditCorrelationId.for("request-one")
    assert_not_equal first, AuditCorrelationId.for("request-two")
    assert_nil AuditCorrelationId.for(nil)
    assert_nil AuditCorrelationId.for("")
  end
end

# End-to-end coverage of the editor's save contract (Product::SaveContract,
# gumroad-private#1379) through the real save endpoint.
#
# The old save read every collection as `params[:thing] || []`, so a request
# that simply didn't mention a collection — or sent it in a shape strong
# parameters dropped — was read as "delete everything in it". The contract
# changes that, behind the :product_editor_save_contract flag: leaving a
# collection out means "no changes", and deleting requires an explicit ask
# (deletion_operations) plus proof of which snapshot the client was editing
# (editor_revision).
#
# The flag-OFF tests below deliberately document the OLD deleting behaviour,
# so that if someone changes the disabled path they find out here: the flag
# has to be a pure kill switch, byte-identical to what shipped before it.
class LinksControllerSaveContractTest < ActionController::TestCase
  tests LinksController
  include LinksControllerTestHelpers

  setup do
    sign_in_seller_area!
    @product = create_product_with_pdf_file(user: @seller)
    product_file = @product.product_files.alive.first
    # The same baseline payload the editor's save sends: the product's fields
    # and its one file, with NO variants or rich_content keys. Every test
    # merges what it needs on top, so "absent collection" is the default.
    @params = {
      id: @product.unique_permalink,
      name: "sumlink",
      description: "New description",
      files: [{ id: product_file.external_id, url: product_file.url }],
    }
    @category = create_variant_category(link: @product, title: "Versions")
  end

  teardown do
    # Per-user deactivation on purpose. The Flipper store is Redis-backed and
    # shared across concurrently running test processes, so a global
    # Feature.deactivate here would switch the flag off under another process
    # mid-test. Deactivating only for this test's seller is safe: no other
    # process knows this user.
    Feature.deactivate_user(Product::SaveContract::FEATURE_NAME, @seller)
    # Remove the in-process pin (see pin_contract_flag!) so later tests read
    # the real flag again.
    Feature.singleton_class.send(:remove_method, :active?) if @contract_flag_pinned
  end

  # Pins what the save reads for THIS one flag, inside this process only,
  # while every other flag still goes through the real Feature module.
  #
  # Why pinning is needed at all: the Flipper flag store lives in a shared
  # Redis, and other test processes running at the same time flush that Redis
  # at the start of every one of their tests (test_helper/spec_helper both do
  # this to keep tests isolated). A flag this test just activated can
  # therefore vanish between the activation and the request — which made these
  # tests fail at random whenever another suite ran alongside. Verified
  # empirically: same seed, different failures per run, and a concurrent
  # rspec process was present each time.
  def pin_contract_flag!(value)
    original = Feature.method(:active?)
    Feature.define_singleton_method(:active?) do |name, actor = nil|
      name.to_sym == Product::SaveContract::FEATURE_NAME ? value : original.call(name, actor)
    end
    @contract_flag_pinned = true
  end

  # Turns the contract on for this test's seller. Called explicitly by the
  # flag-ON tests rather than in setup, so the flag-OFF tests in this same
  # class genuinely run with the flag off.
  def enable_contract!
    # The real per-user activation, exactly what a rollout does...
    Feature.activate_user(Product::SaveContract::FEATURE_NAME, @seller)
    # ...plus the in-process pin so a concurrent process flushing Redis can't
    # switch the flag off underneath this test.
    pin_contract_flag!(true)
  end

  # Pins the contract OFF for the flag-off tests, for the mirror-image reason:
  # a concurrent process could conceivably turn the flag on, and these tests
  # exist precisely to document what the disabled path does.
  def disable_contract!
    pin_contract_flag!(false)
  end

  # Makes the flag store RAISE, the way a Redis outage does. Distinct from the
  # flag being off: off is an answer, this is the absence of one.
  def break_contract_flag_store!(error: Redis::CannotConnectError.new("flag store down"))
    original = Feature.method(:active?)
    Feature.define_singleton_method(:active?) do |name, actor = nil|
      raise error if name.to_sym == Product::SaveContract::FEATURE_NAME

      original.call(name, actor)
    end
    @contract_flag_pinned = true
  end

  # The token the editor would have been handed when it loaded the product.
  # Computed fresh (after this test's factory setup) so the save's deletion
  # check sees it as current.
  def current_revision
    Product::EditorRevision.current(@product.reload)
  end

  # A content page with no title and no body. Pages like this carry no seller
  # work, so the existing rich-content deletion guard lets them be deleted
  # without a confirmation — which keeps these tests about the CONTRACT's
  # decision, not about the older guard's.
  def create_blank_page
    create_rich_content(entity: @product, description: [])
  end

  # --- flag OFF: the old behaviour must be exactly preserved -----------------

  test "flag off: a payload with no variants key still deletes every version (the old behaviour)" do
    disable_contract!
    variant = create_variant(variant_category: @category, name: "Plain version")

    post :update, params: @params, format: :json
    assert_response :success

    # This is the pre-contract behaviour being pinned, not endorsed: omitting
    # the key wipes the collection. If this test starts failing, the kill
    # switch is no longer a pure revert.
    assert_not variant.reload.alive?
  end

  test "flag off: a payload with no rich_content key still deletes existing pages (the old behaviour)" do
    disable_contract!
    page = create_blank_page

    post :update, params: @params, format: :json
    assert_response :success

    assert_not page.reload.alive?
  end

  # --- flag ON, Rule 1: absent and [] both mean "no changes" -----------------

  test "flag on: a payload with no variants key deletes nothing" do
    enable_contract!
    variant = create_variant(variant_category: @category, name: "Plain version")

    post :update, params: @params, format: :json
    assert_response :success

    assert variant.reload.alive?
  end

  test "flag on: variants sent as an empty list deletes nothing" do
    enable_contract!
    variant = create_variant(variant_category: @category, name: "Plain version")

    post :update, params: @params.merge(variants: []), format: :json
    assert_response :success

    assert variant.reload.alive?
  end

  test "flag on: a payload with no rich_content key deletes nothing" do
    enable_contract!
    # The category needs at least one version to pass product validation once
    # the contract stops the save from sweeping the (otherwise empty) category
    # away — mirroring a real product, where a category always has versions.
    create_variant(variant_category: @category, name: "Plain version")
    page = create_blank_page

    post :update, params: @params, format: :json
    assert_response :success

    assert page.reload.alive?
  end

  test "flag on: rich_content sent as an empty list deletes nothing" do
    enable_contract!
    create_variant(variant_category: @category, name: "Plain version")
    page = create_blank_page

    post :update, params: @params.merge(rich_content: []), format: :json
    assert_response :success

    assert page.reload.alive?
  end

  # --- flag ON, Rule 2: deletion only through an explicit operation ----------

  test "flag on: deleted_ids plus a fresh revision deletes exactly the named variant" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    removed = create_variant(variant_category: @category, name: "Removed")

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [removed.external_id] } },
    ), format: :json
    assert_response :success

    assert_not removed.reload.alive?
    # The sibling was not named, so the deletion must not spread to it.
    assert kept.reload.alive?
  end

  test "flag on: a named variant in a grouping the editor does not address is still deleted" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    # A product can own more than one grouping — older editors and the v2 API
    # both create them — but the current editor only ever shows and submits the
    # FIRST one. A deletion naming a version in any other grouping must still
    # happen, otherwise the save reports success and the version reappears.
    other_category = create_variant_category(link: @product, title: "Formats")
    removed = create_variant(variant_category: other_category, name: "Removed elsewhere")
    sibling = create_variant(variant_category: other_category, name: "Sibling elsewhere")

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [removed.external_id] } },
    ), format: :json
    assert_response :success

    assert_not removed.reload.alive?
    # Visiting the second grouping must not turn into a sweep of it.
    assert sibling.reload.alive?
    assert other_category.reload.alive?
    assert kept.reload.alive?
  end

  # Regression test for the intermittent red that this file's sibling test above
  # hit on main (run 30431791476): a version and a grouping can share an external
  # id, because ExternalId#external_id is ObfuscateIds.encrypt(id) of the primary
  # key with no table discriminator, and `variants` / `variant_categories` are
  # separate tables with independent auto-increment counters. Whether the two
  # counters happened to line up decided whether the save was correct, so the
  # sibling test passed or failed depending on how many rows earlier tests in the
  # shard had created. Forcing the collision makes the bug deterministic.
  test "flag on: a named version is not read as a grouping when their ids collide" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    other_category = create_variant_category(link: @product, title: "Formats")
    removed = create_variant(variant_category: other_category, name: "Removed elsewhere")
    sibling = create_variant(variant_category: other_category, name: "Sibling elsewhere")

    # Give the version the seller names for deletion the same primary key as the
    # grouping that must survive, so the two carry the same external id.
    collided_id = VariantCategory.maximum(:id).to_i + BaseVariant.maximum(:id).to_i + 1
    other_category.update_columns(id: collided_id)
    removed.update_columns(id: collided_id, variant_category_id: collided_id)
    sibling.update_columns(variant_category_id: collided_id)
    other_category = VariantCategory.find(collided_id)
    removed = Variant.find(collided_id)
    assert_equal removed.external_id, other_category.external_id,
                 "this test is only meaningful while the two ids collide"

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [removed.external_id] } },
    ), format: :json
    assert_response :success

    # The id named a version, so a version is what gets deleted.
    assert_not removed.reload.alive?
    # ...and the grouping that merely shares its id keeps everything in it.
    assert other_category.reload.alive?
    assert sibling.reload.alive?
    assert kept.reload.alive?
  end

  # The mirror image of the test above, and the reason the version lookup is
  # scoped to alive rows. A soft-deleted version can also collide with a
  # grouping's id, and a dead version is never what the editor is naming — it is
  # already gone. Reading the id as "a version" on the strength of that dead row
  # would leave the grouping the seller did name alive, with everything in it,
  # and report success.
  test "flag on: a named grouping is still swept when a soft-deleted version shares its id" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    other_category = create_variant_category(link: @product, title: "Formats")
    swept_version = create_variant(variant_category: other_category, name: "Goes with the grouping")

    # A version that was deleted in some earlier save, sitting in a grouping that
    # is still alive, whose primary key happens to equal the named grouping's.
    # Move both rows to an id past the high-water mark of BOTH tables rather than
    # reusing either one's existing id — the two auto-increment counters are
    # independent, so any id one table has issued may already be taken in the
    # other, and the collision this test needs must be the only one.
    stale = create_variant(variant_category: @category, name: "Deleted earlier")
    stale.mark_deleted!
    collided_id = VariantCategory.maximum(:id).to_i + BaseVariant.maximum(:id).to_i + 1
    stale.update_columns(id: collided_id)
    other_category.update_columns(id: collided_id)
    swept_version.update_columns(variant_category_id: collided_id)
    other_category = VariantCategory.find(collided_id)
    stale = Variant.find(collided_id)
    assert_equal other_category.external_id, stale.external_id,
                 "this test is only meaningful while the two ids collide"
    assert_not stale.alive?

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [other_category.external_id] } },
    ), format: :json
    assert_response :success

    assert_not other_category.reload.alive?
    assert kept.reload.alive?
    # Aliveness alone cannot say WHICH route deleted the grouping; the audit
    # row names it.
    audit = ProductVariantDeletionAudit.where(route: ProductVariantDeletionAudit::EDITOR_CATEGORY_SWEPT).last
    assert_not_nil audit, "the grouping should have been deleted by the named-grouping sweep"
    assert_includes audit.deleted_variant_category_external_ids, other_category.external_id
  end

  test "flag on: a second grouping is left alone when the save names no deletions" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    other_category = create_variant_category(link: @product, title: "Formats")
    untouched = create_variant(variant_category: other_category, name: "Untouched")

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
    ), format: :json
    assert_response :success

    assert untouched.reload.alive?
    assert other_category.reload.alive?
    assert_equal "Formats", other_category.reload.title
  end

  test "flag on: deleting the last version of a grouping through deleted_ids removes the grouping" do
    enable_contract!
    only_version = create_variant(variant_category: @category, name: "Only version")

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [only_version.external_id] } },
    ), format: :json
    assert_response :success

    assert_not only_version.reload.alive?
    assert_not @category.reload.alive?
  end

  test "flag on: a partial deletion keeps the grouping and its name" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    removed = create_variant(variant_category: @category, name: "Removed")

    # `variants` omitted entirely, so the save reaches the "grouping wasn't
    # submitted" route with no name in hand. It must not blank the seller's
    # grouping title as a side effect of deleting one version.
    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [removed.external_id] } },
    ), format: :json
    assert_response :success

    assert_not removed.reload.alive?
    assert kept.reload.alive?
    assert @category.reload.alive?
    assert_equal "Versions", @category.reload.title
  end

  test "flag on: deleted_ids plus a fresh revision deletes exactly the named page" do
    enable_contract!
    create_variant(variant_category: @category, name: "Plain version")
    removed = create_blank_page
    kept = create_blank_page

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { rich_content: [removed.external_id] } },
    ), format: :json
    assert_response :success

    assert_not removed.reload.alive?
    assert kept.reload.alive?
  end

  test "flag on: moving a shared page to a version deletes its source and repairs its stale embed" do
    enable_contract!
    version = create_variant(variant_category: @category, name: "Version 1")
    foreign_product = create_product(user: @seller)
    dead_foreign_file = create_product_file(link: foreign_product, deleted_at: Time.current)
    dead_foreign_embed = { "type" => "fileEmbed", "attrs" => { "id" => dead_foreign_file.external_id, "uid" => SecureRandom.uuid } }
    paragraph = { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Keep me" }] }
    source = create_product_rich_content(entity: @product, description: [paragraph])
    source.update_column(:description, [dead_foreign_embed, paragraph])
    @product.update!(has_same_rich_content_for_all_variants: true)

    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [{
        id: version.external_id,
        name: version.name,
        rich_content: [{
          id: source.external_id,
          title: "Moved page",
          description: { type: "doc", content: [dead_foreign_embed, paragraph] }
        }]
      }],
      editor_revision: current_revision,
    ), format: :json

    assert_response :success
    assert_not source.reload.alive?
    assert_equal 0, @product.reload.alive_rich_contents.count
    assert_equal [paragraph], version.reload.alive_rich_contents.sole.description
  end

  test "flag on: moving a version page to shared content deletes its source and repairs its stale embed" do
    enable_contract!
    version = create_variant(variant_category: @category, name: "Version 1")
    foreign_product = create_product(user: @seller)
    dead_foreign_file = create_product_file(link: foreign_product, deleted_at: Time.current)
    dead_foreign_embed = { "type" => "fileEmbed", "attrs" => { "id" => dead_foreign_file.external_id, "uid" => SecureRandom.uuid } }
    paragraph = { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Keep me" }] }
    source = create_rich_content(entity: version, description: [paragraph])
    source.update_column(:description, [dead_foreign_embed, paragraph])
    @product.update!(has_same_rich_content_for_all_variants: false)

    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: true,
      rich_content: [{
        id: source.external_id,
        title: "Moved page",
        description: { type: "doc", content: [dead_foreign_embed, paragraph] }
      }],
      variants: [{ id: version.external_id, name: version.name, rich_content: [] }],
      editor_revision: current_revision,
    ), format: :json

    assert_response :success
    assert_not source.reload.alive?
    assert_equal 0, version.reload.alive_rich_contents.count
    assert_equal [paragraph], @product.reload.alive_rich_contents.sole.description
  end

  test "flag on: a page ID kept in its source and destination scopes is rejected before mutation" do
    enable_contract!
    source_version = create_variant(variant_category: @category, name: "Source")
    destination_version = create_variant(variant_category: @category, name: "Destination")
    foreign_product = create_product(user: @seller)
    dead_foreign_file = create_product_file(link: foreign_product, deleted_at: Time.current)
    dead_foreign_embed = { "type" => "fileEmbed", "attrs" => { "id" => dead_foreign_file.external_id, "uid" => SecureRandom.uuid } }
    paragraph = { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Keep both" }] }
    source = create_rich_content(entity: source_version, description: [paragraph])
    source.update_column(:description, [dead_foreign_embed, paragraph])
    @product.update!(has_same_rich_content_for_all_variants: false)

    post :update, params: @params.merge(
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [
        {
          id: source_version.external_id,
          name: source_version.name,
          rich_content: [{
            id: source.external_id,
            title: "Source page",
            description: { type: "doc", content: [dead_foreign_embed, paragraph] }
          }]
        },
        {
          id: destination_version.external_id,
          name: destination_version.name,
          rich_content: [{
            id: source.external_id,
            title: "Copied page",
            description: { type: "doc", content: [dead_foreign_embed, paragraph] }
          }]
        }
      ],
      editor_revision: current_revision,
    ), format: :json

    assert_response :conflict
    assert_equal "ambiguous_rich_content_id_conflict", response.parsed_body["error_code"]
    assert_includes response.parsed_body["error_message"], "Reload the editor"
    assert source.reload.alive?
    assert_equal [dead_foreign_embed, paragraph], source.description
    assert_empty destination_version.reload.alive_rich_contents
  end

  test "flag on: an explicit clear-all plus a fresh revision deletes every variant" do
    enable_contract!
    first = create_variant(variant_category: @category, name: "First version")
    second = create_variant(variant_category: @category, name: "Second version")

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { cleared_collections: ["variants"] },
    ), format: :json
    assert_response :success

    # "Empty this collection" stays expressible — it just has to be asked for
    # in so many words instead of implied by an empty or missing list.
    assert_not first.reload.alive?
    assert_not second.reload.alive?
  end

  test "flag on: deleted_ids without an editor_revision is refused with a 409 and deletes nothing" do
    enable_contract!
    named = create_variant(variant_category: @category, name: "Named for deletion")
    sibling = create_variant(variant_category: @category, name: "Sibling")

    # The ids are supplied, but the client never says which snapshot it was
    # editing. A destructive save that can't vouch for its snapshot is refused
    # outright — silently skipping the deletion would tell the seller "saved"
    # while the rows quietly survive, so the save is rejected before any
    # mutation and the editor is handed a fresh token to retry with.
    original_name = @product.name
    post :update, params: @params.merge(
      deletion_operations: { deleted_ids: { variants: [named.external_id] } },
    ), format: :json
    assert_response :conflict

    body = response.parsed_body
    assert_equal "stale_deletion_conflict", body["error_code"]
    # And NO token: one here could only authorise the session's next save, which
    # is the same stale snapshot, so the retry it enabled would delete AND revert
    # a co-editor's changes (gumroad-private#1532). Recovery is a reload, which
    # issues a current token of its own.
    assert_not body.key?("editor_revision")

    # Nothing was written: the deletion did not happen AND the ordinary field
    # updates in the same payload were rolled back with it.
    assert named.reload.alive?
    assert sibling.reload.alive?
    assert_equal original_name, @product.reload.name
  end

  # --- flag ON: the malformed-value case the contract exists for -------------

  test "flag on: a malformed variants value deletes nothing" do
    enable_contract!
    variant = create_variant(variant_category: @category, name: "Plain version")

    # Strong parameters silently drops a value that isn't the expected list of
    # hashes, so by the time the save runs, this looks identical to not
    # sending the key at all. Before the contract, that dropped value read as
    # "delete every version" — a client bug becoming data loss.
    post :update, params: @params.merge(variants: "not-a-list"), format: :json
    assert_response :success

    assert variant.reload.alive?
  end

  # --- flag ON: ordinary saves keep working -----------------------------------

  test "flag on: a save that deletes nothing still applies normal field updates" do
    enable_contract!
    variant = create_variant(variant_category: @category, name: "Plain version")

    post :update, params: @params.merge(name: "Renamed under the contract"), format: :json
    assert_response :success

    # The contract only decides what may be DELETED; everything else about the
    # save must go through untouched.
    assert_equal "Renamed under the contract", @product.reload.name
    assert variant.reload.alive?
  end

  # --- flag ON: an explicit deletion must not widen into a sweep --------------

  test "flag on: naming one variant while the collection is omitted deletes only that variant" do
    enable_contract!
    removed = create_variant(variant_category: @category, name: "Removed")
    sibling = create_variant(variant_category: @category, name: "Sibling")

    # No `variants` key at all, but an explicit id to delete. The save reaches
    # the "this grouping wasn't submitted" route, which historically swept every
    # version in the category — turning a one-version deletion into a wipe of
    # the whole grouping. The contract has to scope it to the named id.
    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [removed.external_id] } },
    ), format: :json
    assert_response :success

    assert_not removed.reload.alive?
    assert sibling.reload.alive?
    # The grouping still holds a live version, so it must survive too.
    assert @category.reload.alive?
  end

  test "flag on: a clear-all with the collection omitted still empties the grouping" do
    enable_contract!
    first = create_variant(variant_category: @category, name: "First version")
    second = create_variant(variant_category: @category, name: "Second version")

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { cleared_collections: ["variants"] },
    ), format: :json
    assert_response :success

    assert_not first.reload.alive?
    assert_not second.reload.alive?
  end

  # --- flag ON: the revision must survive the session ------------------------

  test "flag on: the save response returns the revision for the state it committed" do
    enable_contract!
    create_variant(variant_category: @category, name: "Plain version")

    post :update, params: @params.merge(editor_revision: current_revision), format: :json
    assert_response :success

    returned = response.parsed_body["editor_revision"]
    assert returned.present?
    # It describes the post-save state, which is what the editor must echo next.
    assert_equal Product::EditorRevision.current(@product.reload), returned
  end

  test "flag on: a deletion after an ordinary save in the same session still deletes" do
    enable_contract!
    removed = create_variant(variant_category: @category, name: "Removed")
    kept = create_variant(variant_category: @category, name: "Kept")

    # First save: an ordinary edit, no deletions. It moves the product's
    # fingerprint, so the token the editor loaded with is now stale.
    post :update, params: @params.merge(
      name: "Renamed",
      editor_revision: current_revision,
    ), format: :json
    assert_response :success
    refreshed = response.parsed_body["editor_revision"]

    # Second save: the seller deletes a version without reloading the page. The
    # editor echoes the token the FIRST save handed back. Before the response
    # carried one, this deletion was silently refused as stale and the version
    # reappeared on reload.
    @controller = LinksController.new
    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: refreshed,
      deletion_operations: { deleted_ids: { variants: [removed.external_id] } },
    ), format: :json
    assert_response :success

    assert_not removed.reload.alive?
    assert kept.reload.alive?
  end

  # --- flag ON: explicit deletion across the remaining collections -----------

  test "flag on: deleted_ids plus a fresh revision deletes exactly the named file" do
    enable_contract!
    kept = @product.product_files.alive.first
    removed = create_product_file(link: @product, display_name: "Removed file")
    @product.reload

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { files: [removed.external_id] } },
    ), format: :json
    assert_response :success

    assert removed.reload.deleted?
    assert_not kept.reload.deleted?
  end

  test "flag on: deleted_ids plus a fresh revision schedules exactly the named public file" do
    enable_contract!
    removed = create_public_file(resource: @product, display_name: "Removed audio")
    kept = create_public_file(resource: @product, display_name: "Kept audio")
    @product.reload

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { public_files: [removed.public_id] } },
    ), format: :json
    assert_response :success

    assert removed.reload.scheduled_for_deletion?
    assert_not kept.reload.scheduled_for_deletion?
  end

  test "flag on: deleted_ids plus a fresh revision disconnects exactly the named integration" do
    enable_contract!
    removed = create_circle_integration
    kept = create_zoom_integration
    @product.active_integrations << [removed, kept]
    @product.reload

    # Integrations carry no external id in the editor payload — the collection
    # is keyed by provider name, so the "ids" here are provider names.
    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { integrations: ["circle"] } },
    ), format: :json
    assert_response :success

    assert_not @product.reload.active_integrations.include?(removed)
    assert @product.active_integrations.include?(kept)
  end

  # --- flag ON, Rule 1 for the files collection --------------------------------

  test "flag on: a payload with no files key deletes no files" do
    enable_contract!
    file = @product.product_files.alive.first

    post :update, params: @params.except(:files), format: :json
    assert_response :success

    assert_not file.reload.deleted?
  end

  test "flag on: files sent as an empty list deletes no files" do
    enable_contract!
    file = @product.product_files.alive.first

    post :update, params: @params.merge(files: []), format: :json
    assert_response :success

    assert_not file.reload.deleted?
  end

  # --- flag ON: malformed deletion_operations degrade to "no deletions" -------

  test "flag on: a malformed deletion_operations value deletes nothing and does not 500" do
    enable_contract!
    variant = create_variant(variant_category: @category, name: "Plain version")
    page = create_blank_page
    file = @product.product_files.alive.first

    # Every malformed shape has to read as "no explicit deletions were
    # legible" (Rule 1): a bare String, an Integer, and a deletion_operations
    # whose deleted_ids is not a hash. A fresh token rides along each time so
    # nothing but the contract's hardening stands between these payloads and
    # a wipe — a raise here would turn a client bug into a failed save, and a
    # lenient parse would turn it into data loss.
    [
      "just-a-string",
      12345,
      { deleted_ids: "not-a-hash" },
    ].each do |malformed|
      post :update, params: @params.merge(
        editor_revision: current_revision,
        deletion_operations: malformed,
      ), format: :json
      assert_response :success, "deletion_operations=#{malformed.inspect} must not fail the save"

      assert variant.reload.alive?, "deletion_operations=#{malformed.inspect} must not delete variants"
      assert page.reload.alive?, "deletion_operations=#{malformed.inspect} must not delete pages"
      assert_not file.reload.deleted?, "deletion_operations=#{malformed.inspect} must not delete files"
    end
  end

  # --- flag ON: staleness gates deletions, and only deletions -----------------

  test "flag on: a destructive save with a stale token is refused with a 409 and deletes nothing" do
    enable_contract!
    named = create_variant(variant_category: @category, name: "Named for deletion")
    sibling = create_variant(variant_category: @category, name: "Sibling")

    stale_token = current_revision
    # Another session edits the product after this session captured its token:
    # any edit to a deletable child moves the fingerprint.
    named.update!(name: "Renamed by another session")
    assert_not Product::EditorRevision.fresh?(product: @product.reload, token: stale_token)

    original_name = @product.name
    post :update, params: @params.merge(
      editor_revision: stale_token,
      deletion_operations: { deleted_ids: { variants: [named.external_id] } },
    ), format: :json
    assert_response :conflict

    body = response.parsed_body
    assert_equal "stale_deletion_conflict", body["error_code"]
    # And NO token. See gumroad-private#1532: the only thing a token here could
    # authorise is the session's next save, which is the same stale snapshot, so
    # it would delete as asked AND revert a co-editor's edits. Recovery is a
    # reload, which issues a current token of its own.
    assert_not body.key?("editor_revision")

    # Refused BEFORE any mutation: the rows survive and the ordinary field
    # updates in the same payload were rolled back with the transaction.
    assert named.reload.alive?
    assert sibling.reload.alive?
    assert_equal original_name, @product.reload.name
  end

  test "flag on: a stale clear-all is refused with a 409 and deletes nothing" do
    enable_contract!
    variant = create_variant(variant_category: @category, name: "Plain version")

    stale_token = current_revision
    variant.update!(name: "Renamed by another session")

    post :update, params: @params.merge(
      editor_revision: stale_token,
      deletion_operations: { cleared_collections: ["variants"] },
    ), format: :json
    assert_response :conflict

    assert_equal "stale_deletion_conflict", response.parsed_body["error_code"]
    assert variant.reload.alive?
  end

  # Why the editor may not adopt the 409's fresh token and resend the same
  # payload (gumroad-private#1532). Deletions are gated on the token; ordinary
  # writes are NOT, and the editor save is a full snapshot. So the "retry" is a
  # save that both applies the deletion and reverts every field the other
  # session changed in between — the seller confirmed removing Y, not
  # overwriting X. Product::StaleContentWriteGuard would be the thing to catch
  # the overwrite half, and it is observe-only by default.
  #
  # Driven end to end here rather than asserted in the client, because it is the
  # SERVER's acceptance of the retry that makes the overwrite happen; a client
  # test can only show which request was sent.
  test "flag on: the 409 refusing a stale deletion carries no fresh revision token" do
    enable_contract!
    doomed = create_variant(variant_category: @category, name: "Version Y, to delete")
    edited = create_variant(variant_category: @category, name: "Version X, as this session loaded it")
    stale_token = current_revision
    session_snapshot = @params.merge(
      variants: [
        { id: doomed.external_id, name: doomed.name },
        { id: edited.external_id, name: edited.name },
      ],
    )

    # The other session renames X. That moves the fingerprint, so this session's
    # deletion of Y is refused.
    edited.update!(name: "Version X, renamed by the other session")
    post :update, params: session_snapshot.merge(
      editor_revision: stale_token,
      deletion_operations: { deleted_ids: { variants: [doomed.external_id] } },
    ), format: :json
    assert_response :conflict

    # The refusal must not hand back a token. It could only authorise the next
    # save, which is the same stale snapshot — so the deletion would land AND
    # revert the other session's rename (gumroad-private#1532). The client
    # discards it, and the recovery is a reload, which issues its own current
    # token from ProductPresenter.
    assert_equal "stale_deletion_conflict", response.parsed_body["error_code"]
    assert_not response.parsed_body.key?("editor_revision"),
               "the 409 must not carry a token that can only authorise a stale overwrite"
    assert response.parsed_body["error_message"].present?

    # Nothing was written: the deletion is still pending and the co-editor's
    # rename survives.
    assert doomed.reload.alive?
    assert_equal "Version X, renamed by the other session", edited.reload.name
  end

  test "flag on: resending a stale snapshot with a separately-obtained fresh token deletes as asked AND reverts the other session's edit" do
    enable_contract!
    doomed = create_variant(variant_category: @category, name: "Version Y, to delete")
    edited = create_variant(variant_category: @category, name: "Version X, as this session loaded it")
    stale_token = current_revision
    session_snapshot = @params.merge(
      variants: [
        { id: doomed.external_id, name: doomed.name },
        { id: edited.external_id, name: edited.name },
      ],
    )

    # The other session renames X. That moves the fingerprint, so this session's
    # deletion of Y is refused.
    edited.update!(name: "Version X, renamed by the other session")
    post :update, params: session_snapshot.merge(
      editor_revision: stale_token,
      deletion_operations: { deleted_ids: { variants: [doomed.external_id] } },
    ), format: :json
    assert_response :conflict
    assert_equal "Version X, renamed by the other session", edited.reload.name

    # The 409 no longer supplies a token, so compute the current one directly —
    # this is what any client-side "adopt a fresh token and resend" retry
    # amounts to, however the token is obtained. The point of this test is that
    # the DANGER is in resending the stale snapshot, not in where the token came
    # from: that is why no safe retry can be built by swapping tokens alone.
    post :update, params: session_snapshot.merge(
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [doomed.external_id] } },
    ), format: :json
    assert_response :success

    assert_not doomed.reload.alive?, "the deletion the token now authorises goes through"
    assert_equal "Version X, as this session loaded it", edited.reload.name,
                 "and the same payload silently reverts the other session's rename — which is why there is no client-side retry"
  end

  test "flag on: a write-only save from a stale tab still succeeds" do
    enable_contract!
    variant = create_variant(variant_category: @category, name: "Plain version")

    stale_token = current_revision
    variant.update!(name: "Renamed by another session")
    assert_not Product::EditorRevision.fresh?(product: @product.reload, token: stale_token)

    # No deletions requested, so staleness must not block the save: a stale
    # tab fixing a typo is recoverable and has to keep working — rejecting
    # every stale save is what forced product-wide optimistic concurrency off.
    post :update, params: @params.merge(
      name: "Renamed from a stale tab",
      editor_revision: stale_token,
    ), format: :json
    assert_response :success

    assert_equal "Renamed from a stale tab", @product.reload.name
    assert variant.reload.alive?
  end

  # --- flag ON: clear-all for files --------------------------------------------

  test "flag on: an explicit clear-all plus a fresh revision empties the files collection" do
    enable_contract!
    second_file = create_product_file(link: @product, display_name: "Second file")
    @product.reload

    post :update, params: @params.except(:files).merge(
      editor_revision: current_revision,
      deletion_operations: { cleared_collections: ["files"] },
    ), format: :json
    assert_response :success

    assert_empty @product.reload.alive_product_files
    assert second_file.reload.deleted?
  end

  # --- flag store DOWN: never fall back to implicit deletion -----------------
  #
  # A raising flag lookup used to be rescued into `false`, i.e. "contract
  # disabled", which routes the save down the legacy delete-by-omission path.
  # A Redis blip therefore became a data wipe of every collection the payload
  # didn't mention. These pin that shut for all three collections.

  test "flag store down: a payload with no files key deletes no files" do
    break_contract_flag_store!
    second_file = create_product_file(link: @product, display_name: "Second file")
    @product.reload

    post :update, params: @params.except(:files), format: :json
    assert_response :success

    assert_not second_file.reload.deleted?
    assert_equal 2, @product.reload.alive_product_files.count
  end

  test "flag store down: a payload with no public_files key deletes no public files" do
    break_contract_flag_store!
    public_file = create_public_file(with_audio: true, resource: @product, display_name: "Audio 1")
    @product.reload

    # No public_files key AND a description that embeds nothing: the legacy
    # rule infers "delete" from exactly this shape.
    post :update, params: @params.merge(description: "<p>No embeds here</p>"), format: :json
    assert_response :success

    assert_nil public_file.reload.scheduled_for_deletion_at
    assert_equal 1, @product.reload.public_files.alive.count
  end

  test "flag store down: a payload with no integrations key disconnects nothing" do
    break_contract_flag_store!
    discord = create_discord_integration
    @product.active_integrations << discord
    @product.reload

    # disconnect! is an irreversible third-party call; it must not fire on a
    # save that never mentioned integrations.
    Integration.any_instance.expects(:disconnect!).never

    post :update, params: @params, format: :json
    assert_response :success

    assert_equal [discord], @product.reload.active_integrations
  end

  test "flag store down: writes still land, only implicit deletion is suppressed" do
    break_contract_flag_store!
    second_file = create_product_file(link: @product, display_name: "Second file")
    @product.reload

    post :update, params: @params.except(:files).merge(name: "Renamed while the flag store was down"), format: :json
    assert_response :success

    assert_equal "Renamed while the flag store was down", @product.reload.name
    assert_not second_file.reload.deleted?
  end

  test "flag store down: a failing error notifier does not break the save" do
    break_contract_flag_store!
    # The notifier reaches out over the network from inside a locked save. If
    # it throws, the seller's save must still succeed.
    ErrorNotifier.expects(:notify).at_least_once.raises(StandardError.new("bugsnag unreachable"))
    second_file = create_product_file(link: @product, display_name: "Second file")
    @product.reload

    post :update, params: @params.except(:files), format: :json
    assert_response :success

    assert_not second_file.reload.deleted?
  end

  # --- the integrations baseline has to move with the session ----------------

  test "flag on: the save response carries the integrations baseline for the state it committed" do
    enable_contract!
    discord = create_discord_integration
    @product.active_integrations << discord
    @product.reload

    post :update, params: @params.merge(editor_revision: current_revision), format: :json
    assert_response :success

    baseline = response.parsed_body["loaded_integrations"]
    assert_not_nil baseline, "save response must issue a refreshed integrations baseline"
    assert_equal true, baseline["discord"]
    assert_equal false, baseline["circle"]
  end

  test "flag on: a connect in one save is reflected in the baseline the next save sees" do
    enable_contract!
    # Page load: nothing connected. The presenter's baseline would be all false.
    assert_empty @product.reload.active_integrations

    # Save #1 connects discord.
    post :update, params: @params.merge(
      editor_revision: current_revision,
      integrations: { discord: { keep_inactive_members: false, integration_details: { server_id: "0", server_name: "Gaming", username: "gumbot" } } },
    ), format: :json
    assert_response :success
    assert_equal ["discord"], @product.reload.active_integrations.map(&:name)

    # The response must already say discord is connected, so the editor that
    # never reloaded can recognise a later disconnect as a removal.
    assert_equal true, response.parsed_body["loaded_integrations"]["discord"]
  end

  test "flag on: no baseline is issued while the contract is off" do
    disable_contract!

    post :update, params: @params, format: :json
    assert_response :success

    assert_nil response.parsed_body["loaded_integrations"]
    assert_nil response.parsed_body["editor_revision"]
  end

  # --- version-level integrations are explicit, owner-scoped, revision-gated --
  #
  # These joins live between a variant and an integration. They used to be
  # removed by inference from the submitted checkbox map, which meant a payload
  # that simply didn't re-check a box tore the integration down — and because
  # the join was absent from the revision fingerprint, a stale tab's teardown
  # looked perfectly fresh.

  def variant_with_integration
    variant = create_variant(variant_category: @category, name: "Pro")
    integration = create_discord_integration
    variant.active_integrations << integration
    @product.reload
    [variant, integration]
  end

  # The checkbox map for a version, as the editor sends it. `price_difference_cents`
  # is deliberately omitted: in a controller test every param arrives as a
  # String, and the updater does `option[:price] /= 100.0` on it, which raises
  # on a String. Real payloads go through the JSON body, not this path.
  def version_params(variant, integrations:)
    [{ id: variant.external_id, name: variant.name, integrations: }]
  end

  test "flag on: a version's integration survives a save that simply doesn't re-check it" do
    enable_contract!
    variant, _integration = variant_with_integration

    # No deletion named for this version: unchecking alone is not a request.
    post :update, params: @params.merge(
      editor_revision: current_revision,
      variants: version_params(variant, integrations: { "discord" => false }),
    ), format: :json
    assert_response :success

    assert_equal 1, variant.reload.active_integrations.count
  end

  test "flag on: an explicitly named version integration is disconnected" do
    enable_contract!
    variant, _integration = variant_with_integration

    post :update, params: @params.merge(
      editor_revision: current_revision,
      variants: version_params(variant, integrations: { "discord" => false }),
      deletion_operations: { variant_deleted_ids: { variant.external_id => { integrations: ["discord"] } } },
    ), format: :json
    assert_response :success

    assert_empty variant.reload.active_integrations
  end

  test "flag on: naming a version's integration leaves the same integration on a sibling version" do
    enable_contract!
    variant, integration = variant_with_integration
    sibling = create_variant(variant_category: @category, name: "Basic")
    sibling.active_integrations << integration
    @product.reload

    post :update, params: @params.merge(
      editor_revision: current_revision,
      variants: version_params(variant, integrations: { "discord" => false }) +
                version_params(sibling, integrations: { "discord" => true }),
      deletion_operations: { variant_deleted_ids: { variant.external_id => { integrations: ["discord"] } } },
    ), format: :json
    assert_response :success

    assert_empty variant.reload.active_integrations
    assert_equal 1, sibling.reload.active_integrations.count, "the sibling version's join must survive"
  end

  test "flag on: a stale tab cannot disconnect a version integration another tab just enabled" do
    enable_contract!
    variant = create_variant(variant_category: @category, name: "Pro")
    @product.reload
    # Tab A loaded here, before the integration existed.
    stale_token = current_revision

    # Tab B enables the integration on that version.
    integration = create_discord_integration
    variant.active_integrations << integration
    @product.reload

    # The join alone must move the fingerprint, or tab A's teardown looks fresh.
    assert_not Product::EditorRevision.fresh?(product: @product.reload, token: stale_token),
               "enabling a version integration must invalidate an older token"

    post :update, params: @params.merge(
      editor_revision: stale_token,
      variants: version_params(variant, integrations: { "discord" => false }),
      deletion_operations: { variant_deleted_ids: { variant.external_id => { integrations: ["discord"] } } },
    ), format: :json

    assert_response :conflict
    assert_equal "stale_deletion_conflict", response.parsed_body["error_code"]
    assert_equal 1, variant.reload.active_integrations.count, "the stale save must not have disconnected anything"
  end

  test "flag on: omitting the integrations key for a version removes nothing" do
    enable_contract!
    variant, _integration = variant_with_integration

    post :update, params: @params.merge(
      editor_revision: current_revision,
      variants: [{ id: variant.external_id, name: variant.name }],
    ), format: :json
    assert_response :success

    assert_equal 1, variant.reload.active_integrations.count
  end

  test "flag on: an empty integrations map for a version removes nothing" do
    enable_contract!
    variant, _integration = variant_with_integration

    post :update, params: @params.merge(
      editor_revision: current_revision,
      variants: version_params(variant, integrations: {}),
    ), format: :json
    assert_response :success

    assert_equal 1, variant.reload.active_integrations.count
  end

  test "flag on: an explicitly named integration on a version in a later grouping is disconnected" do
    enable_contract!
    # A legacy product with two alive variant groupings. The editor only ever
    # renders and submits the first one, so a version in the second is never
    # visited by the save — but the payload can still name it for deletion.
    other_category = create_variant_category(link: @product, title: "Sizes")
    variant = create_variant(variant_category: other_category, name: "Large")
    integration = create_discord_integration
    variant.active_integrations << integration
    @product.reload

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { variant_deleted_ids: { variant.external_id => { integrations: ["discord"] } } },
    ), format: :json
    assert_response :success

    assert_empty variant.reload.active_integrations,
                 "a named integration on a version outside the first grouping must actually be disconnected"
  end

  test "flag on: a version-scoped deletion in a later grouping leaves everything else in that grouping alone" do
    enable_contract!
    other_category = create_variant_category(link: @product, title: "Sizes")
    named = create_variant(variant_category: other_category, name: "Large")
    untouched = create_variant(variant_category: other_category, name: "Small")
    integration = create_discord_integration
    named.active_integrations << integration
    untouched.active_integrations << integration
    @product.reload

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { variant_deleted_ids: { named.external_id => { integrations: ["discord"] } } },
    ), format: :json
    assert_response :success

    assert_empty named.reload.active_integrations
    assert_equal 1, untouched.reload.active_integrations.count,
                 "the unnamed sibling's join must survive"
    assert untouched.reload.alive?, "visiting the grouping must not delete versions nobody named"
    assert_equal "Sizes", other_category.reload.title, "the grouping's name must survive"
    assert other_category.alive?, "the grouping itself must survive"
  end

  test "flag on: a stale tab cannot disconnect an integration on a version in a later grouping" do
    enable_contract!
    other_category = create_variant_category(link: @product, title: "Sizes")
    variant = create_variant(variant_category: other_category, name: "Large")
    @product.reload
    stale_token = current_revision

    integration = create_discord_integration
    variant.active_integrations << integration
    @product.reload

    post :update, params: @params.merge(
      editor_revision: stale_token,
      deletion_operations: { variant_deleted_ids: { variant.external_id => { integrations: ["discord"] } } },
    ), format: :json

    assert_response :conflict
    assert_equal 1, variant.reload.active_integrations.count,
                 "a stale save must not reach a version in another grouping either"
  end

  test "flag on: malformed version-scoped deletion operations delete nothing and do not 500" do
    enable_contract!
    variant, _integration = variant_with_integration
    token = current_revision

    [
      "not-a-hash",
      { variant.external_id => "not-a-hash" },
      { variant.external_id => { integrations: "discord" } },       # string, not a list
      { variant.external_id => { integrations: [{ evil: 1 }] } },   # non-string members
      { variant.external_id => { not_a_collection: ["discord"] } }, # unknown collection
    ].each do |malformed|
      post :update, params: @params.merge(
        editor_revision: token,
        variants: version_params(variant, integrations: { "discord" => false }),
        deletion_operations: { variant_deleted_ids: malformed },
      ), format: :json

      assert_response :success, "malformed payload #{malformed.inspect} should not break the save"
      assert_equal 1, variant.reload.active_integrations.count,
                   "malformed payload #{malformed.inspect} must not delete anything"
    end
  end

  # --- two versions created in one save, then a content edit in the same tab --
  #
  # gumroad-private#1379. The first save creates both versions server-side; the
  # editor adopts their canonical ids and the fresh token. The second save is an
  # ordinary content edit that does not mention versions at all. Neither version
  # may be dropped from the product, and the shared-content flag must not be
  # flipped as a side effect of the second save.
  test "flag on: two versions created in one save both survive a later content edit in the same session" do
    enable_contract!
    shared_content_before = @product.reload.has_same_rich_content_for_all_variants?

    # Save #1: create two versions at once (no ids — they don't exist yet).
    post :update, params: @params.merge(
      editor_revision: current_revision,
      variants: [{ id: nil, name: "First version" }, { id: nil, name: "Second version" }],
    ), format: :json
    assert_response :success

    created = @product.reload.alive_variants.order(:id).to_a
    assert_equal ["First version", "Second version"], created.map(&:name).sort
    # The editor adopts the token this save returned; it never reloads the page.
    adopted_token = response.parsed_body["editor_revision"]
    assert_not_nil adopted_token, "the save must hand back a token for the state it committed"

    # Save #2: a plain content edit in the same session. It says nothing about
    # versions, so under Rule 1 nothing about them may change.
    #
    # Note this second save exercises the controller's `variants.any?`
    # short-circuit rather than the contract: with no variants key the updater
    # is never reached at all. That is the real protection for an absent
    # collection here, and the assertions below hold it in place.
    post :update, params: @params.merge(
      editor_revision: adopted_token,
      description: "<p>Edited in the same session, without reloading</p>",
    ), format: :json
    assert_response :success

    survivors = @product.reload.alive_variants.order(:id).to_a
    assert_equal created.map(&:id).sort, survivors.map(&:id).sort,
                 "both versions created in the first save must survive the second"
    assert_equal shared_content_before, @product.reload.has_same_rich_content_for_all_variants?,
                 "the shared-content flag must not change as a side effect of a content edit"
  end

  # The same session, but the second save DOES carry a variants key — the shape
  # the editor actually sends when the seller edits content while versions are
  # on screen. This one reaches the updater, so it is the case where the
  # contract, not the controller's short-circuit, has to keep both versions.
  test "flag on: a same-session content edit that resubmits one version does not drop the other" do
    enable_contract!

    post :update, params: @params.merge(
      editor_revision: current_revision,
      variants: [{ id: nil, name: "First version" }, { id: nil, name: "Second version" }],
    ), format: :json
    assert_response :success

    created = @product.reload.alive_variants.order(:id).to_a
    assert_equal 2, created.count
    adopted_token = response.parsed_body["editor_revision"]
    first, second = created

    # The editor re-submits only the version being edited, and names no
    # deletions. The other version must not be swept for being absent.
    post :update, params: @params.merge(
      editor_revision: adopted_token,
      variants: [{ id: first.external_id, name: "First version renamed" }],
    ), format: :json
    assert_response :success

    assert_equal "First version renamed", first.reload.name
    assert first.reload.alive?, "the resubmitted version must survive"
    assert second.reload.alive?, "the version merely absent from the payload must survive"
  end

  # Reaching a version in a later grouping means visiting every other alive
  # grouping, including ones that hold nothing. Such a grouping cannot survive
  # the visit — an alive grouping with no alive versions makes the product
  # invalid — but nothing of the seller's goes with it, so it must not be filed
  # as an omission-driven deletion. That count is the number the save-contract
  # rollout watches, and a cleanup that removed nothing would inflate it.
  test "flag on: a pass-through empty grouping is audited as a cleanup, not an omission" do
    enable_contract!
    empty_category = create_variant_category(link: @product, title: "Sizes")
    other_category = create_variant_category(link: @product, title: "Formats")
    variant = create_variant(variant_category: other_category, name: "Large")
    integration = create_discord_integration
    variant.active_integrations << integration
    @product.reload

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { variant_deleted_ids: { variant.external_id => { integrations: ["discord"] } } },
    ), format: :json
    assert_response :success

    assert_empty variant.reload.active_integrations, "the named integration must still be disconnected"
    assert variant.reload.alive?, "no version may be removed by the pass-through"

    cleanup = ProductVariantDeletionAudit.where(product_id: @product.id)
                                         .find { Array(_1.deleted_variant_category_external_ids).include?(empty_category.external_id) }
    assert_not_nil cleanup, "removing the empty grouping must still be recorded"
    assert_equal ProductVariantDeletionAudit::EMPTY_GROUPING_CLEANUP, cleanup.intent_source
    assert_empty cleanup.deleted_variant_external_ids, "the cleanup removed no versions"

    omissions = ProductVariantDeletionAudit.where(product_id: @product.id,
                                                  intent_source: ProductVariantDeletionAudit::PAYLOAD_OMISSION)
    assert_empty omissions, "a pass-through must not register as an omission-driven deletion"
  end

  # Pins WHY Product::EditorRevision does not fingerprint skus_enabled or SKU
  # rows. Product::SkusUpdaterService is the only code that deletes SKUs;
  # VariantsUpdaterService is its only caller and guards it with
  # `if skus_enabled`; and #update assigns skus_enabled = false before that
  # point. So this endpoint cannot delete a SKU, and the revision token
  # deliberately ignores SKU state rather than invalidating over something no
  # deletion here can act on.
  #
  # If a future change makes SKUs reachable from the editor save, this test goes
  # red and the revision token needs to cover them again.
  test "the editor save cannot delete a SKU, even with skus_enabled persisted true" do
    @product.update_attribute(:skus_enabled, true)
    sku = Sku.create!(link: @product, name: "SKU reachability probe", price_difference_cents: 0)
    variant = create_variant(variant_category: @category, name: "Alpha")

    assert @product.reload.skus_enabled?, "precondition: the column really is true before the save"
    assert sku.reload.alive?, "precondition: the SKU is alive before the save"

    observed_flag = []
    Product::VariantsUpdaterService.class_eval do
      alias_method :__orig_perform_sku_probe, :perform
      define_method(:perform) do
        observed_flag << product.skus_enabled?
        __orig_perform_sku_probe
      end
    end

    Thread.current[:__sku_updater_ran] = false
    Product::SkusUpdaterService.singleton_class.class_eval do
      alias_method :__orig_new_sku_probe, :new
      define_method(:new) do |**kwargs|
        Thread.current[:__sku_updater_ran] = true
        __orig_new_sku_probe(**kwargs)
      end
    end

    begin
      put :update, params: @params.merge(variants: [{ id: variant.external_id, name: "Alpha" }]), as: :json
      assert_response :success

      assert_equal [false], observed_flag,
                   "the save must zero skus_enabled before VariantsUpdaterService runs"
      assert_not Thread.current[:__sku_updater_ran],
                 "SkusUpdaterService must never be constructed from the editor save"
      assert sku.reload.alive?, "the editor save must not delete a SKU"
    ensure
      Product::VariantsUpdaterService.class_eval do
        alias_method :perform, :__orig_perform_sku_probe
        remove_method :__orig_perform_sku_probe
      end
      Product::SkusUpdaterService.singleton_class.class_eval do
        alias_method :new, :__orig_new_sku_probe
        remove_method :__orig_new_sku_probe
      end
    end
  end

  # --- a 200 that applied fewer deletions than it named (gumroad-private#1508)
  #
  # The reported failure was a save that returned 200, deleted nothing, and
  # left no audit row — indistinguishable from success. Under the contract that
  # shape can only come from a payload whose stated deletions did not take
  # effect, so the server compares what was named against what survived.

  test "flag on: a save whose named variant deletion did not take effect is reported" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    survivor = create_variant(variant_category: @category, name: "Should have gone")

    # Make the deletion a no-op without changing the response: the contract
    # still reports the id as requested, the variants updater never removes it.
    Product::VariantCategoryUpdaterService.any_instance.stubs(:perform)

    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [survivor.external_id] } },
    ), format: :json
    assert_response :success

    assert survivor.reload.alive?, "precondition: the stubbed updater really did leave the version alive"
    report = notified.find { |message, _| message == "Product save applied fewer deletions than it named" }
    assert report, "expected the unapplied-deletion report (got: #{notified.inspect})"
    assert_equal [survivor.external_id], report.last[:surviving_variant_ids]
    assert_equal [survivor.external_id], report.last[:requested_variant_ids]
  end

  test "flag on: a save whose named deletions all took effect reports nothing" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    removed = create_variant(variant_category: @category, name: "Removed")

    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [removed.external_id] } },
    ), format: :json
    assert_response :success

    assert_not removed.reload.alive?
    assert_empty notified.select { |message, _| message == "Product save applied fewer deletions than it named" }
  end

  test "flag on: a save that names no deletions never runs the discrepancy check" do
    enable_contract!
    create_variant(variant_category: @category, name: "Kept")

    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params, format: :json
    assert_response :success

    assert_empty notified.select { |message, _| message == "Product save applied fewer deletions than it named" }
  end

  test "flag on: an unapplied page deletion is reported even when its grouping is gone" do
    enable_contract!
    create_variant(variant_category: @category, name: "Kept")
    # Deleting a grouping does not soft-delete the versions in it, so a page
    # under one is alive and unreachable through the product's live versions.
    # The grouping's state at commit is all that matters here, so deleting it
    # up front stands in for a save that removes it and the page together.
    other_category = create_variant_category(link: @product, title: "Formats")
    orphaned_variant = create_variant(variant_category: other_category, name: "Under a dead grouping")
    survivor = create_rich_content(entity: orphaned_variant, description: [])
    other_category.mark_deleted!

    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { rich_content: [survivor.external_id] } },
    ), format: :json
    assert_response :success

    assert survivor.reload.alive?, "precondition: the named page really did survive the save"
    report = notified.find { |message, _| message == "Product save applied fewer deletions than it named" }
    assert report, "expected the unapplied-deletion report (got: #{notified.inspect})"
    assert_equal [survivor.external_id], report.last[:surviving_rich_content_ids]
  end

  test "flag on: a page whose version this save deleted is not reported as surviving" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    removed = create_variant(variant_category: @category, name: "Removed")
    # Version deletion hands the page to DeleteProductRichContentWorker, so the
    # row is still alive when the check runs. That is the deletion working, not
    # a discrepancy.
    page = create_rich_content(entity: removed, description: [])

    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      deletion_operations: { deleted_ids: { variants: [removed.external_id], rich_content: [page.external_id] } },
    ), format: :json
    assert_response :success

    assert_not removed.reload.alive?
    assert_empty notified.select { |message, _| message == "Product save applied fewer deletions than it named" }
  end

  # --- the happy path leaves an audit row (gumroad-private#1508, criterion 4)
  #
  # The reported save returned 200, left all three versions alive, and wrote
  # zero ProductVariantDeletionAudit rows. The absent audit row is what made it
  # indistinguishable from success, so asserting `deleted_at` alone would still
  # pass against that bug: a save that deletes nothing and audits nothing looks
  # the same as one that never named a deletion. Assert both halves.

  test "flag on: a confirmed version removal deletes the row AND writes an audit row" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    removed = create_variant(variant_category: @category, name: "Removed")

    assert_difference -> { ProductVariantDeletionAudit.count }, 1 do
      post :update, params: @params.merge(
        variants: [{ id: kept.external_id, name: "Kept" }],
        editor_revision: current_revision,
        confirmed_removed_variant_ids: [removed.external_id],
        deletion_operations: { deleted_ids: { variants: [removed.external_id] } },
      ), format: :json
      assert_response :success
    end

    assert_not removed.reload.alive?, "the confirmed version must actually be gone"
    assert kept.reload.alive?, "the version the payload kept must survive"

    audit = ProductVariantDeletionAudit.where(product_id: @product.id).last
    assert_equal [removed.external_id], audit.deleted_variant_external_ids
    assert_equal @product.id, audit.product_id
    # Confirmed in the payload, so the audit must not read as an omission — that
    # is the distinction the table exists to make.
    assert_equal ProductVariantDeletionAudit::CONFIRMED_IDS, audit.intent_source
  end

  # --- a save that confirmed a removal it never named (gumroad-private#1508)
  #
  # The report above is gated on requested_deletion?, so it is blind to the
  # shape actually reported: a payload naming NO deletion. The confirmed ids
  # are the witness, because the editor derives both lists from the same
  # in-session state.

  test "flag on: a confirmed removal the deletion operations never named is reported" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    survivor = create_variant(variant_category: @category, name: "Confirmed but unnamed")

    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      confirmed_removed_variant_ids: [survivor.external_id],
      deletion_operations: { deleted_ids: {} },
    ), format: :json
    assert_response :success

    assert survivor.reload.alive?, "precondition: nothing was named, so the row must still be alive"
    report = notified.find { |message, _| message == "Product save confirmed a removal its deletion operations never named" }
    assert report, "expected the unstated-confirmed-removal report (got: #{notified.inspect})"
    assert_equal [survivor.external_id], report.last[:unstated_variant_ids]
    assert_empty report.last[:named_variant_ids]
  end

  test "flag on: a confirmed removal the payload did name reports nothing" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    removed = create_variant(variant_category: @category, name: "Removed")

    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      confirmed_removed_variant_ids: [removed.external_id],
      deletion_operations: { deleted_ids: { variants: [removed.external_id] } },
    ), format: :json
    assert_response :success

    assert_not removed.reload.alive?
    assert_empty notified.select { |message, _| message == "Product save confirmed a removal its deletion operations never named" }
  end

  # A resent payload naming an already-deleted row is not a live defect: the
  # editor clears its confirmed ids after a successful save, so reporting this
  # would be noise on every duplicate submit.
  test "flag on: a confirmed id whose row is already deleted is not reported" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    already_gone = create_variant(variant_category: @category, name: "Already gone")
    already_gone.mark_deleted!

    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      editor_revision: current_revision,
      confirmed_removed_variant_ids: [already_gone.external_id],
      deletion_operations: { deleted_ids: {} },
    ), format: :json
    assert_response :success

    assert_empty notified.select { |message, _| message == "Product save confirmed a removal its deletion operations never named" }
  end

  # A tab predating the contract sends neither key, so its confirmed ids carry
  # no contradiction — it has no way to state a deletion.
  test "flag on: a payload with no contract keys is not reported" do
    enable_contract!
    kept = create_variant(variant_category: @category, name: "Kept")
    survivor = create_variant(variant_category: @category, name: "Survivor")

    notified = []
    ErrorNotifier.stubs(:notify).with { |message, **context| notified << [message, context]; true }

    post :update, params: @params.merge(
      variants: [{ id: kept.external_id, name: "Kept" }],
      confirmed_removed_variant_ids: [survivor.external_id],
    ), format: :json
    assert_response :success

    assert_empty notified.select { |message, _| message == "Product save confirmed a removal its deletion operations never named" }
  end
end
