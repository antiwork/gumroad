# frozen_string_literal: true

require "test_helper"

# Pins gumroad-private#1784, item 2: on a versioned product where one submitted
# variant id no longer resolves (already deleted by a concurrent save, or by an
# earlier iteration within the SAME save — see VariantCategoryUpdaterService),
# `Product::VariantCategoryUpdaterService#create_or_update_variant!` raised a bare
# `ActiveRecord::RecordNotFound` that unwound straight out of the `update`
# transaction. `LinksController#update`'s rescue clauses only handle
# StaleContentConflict/StaleDeletionConflict/HiddenVariantContentConflict/
# RecordNotSaved/RecordInvalid/LinkInvalid, so RecordNotFound was never one of
# them — the controller returned a bare 500, the transaction rolled back
# (nothing persisted), and from the editor's "Save changes" button this looked
# exactly like the reported symptom: a save that neither persists nor surfaces
# any error, hanging on "Saving changes...".
#
# The shape here mirrors the reporter's product qushdj (link 13633998): a
# versioned product with several variants including one literally named
# "Free Trial", each variant with exactly one live RichContent row and no
# Link-level RichContent. The variant name "Free Trial" is included and
# asserted on to rule out (not invoke) any accidental interaction with
# subscription free-trial plumbing — the bug is purely about a stale/missing
# variant id, unrelated to what any variant happens to be named.
class LinksControllerGp1784RichContentSaveTest < ActionController::TestCase
  tests LinksController

  setup do
    @seller = create_user(name: "Seller", payment_address: "seller-pay-#{SecureRandom.hex(4)}@example.com")
    @logged_in_user = create_user
    create_team_membership(user: @logged_in_user, seller: @seller, role: TeamMembership::ROLE_ADMIN)
    cookies.encrypted[:current_seller_id] = @seller.id
    sign_in @logged_in_user

    @product = create_product(user: @seller)
    @category = create_variant_category(link: @product, title: "Version")

    # Five live variants, one named exactly "Free Trial", matching the
    # reporter's product shape. Each gets exactly one live RichContent row;
    # the product itself has no Link-level RichContent.
    @variants = ["Free Trial", "1 Mac", "2 Macs", "3 Macs", "5 Macs"].map do |name|
      create_variant(variant_category: @category, name:)
    end
    @rich_contents = @variants.map do |variant|
      create_rich_content(entity: variant, title: "Download", description: [{ "type" => "paragraph" }])
    end
    @free_trial_variant = @variants.first
    @free_trial_rich_content = @rich_contents.first

    @base_params = { id: @product.unique_permalink, name: @product.name }
  end

  test "editing a RichContent row on the 'Free Trial' variant persists (rules out a name collision with subscription free-trial plumbing)" do
    put :update, params: @base_params.merge(
      variants: @variants.map do |variant|
        rich_content = variant.alive_rich_contents.sole
        {
          id: variant.external_id,
          name: variant.name,
          rich_content: [{
            id: rich_content.external_id,
            title: rich_content.title,
            description: variant == @free_trial_variant ? { type: "doc", content: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Edited" }] }] } : rich_content.description,
          }],
        }
      end
    ), as: :json

    assert_response :success
    assert_equal [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Edited" }] }],
                 @free_trial_rich_content.reload.description
  end

  test "a save naming a variant id that no longer resolves fails loudly with a JSON error instead of a bare 500 / silent no-op" do
    stale_variant = @variants.last
    stale_variant_id = ObfuscateIds.encrypt(stale_variant.id + 999_999_999)
    stale_variant.mark_deleted!

    rich_content_before = @free_trial_rich_content.updated_at

    put :update, params: @base_params.merge(
      variants: (@variants - [stale_variant]).map do |variant|
        rich_content = variant.alive_rich_contents.sole
        {
          id: variant.external_id,
          name: variant.name,
          rich_content: [{
            id: rich_content.external_id,
            title: rich_content.title,
            description: variant == @free_trial_variant ? { type: "doc", content: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Edited" }] }] } : rich_content.description,
          }],
        }
      end + [{ id: stale_variant_id, name: stale_variant.name }]
    ), as: :json

    # Before the fix this was a bare 500 (ActiveRecord::RecordNotFound
    # escaping the transaction) with no JSON body the editor's save handler
    # could read — indistinguishable, from the browser, from a hang.
    assert_response :unprocessable_entity
    body = response.parsed_body
    # Pin the SERVICE-level rescue specifically: the controller's catch-all
    # would also render 422, but with a generic message and an ErrorNotifier
    # report. Asserting the service's refresh message (and no error report,
    # below) means this test fails if the targeted rescue is removed and the
    # failure merely falls through to defense-in-depth.
    assert_includes body["error_message"].to_s, "may be out of date — please refresh",
                    "expected the variant-not-found seller message from " \
                    "VariantCategoryUpdaterService, got: #{response.body}"

    # The whole transaction rolled back: the unrelated Free Trial edit in the
    # SAME request must NOT have been silently partially applied.
    assert_equal rich_content_before, @free_trial_rich_content.reload.updated_at
  end

  test "a stale variant id takes the anticipated service rescue, not the catch-all (no error report for an expected editor-staleness case)" do
    stale_variant = @variants.last
    stale_variant_id = ObfuscateIds.encrypt(stale_variant.id + 999_999_999)
    stale_variant.mark_deleted!

    ErrorNotifier.expects(:notify).never

    put :update, params: @base_params.merge(
      variants: (@variants - [stale_variant]).map do |variant|
        rich_content = variant.alive_rich_contents.sole
        {
          id: variant.external_id,
          name: variant.name,
          rich_content: [{ id: rich_content.external_id, title: rich_content.title, description: rich_content.description }],
        }
      end + [{ id: stale_variant_id, name: stale_variant.name }]
    ), as: :json

    assert_response :unprocessable_entity
  end

  test "an entirely unanticipated exception during save also fails loudly instead of propagating as a bare 500" do
    # Defense in depth: even a failure mode nobody wrote a specific rescue for
    # must still surface as a readable JSON error, not an unhandled 500 that
    # looks like a hang from the browser.
    Product::VariantCategoryUpdaterService.any_instance.stubs(:save_rich_content).raises(RuntimeError, "boom")
    rich_content_before = @free_trial_rich_content.updated_at

    # The catch-all's contract is fail-loudly-BOTH-ways: readable JSON for the
    # seller AND a report for on-call. Without this expectation, removing the
    # ErrorNotifier call would silently regress 500-visibility to nothing.
    ErrorNotifier.expects(:notify).with(instance_of(RuntimeError))

    put :update, params: @base_params.merge(
      variants: @variants.map do |variant|
        rich_content = variant.alive_rich_contents.sole
        {
          id: variant.external_id,
          name: variant.name,
          rich_content: [{ id: rich_content.external_id, title: rich_content.title, description: rich_content.description }],
        }
      end
    ), as: :json

    assert_response :unprocessable_entity
    assert response.parsed_body["error_message"].present?
    assert_equal rich_content_before, @free_trial_rich_content.reload.updated_at
  end
end
