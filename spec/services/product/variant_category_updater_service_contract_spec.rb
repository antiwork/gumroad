# frozen_string_literal: true

require "spec_helper"

# Version-level collections under the save contract (gumroad-private#1379).
#
# The product-level collections were brought under the contract first, but a
# product's real content usually hangs off its VERSIONS, and those had their own
# omission-inference: version pages were deleted by `existing - submitted`, and
# version integrations by `active - enabled`. A payload that simply didn't
# mention them read as "remove them all".
describe Product::VariantCategoryUpdaterService, "version-level save contract" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let!(:category) { create(:variant_category, link: product, title: "Versions") }
  let!(:version) { create(:variant, variant_category: category, name: "V1") }
  let!(:version_page) do
    version.alive_rich_contents.create!(
      title: "Version page",
      description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "keep me" }] }]
    )
  end
  let!(:integration) { create(:circle_integration) }

  before do
    product.active_integrations << integration
    version.active_integrations << integration
  end

  def contract(deletion_operations: nil)
    params = { editor_revision: Product::EditorRevision.current(product.reload) }
    params[:deletion_operations] = deletion_operations if deletion_operations
    Product::SaveContract.new(params: params.deep_symbolize_keys, product: product.reload)
  end

  def save(option, contract:, confirmed_removed_rich_content_ids: [])
    described_class.new(
      product: product,
      category_params: { id: category.external_id, name: "Versions", options: [option] },
      confirmed_removed_rich_content_ids: confirmed_removed_rich_content_ids,
      contract: contract
    ).perform
  end

  # The version itself is submitted; its nested collections are not.
  let(:option_without_nested) { { id: version.external_id, name: "V1", price_difference_cents: 0 } }

  context "when the flag is on" do
    before { Feature.activate_user(Product::SaveContract::FEATURE_NAME, seller) }
    after { Feature.deactivate_user(Product::SaveContract::FEATURE_NAME, seller) }

    it "keeps a version's pages when the payload says nothing about them" do
      save(option_without_nested, contract: contract)

      expect(version_page.reload.alive?).to eq(true)
    end

    it "keeps a version's integrations when the payload says nothing about them" do
      save(option_without_nested, contract: contract)

      expect(version.reload.active_integrations).to include(integration)
    end

    it "does not delete a version's pages just because an empty list was sent" do
      save(option_without_nested.merge(rich_content: []), contract: contract)

      expect(version_page.reload.alive?).to eq(true)
    end

    it "deletes exactly the page named in deleted_ids" do
      other_page = version.alive_rich_contents.create!(title: "Second", description: [])
      ops = { deleted_ids: { rich_content: [version_page.external_id] } }

      # The explicit ids are also the confirmation the #6359 guard requires:
      # under the contract, naming an id IS the seller's stated intent.
      save(option_without_nested.merge(rich_content: []),
           contract: contract(deletion_operations: ops),
           confirmed_removed_rich_content_ids: [version_page.external_id])

      expect(version_page.reload.alive?).to eq(false)
      expect(other_page.reload.alive?).to eq(true)
    end

    # Superseded by the owner-scoped contract (reviewer, 2026-07-27). This
    # previously asserted that a submitted-but-empty integrations hash unchecks
    # the integration — i.e. deletion inferred from the checkbox map. That
    # inference is exactly what let a stale tab tear down an integration another
    # tab had just enabled, so a version's integration is now removed only when
    # the payload names it for that version.
    it "does not disconnect an integration merely absent from the submitted map" do
      save(option_without_nested.merge(integrations: {}), contract: contract)

      expect(version.reload.active_integrations).to include(integration)
    end

    it "disconnects an integration the payload explicitly names for this version" do
      naming_contract = contract(
        deletion_operations: { variant_deleted_ids: { version.external_id => { integrations: [integration.name] } } }
      )

      save(option_without_nested.merge(integrations: {}), contract: naming_contract)

      expect(version.reload.active_integrations).not_to include(integration)
    end

    it "does not raise when the nested collections are malformed" do
      expect do
        save(option_without_nested.merge(rich_content: "not-a-list", integrations: "not-a-hash"), contract: contract)
      end.not_to raise_error

      expect(version_page.reload.alive?).to eq(true)
      expect(version.reload.active_integrations).to include(integration)
    end
  end

  # The controller routes every OTHER alive grouping through the `options: nil`
  # entry point whenever a save names any deletion, so that a named id living
  # outside the first grouping can still be reached. A grouping that is already
  # empty cannot be left standing on the way past — the product would fail
  # Link#alive_category_variants_presence — but nothing of the seller's is lost
  # there. See ProductVariantDeletionAudit::EMPTY_GROUPING_CLEANUP for how that
  # is kept out of the omission-driven deletion count the rollout watches, and
  # the LinksControllerSaveContractTest case that covers it end to end.
  context "when an unrelated grouping is visited as a deletion-only entry" do
    let!(:empty_category) { create(:variant_category, link: product, title: "Formats") }

    before { Feature.activate_user(Product::SaveContract::FEATURE_NAME, seller) }
    after { Feature.deactivate_user(Product::SaveContract::FEATURE_NAME, seller) }

    def visit_empty_category(deletion_operations)
      described_class.new(
        product: product,
        category_params: { id: empty_category.external_id, options: nil },
        contract: contract(deletion_operations: deletion_operations)
      ).perform
    end

    it "removes nothing of the seller's from a grouping the request never named" do
      expect do
        visit_empty_category(variant_deleted_ids: { version.external_id => { integrations: [integration.name] } })
      end.not_to change { product.reload.alive_variants.count }
    end

    it "leaves the version named elsewhere alive" do
      visit_empty_category(deleted_ids: { variants: [version.external_id] })

      expect(version.reload.alive?).to eq(true)
    end
  end

  # Judged from the ids alone, so it can be pinned without standing up a whole
  # save. `affected` empty means the operation authorised removing no versions
  # at all — the only thing that went was an empty grouping.
  describe "how an empty-grouping cleanup is classified" do
    it "is a cleanup, not an omission, when no version's removal was authorised" do
      expect(
        ProductVariantDeletionAudit.intent_source_for(affected_external_ids: [], confirmed_external_ids: [])
      ).to eq(ProductVariantDeletionAudit::EMPTY_GROUPING_CLEANUP)
    end

    it "still reports an unconfirmed real deletion as an omission" do
      expect(
        ProductVariantDeletionAudit.intent_source_for(affected_external_ids: ["abc"], confirmed_external_ids: [])
      ).to eq(ProductVariantDeletionAudit::PAYLOAD_OMISSION)
    end
  end

  context "when the flag is off" do
    # Not "the pages are swept": the deletion guard added in #6359 already
    # blocks an unconfirmed sweep of content-bearing pages by raising. The
    # point of this example is that the contract changes nothing here — the
    # pre-existing protection is what responds, exactly as it does on main.
    it "preserves today's behaviour: the pre-existing guard blocks the sweep" do
      expect { save(option_without_nested, contract: contract) }.to raise_error(Link::LinkInvalid)

      expect(version_page.reload.alive?).to eq(true)
    end

    it "preserves today's behaviour: an omitted integrations key still unchecks" do
      # No pages on this version, so the content guard has nothing to object to
      # and the integration sweep runs as it does on main.
      version_page.mark_deleted!

      save(option_without_nested, contract: contract)

      expect(version.reload.active_integrations).not_to include(integration)
    end
  end
end
