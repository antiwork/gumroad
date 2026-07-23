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

  test "POST create does not enable community chat by default when communities feature is enabled" do
    Rails.cache.clear
    Feature.activate_user(:communities, @seller)

    post :create, params: { link: { price_cents: 100, name: "test link" } }

    assert_redirected_to edit_link_path(Link.last)
    product = @seller.links.last
    assert_equal false, product.community_chat_enabled?
    assert_nil product.active_community
  end

  test "POST create does not enable community chat when communities feature is disabled" do
    Rails.cache.clear
    Feature.deactivate_user(:communities, @seller)

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

  test "PUT update allows a collaborator to access" do
    assert_collaborator_can_access(:put, :update, product: @product, params: @params, status: 204)
  end

  test "PUT update returns the existing validation error when suggested price is set but the default price record is missing" do
    @product.prices.destroy_all
    @product.update_column(:customizable_price, true)

    put :update, params: @params.merge(suggested_price: "10", customizable_price: true), as: :json

    assert_response :unprocessable_entity
    assert_equal "Default price cents can't be blank", response.parsed_body["error_message"]
    assert_nil @product.reload.suggested_price_cents
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

  # --- coffee products --------------------------------------------------------

  test "PUT update sets suggested_price_cents to the maximum price_difference_cents of variants for coffee products" do
    coffee_product = create_coffee_product
    sign_in coffee_product.user

    post :update, params: {
      id: coffee_product.unique_permalink,
      variants: [{ price_difference_cents: 300 }, { price_difference_cents: 500 }, { price_difference_cents: 100 }]
    }, as: :json

    assert_response :success
    assert_equal 500, coffee_product.reload.suggested_price_cents
  end

  test "PUT update ignores variants with a nil price_difference_cents when computing suggested_price_cents for coffee products" do
    coffee_product = create_coffee_product
    sign_in coffee_product.user

    post :update, params: {
      id: coffee_product.unique_permalink,
      variants: [{ price_difference_cents: 10000 }, { price_difference_cents: nil }]
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
    post :update, params: { id: @product.unique_permalink, variants: }, as: :json

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
    create_variant(variant_category: category, name: "small", price_difference_cents: 200, max_purchase_count: 100)

    assert_difference -> { @product.reload.variant_categories_alive.count }, -1 do
      post :update, params: { id: @product.unique_permalink, variants: [] }, as: :json
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

    assert_difference -> { product.reload.alive_rich_contents.count }, -4 do
      assert_no_difference -> { product.rich_contents.count } do
        post :update, params: { id: product.unique_permalink, rich_content: [] }, format: :json
      end
    end
  end

  # --- product_files_archive generation ---------------------------------------

  test "PUT update deletes all product-level archives when switching to variant-level archives" do
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
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
          variants: [{ name: "Version 1", rich_content: [{ title: "Version 1 - Page 1", description: { type: "doc", content: description } }] }],
          files:,
        }, format: :json
      end
    end
  end

  test "PUT update deletes all variant-level archives when switching to product-level archives" do
    category = create_variant_category(link: @product, title: "Versions")
    version1 = create_variant(variant_category: category, name: "Version 1")

    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
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
          rich_content: [{ id: nil, title: "Version 1 - Page 1", description: { type: "doc", content: version1_rich_content_description } }],
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
    file1 = create_product_file(display_name: "File 1")
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
    file1 = create_product_file(display_name: "File 1")
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
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
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
        rich_content: [{ id: nil, title: "New page title", description: { type: "doc", content: [folder1] } }],
        files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }],
      }, format: :json
    end
    assert_equal true, folder1_archive.reload.alive?
    assert_equal 1, @product.product_files_archives.folder_archives.alive.count
    assert_equal "New page title", @product.alive_rich_contents.first["title"]
    assert_equal "New product name", @product.reload.name
  end

  test "PUT update does not generate an updated folder archive when top-level files are modified" do
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
    file3 = create_product_file(display_name: "File 2")
    file4 = create_product_file(display_name: "File 2")
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
    file5 = create_product_file(display_name: "File 3")
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
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
    file3 = create_product_file(display_name: "File 3")
    file4 = create_product_file(display_name: "File 4")
    file5 = create_product_file(display_name: "File 5")
    file6 = create_product_file(display_name: "File 6")
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
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
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
        files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }, { id: file3_id, display_name: "File 3", url: create_product_file(display_name: "File 3").url }, { id: file4_id, display_name: "File 4", url: create_product_file(display_name: "File 4").url }],
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
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
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
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
    file3 = create_product_file(display_name: "File 3")
    file4 = create_product_file(display_name: "File 4")
    file5 = create_product_file(display_name: "File 5")
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
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
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
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
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
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
    file3 = create_product_file(display_name: "File 3")
    file4 = create_product_file(display_name: "File 4")
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

    file5 = create_product_file(display_name: "File 5")
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

    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
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
    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
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

  test "PUT update enables community chat when requested and communities feature is enabled" do
    Feature.activate_user(:communities, @seller)

    post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json

    assert_response :success
    assert_equal true, @product.reload.community_chat_enabled?
    assert @product.reload.active_community.present?
  end

  test "PUT update disables community chat when requested and communities feature is enabled" do
    Feature.activate_user(:communities, @seller)
    @product.update!(community_chat_enabled: true)

    post :update, params: { id: @product.unique_permalink, community_chat_enabled: false }, as: :json

    assert_response :success
    assert_equal false, @product.reload.community_chat_enabled?
    assert_nil @product.reload.active_community
  end

  test "PUT update does not enable community chat for coffee products" do
    Feature.activate_user(:communities, @seller)
    @seller.update!(created_at: (User::MIN_AGE_FOR_SERVICE_PRODUCTS + 1.day).ago)
    product = create_product(user: @seller, native_type: Link::NATIVE_TYPE_COFFEE, price_cents: 1000)

    post :update, params: { id: product.unique_permalink, community_chat_enabled: true, variants: [{ price_difference_cents: 1000 }] }, as: :json
    assert_response :success
    assert_equal false, product.reload.community_chat_enabled?
    assert_nil product.reload.active_community
  end

  test "PUT update does not enable community chat for bundle products" do
    Feature.activate_user(:communities, @seller)
    @product.update!(native_type: Link::NATIVE_TYPE_BUNDLE)

    post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json
    assert_response :success
    assert_equal false, @product.reload.community_chat_enabled?
    assert_nil @product.reload.active_community
  end

  test "PUT update reactivates existing community when enabling chat" do
    Feature.activate_user(:communities, @seller)
    community = create_community(resource: @product, seller: @seller)
    community.mark_deleted!
    @product.update!(community_chat_enabled: false)

    post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json

    assert_response :success
    assert_equal true, @product.reload.community_chat_enabled?
    assert community.reload.alive?
  end

  test "PUT update does not enable community chat when communities feature is disabled" do
    Feature.deactivate_user(:communities, @seller)

    post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json

    assert_response :success
    assert_equal false, @product.reload.community_chat_enabled?
    assert_nil @product.reload.active_community
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

    get :show, params: { id: product.to_param, wanted: "true", price: "9.99" }

    assert_response :redirect
    query_params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert(Array(query_params["price"]).all? { |value| value == "999" })
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

  test "GET show redirects to a product defined by legacy permalink" do
    setup_legacy_products
    @request.host = DOMAIN

    get :show, params: { id: "custom" }

    assert_redirected_to @product_with_legacy_mapping.long_url
  end

  test "GET show redirects to an earlier product matched by permalink when legacy permalink points to a deleted product" do
    setup_legacy_products
    @request.host = DOMAIN
    @product_with_legacy_mapping.mark_deleted!

    get :show, params: { id: "custom" }

    assert_redirected_to @other_product.long_url
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
    }
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
