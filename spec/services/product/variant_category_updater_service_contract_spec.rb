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

    it "still unchecks an integration the payload explicitly submits as off" do
      # A submitted-but-empty integrations hash is a real statement, and must
      # keep working exactly as it does today.
      save(option_without_nested.merge(integrations: {}), contract: contract)

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
