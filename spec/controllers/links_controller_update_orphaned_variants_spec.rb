# frozen_string_literal: true

require "spec_helper"

# Regression coverage for gumroad-private#1784.
#
# When an editor save's payload doesn't mention a variant grouping at all, the
# save sweeps that grouping. The sweep used to mark only the grouping deleted:
# its versions (and their pages) stayed alive under a soft-deleted parent, a
# state the editor can neither display nor save back. These specs pin that a
# swept grouping takes its versions down with it, so that state can no longer
# be produced by the editor.
describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  before { sign_in seller }

  def file_embed_page(file)
    [{ "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }]
  end

  def paragraph(text)
    [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => text }] }]
  end

  def editor_save_params(variants_params)
    {
      id: product.unique_permalink,
      name: product.name,
      description: "A description",
      price_currency_type: "usd",
      price_cents: product.price_cents,
      customizable_price: false,
      covers: [],
      files: [],
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: variants_params,
      confirmed_removed_variant_ids: [],
      confirmed_removed_rich_content_ids: [],
      preserved_rich_content_ids: [],
      rich_content_provenance_version: 1,
    }
  end

  it "sweeps an unsubmitted grouping's versions together with the grouping instead of leaving them alive under it" do
    # The production shape behind gumroad-private#1784: a duplicate "Version"
    # grouping whose versions carry file-embed pages. The editor only ever
    # addresses the first alive grouping, so the duplicate is absent from the
    # payload and gets swept. The seller confirmed removing its versions — but
    # the sweep left the versions and their pages alive under the soft-deleted
    # grouping, and that state broke every later editor load and save.
    file = create(:product_file, link: product)
    live_category = create(:variant_category, link: product, title: "Version")
    live_variant = create(:variant, variant_category: live_category, name: "Free Trial")
    live_page = create(:rich_content, entity: live_variant, title: "Download", description: paragraph("Download instructions"))

    old_category = create(:variant_category, link: product, title: "Version")
    old_variants = ["1 Mac", "2 Macs"].map { |name| create(:variant, variant_category: old_category, name: name) }
    old_variants.each { |variant| create(:rich_content, entity: variant, title: nil, description: file_embed_page(file)) }

    params = editor_save_params(
      [
        {
          id: live_variant.external_id,
          name: live_variant.name,
          price_difference_cents: 0,
          rich_content: [
            {
              id: live_page.external_id,
              title: live_page.title,
              description: { type: "doc", content: paragraph("Edited instructions") },
            }
          ],
        }
      ]
    )
    params[:confirmed_removed_variant_ids] = old_variants.map(&:external_id)

    post :update, params: params, as: :json

    expect(response).to be_successful
    expect(live_page.reload.description).to eq(paragraph("Edited instructions"))
    expect(old_category.reload).to be_deleted
    old_variants.each { |variant| expect(variant.reload).to be_deleted }
    expect(BaseVariant.alive.where(variant_category_id: product.variant_categories.deleted.select(:id))).to be_empty
    expect(DeleteProductRichContentWorker.jobs.map { _1["args"] }).to include(*old_variants.map { [product.id, _1.id] })
  end
end
