# frozen_string_literal: true

require "test_helper"

# Ported from spec/controllers/bundles/product_controller_spec.rb (#5801).
# First controller port in the Minitest suite: uses ActionController::TestCase
# with Devise's controller helpers for sign-in, and reads Inertia responses as
# JSON (the `X-Inertia: true` request header makes inertia_rails render the
# page object as JSON instead of the HTML shell) — the Minitest equivalent of
# the `inertia_rails/rspec` matchers the spec used.
class Bundles::ProductControllerTest < ActionController::TestCase
  tests Bundles::ProductController

  setup do
    @seller = users(:named_seller)
    # Mirror the RSpec setup, where the seller factory carried the
    # :eligible_for_service_products trait (needed to create the commission
    # products some tests bundle) and User's creation callbacks ran:
    # - refund_policy_enabled comes from the seller_refund_policy_new_users_enabled
    #   feature in the factory's before_create; fixtures bypass callbacks, so the
    #   flag must be set here or the controller takes the product-level refund
    #   policy branch that the "happy path" assertions expect to be skipped.
    # - the account-level SellerRefundPolicy row is created by an after_create;
    #   BundlePresenter#edit_product_props reads it unconditionally.
    @seller.update_column(:created_at, User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day)
    @seller.update!(refund_policy_enabled: true)
    @seller.create_refund_policy! if @seller.refund_policy.blank?

    @bundle = create_bundle(user: @seller, price_cents: 2000)

    # Sign in as a team admin for the seller, like the RSpec shared context
    # "with user signed in as admin for seller": logged_in_user is a different
    # user than current_seller.
    cookies.encrypted[:current_seller_id] = @seller.id
    sign_in users(:admin_for_named_seller)
  end

  # A commission product can't be part of an installment-plan-eligible bundle;
  # several tests use one to make the bundle ineligible.
  def create_commission_product(user: @seller)
    Link.create!(user:, name: "Commission", price_cents: 200, native_type: Link::NATIVE_TYPE_COMMISSION)
  end

  def inertia_page
    assert_equal "application/json", response.media_type
    response.parsed_body
  end

  # The full update payload the spec sent, minus the covers (tests that need
  # asset previews create them and merge the covers key themselves).
  def bundle_params
    {
      bundle_id: @bundle.external_id,
      name: "New name",
      description: "New description",
      custom_permalink: "new-permalink",
      price_cents: 1000,
      customizable_price: true,
      suggested_price_cents: 2000,
      custom_button_text_option: "buy_this_prompt",
      custom_summary: "Custom summary",
      custom_attributes: [{ "name" => "Detail 1", "value" => "Value 1" }],
      max_purchase_count: 10,
      quantity_enabled: true,
      should_show_sales_count: true,
      is_epublication: true,
      product_refund_policy_enabled: true,
      refund_policy: {
        title: "New refund policy",
        fine_print: "I really hate being small",
      },
    }
  end

  # --- GET edit ---------------------------------------------------------------

  test "GET edit renders the Bundles/Product/Edit Inertia component with expected props" do
    @request.headers["X-Inertia"] = "true"
    get :edit, params: { bundle_id: @bundle.external_id }

    assert_response :success
    page = inertia_page
    assert_equal "Bundles/Product/Edit", page["component"]
    assert_equal @bundle.name, @controller.send(:page_title)

    props = page["props"]
    assert_equal @bundle.external_id, props["id"]
    assert_equal @bundle.unique_permalink, props["unique_permalink"]
    assert_equal @bundle.price_currency_type, props["currency_type"]
    assert_equal @bundle.name, props["bundle"]["name"]
    assert_equal @bundle.price_cents, props["bundle"]["price_cents"]
    assert_kind_of Array, props["bundle"]["products"]
    assert_includes props.keys, "ratings"
    assert_includes props.keys, "refund_policies"
  end

  test "GET edit raises RecordNotFound when the bundle doesn't exist" do
    assert_raises(ActiveRecord::RecordNotFound) do
      get :edit, params: { bundle_id: "" }
    end
  end

  # --- PUT update -------------------------------------------------------------

  test "PUT update calls authorize with the LinkPolicy for the bundle" do
    calls = []
    LinkPolicy.stubs(:new).with do |context, record|
      calls << [context, record]
      true
    end.returns(stub("LinkPolicy", update?: false))

    put :update, params: { bundle_id: @bundle.external_id }

    assert calls.any? { |context, record| context == @controller.send(:pundit_user) && record == @bundle },
           "Expected LinkPolicy to be built via `authorize` with the controller's pundit_user and the bundle"
  end

  test "updates the bundle and redirects back for published bundle" do
    asset_previews = [create_asset_preview(link: @bundle), create_asset_preview(link: @bundle)]

    put :update, params: bundle_params.merge(covers: [asset_previews.second.guid, asset_previews.first.guid])
    @bundle.reload

    assert_equal "New name", @bundle.name
    assert_equal "New description", @bundle.description
    assert_equal "new-permalink", @bundle.custom_permalink
    assert_equal 1000, @bundle.price_cents
    assert @bundle.customizable_price?
    assert_equal 2000, @bundle.suggested_price_cents
    assert_equal "buy_this_prompt", @bundle.custom_button_text_option
    assert_equal [{ "name" => "Detail 1", "value" => "Value 1" }], @bundle.custom_attributes
    assert_equal "Custom summary", @bundle.custom_summary
    assert_equal [asset_previews.second.id, asset_previews.first.id], @bundle.display_asset_previews.map(&:id)
    assert_equal 10, @bundle.max_purchase_count
    assert @bundle.quantity_enabled
    assert @bundle.should_show_sales_count
    assert @bundle.is_epublication
    # The seller has an account-level refund policy, so the product-level
    # refund policy params are ignored.
    assert_not @bundle.product_refund_policy_enabled
    assert_nil @bundle.product_refund_policy

    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  end

  test "redirects to content page after saving when bundle is unpublished" do
    @bundle.update!(draft: true, purchase_disabled_at: Time.current)

    put :update, params: bundle_params
    assert_redirected_to edit_bundle_content_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  end

  # --- installment plans (customizable_price off so plans are allowed) --------

  def installment_bundle_params
    bundle_params.merge(customizable_price: false)
  end

  test "creates a new installment plan when the bundle has none" do
    assert_difference -> { ProductInstallmentPlan.alive.count }, 1 do
      put :update, params: installment_bundle_params.merge(installment_plan: { number_of_installments: 3 })
    end

    plan = @bundle.reload.installment_plan
    assert_equal 3, plan.number_of_installments
    assert_equal "monthly", plan.recurrence
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  end

  test "does not allow creating installment plan when bundle has ineligible products" do
    BundleProduct.create!(bundle: @bundle, product: create_commission_product)

    assert_no_changes -> { @bundle.reload.installment_plan } do
      put :update, params: installment_bundle_params.merge(installment_plan: { number_of_installments: 2 })
    end

    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_includes flash[:alert], "Installment plan is not available for the bundled product"
  end

  test "destroys the existing plan and creates a new plan when there are no payment options" do
    existing_plan = create_product_installment_plan(link: @bundle, number_of_installments: 2)

    assert_no_difference -> { ProductInstallmentPlan.count } do
      put :update, params: installment_bundle_params.merge(installment_plan: { number_of_installments: 4 })
    end

    assert_raises(ActiveRecord::RecordNotFound) { existing_plan.reload }

    new_plan = @bundle.reload.installment_plan
    assert_equal 4, new_plan.number_of_installments
    assert_equal "monthly", new_plan.recurrence
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  end

  test "soft deletes the existing plan and creates a new plan when there are payment options" do
    existing_plan = create_product_installment_plan(link: @bundle, number_of_installments: 2)
    create_payment_option(installment_plan: existing_plan)
    create_installment_plan_purchase(link: @bundle)

    put :update, params: installment_bundle_params.merge(installment_plan: { number_of_installments: 4 })

    assert_not_nil existing_plan.reload.deleted_at

    new_plan = @bundle.reload.installment_plan
    assert_equal 4, new_plan.number_of_installments
    assert_equal "monthly", new_plan.recurrence
    assert_not_equal existing_plan, new_plan
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  end

  test "destroys the existing plan when the param is removed and there are no payment options" do
    existing_plan = create_product_installment_plan(link: @bundle, number_of_installments: 2, recurrence: "monthly")

    assert_difference -> { ProductInstallmentPlan.count }, -1 do
      put :update, params: installment_bundle_params.merge(installment_plan: nil)
    end

    assert_raises(ActiveRecord::RecordNotFound) { existing_plan.reload }
    assert_nil @bundle.reload.installment_plan
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  end

  test "soft deletes the existing plan when the param is removed and there are payment options" do
    existing_plan = create_product_installment_plan(link: @bundle, number_of_installments: 2, recurrence: "monthly")
    create_payment_option(installment_plan: existing_plan)
    create_installment_plan_purchase(link: @bundle)

    put :update, params: installment_bundle_params.merge(installment_plan: nil)

    assert_not_nil existing_plan.reload.deleted_at
    assert_nil @bundle.reload.installment_plan
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  end

  test "does not create an installment plan when the bundle is not eligible" do
    BundleProduct.create!(bundle: @bundle, product: create_commission_product)

    assert_no_difference -> { ProductInstallmentPlan.count } do
      put :update, params: installment_bundle_params.merge(installment_plan: { number_of_installments: 3 })
    end

    assert_nil @bundle.reload.installment_plan
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_includes flash[:alert], "Installment plan is not available for the bundled product"
  end

  test "does not create an installment plan when the bundle has customizable price" do
    @bundle.update!(customizable_price: true)

    assert_no_difference -> { ProductInstallmentPlan.count } do
      put :update, params: bundle_params.merge(
        customizable_price: true,
        installment_plan: { number_of_installments: 3 }
      )
    end

    assert_nil @bundle.reload.installment_plan
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_includes flash[:alert], "Installment plans are not available for \"pay what you want\" pricing"
  end

  # --- default discount code ---------------------------------------------------

  test "sets the default offer code when a valid product offer code is provided" do
    offer_code = create_offer_code(user: @seller, products: [@bundle])

    put :update, params: bundle_params.merge(default_offer_code_id: offer_code.external_id)

    assert_equal offer_code, @bundle.reload.default_offer_code
    assert_equal "Changes saved!", flash[:notice]
  end

  test "sets the default offer code when a valid universal offer code is provided" do
    universal_offer_code = create_universal_offer_code(user: @seller)

    put :update, params: bundle_params.merge(default_offer_code_id: universal_offer_code.external_id)

    assert_equal universal_offer_code, @bundle.reload.default_offer_code
  end

  test "does not set the default offer code when offer code belongs to another user" do
    other_user = create_user
    other_user_offer_code = create_offer_code(user: other_user, products: [create_product(user: other_user)])

    put :update, params: bundle_params.merge(default_offer_code_id: other_user_offer_code.external_id)

    assert_nil @bundle.reload.default_offer_code
    assert_equal "Invalid offer code", flash[:alert]
  end

  test "does not set the default offer code when offer code is not associated with the bundle" do
    unassociated_offer_code = create_offer_code(user: @seller, products: [create_product(user: @seller)])

    put :update, params: bundle_params.merge(default_offer_code_id: unassociated_offer_code.external_id)

    assert_nil @bundle.reload.default_offer_code
    assert_equal "Offer code must apply to this product", flash[:alert]
  end

  test "does not set the default offer code when offer code is expired" do
    expired_offer_code = create_offer_code(user: @seller, products: [@bundle], valid_at: 2.days.ago, expires_at: 1.day.ago)

    put :update, params: bundle_params.merge(default_offer_code_id: expired_offer_code.external_id)

    assert_nil @bundle.reload.default_offer_code
    assert_equal "Offer code cannot be expired", flash[:alert]
  end

  test "clears the default offer code when an empty value is provided" do
    offer_code = create_offer_code(user: @seller, products: [@bundle])
    @bundle.update!(default_offer_code: offer_code)

    put :update, params: bundle_params.merge(default_offer_code_id: "")

    assert_nil @bundle.reload.default_offer_code
  end

  test "keeps the existing default offer code when the param is absent" do
    offer_code = create_offer_code(user: @seller, products: [@bundle])
    @bundle.update!(default_offer_code: offer_code)

    put :update, params: bundle_params

    assert_equal offer_code, @bundle.reload.default_offer_code
  end

  # --- refund policy -----------------------------------------------------------

  test "updates the bundle refund policy when seller_refund_policy_disabled_for_all feature is set" do
    Feature.activate(:seller_refund_policy_disabled_for_all)

    put :update, params: bundle_params
    @bundle.reload
    assert @bundle.product_refund_policy_enabled
    assert_equal "30-day money back guarantee", @bundle.product_refund_policy.title
    assert_equal "I really hate being small", @bundle.product_refund_policy.fine_print
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  ensure
    Feature.deactivate(:seller_refund_policy_disabled_for_all)
  end

  test "updates the bundle refund policy when seller refund policy is disabled" do
    @seller.update!(refund_policy_enabled: false)

    put :update, params: bundle_params
    @bundle.reload
    assert @bundle.product_refund_policy_enabled
    assert_equal "30-day money back guarantee", @bundle.product_refund_policy.title
    assert_equal "I really hate being small", @bundle.product_refund_policy.fine_print
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  end

  test "disables the product refund policy when seller refund policy is disabled and the param is false" do
    @seller.update!(refund_policy_enabled: false)
    @bundle.update!(product_refund_policy_enabled: true)

    put :update, params: bundle_params.merge(product_refund_policy_enabled: false)
    @bundle.reload
    assert_not @bundle.product_refund_policy_enabled
    assert_nil @bundle.product_refund_policy
    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Changes saved!", flash[:notice]
  end

  # --- error paths ---------------------------------------------------------------

  test "returns the error message when there is a validation error" do
    assert_no_changes -> { @bundle.reload.custom_permalink } do
      put :update, params: {
        bundle_id: @bundle.external_id,
        custom_permalink: "*",
      }
    end

    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Custom permalink is invalid", flash[:alert]
  end

  test "redirects with an error message when price_cents exceeds integer limit" do
    put :update, params: { bundle_id: @bundle.external_id, price_cents: 3_000_000_000 }

    assert_redirected_to edit_bundle_product_path(@bundle.external_id)
    assert_equal "Sorry, the price entered is too large.", flash[:alert]
  end

  test "PUT update raises RecordNotFound when the bundle doesn't exist" do
    assert_raises(ActiveRecord::RecordNotFound) do
      put :update, params: { bundle_id: "" }
    end
  end

  test "PUT update raises RecordNotFound when the product is a call" do
    product = create_call_product(user: @seller)

    assert_raises(ActiveRecord::RecordNotFound) do
      put :update, params: { bundle_id: product.external_id }
    end
  end

  test "PUT update raises RecordNotFound when the product is a membership" do
    product = create_membership_product(user: @seller)

    assert_raises(ActiveRecord::RecordNotFound) do
      put :update, params: { bundle_id: product.external_id }
    end
  end

  test "PUT update raises RecordNotFound when the product has variants" do
    product = create_product_with_digital_versions(user: @seller)

    assert_raises(ActiveRecord::RecordNotFound) do
      put :update, params: { bundle_id: product.external_id }
    end
  end
end
