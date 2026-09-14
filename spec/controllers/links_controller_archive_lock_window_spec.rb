# frozen_string_literal: true

require "spec_helper"

# Archive rows are a derived cache, so the pass runs in a job after the save commits —
# inside the save, the `links` row lock stayed held through a query-heavy pass that
# concurrent saves were queued behind, and a failed pass reported a committed save as failed.
describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  before { sign_in seller }

  def folder_group(name, files)
    {
      "type" => "fileEmbedGroup",
      "attrs" => { "name" => name, "uid" => SecureRandom.uuid },
      "content" => files.map { |f| { "type" => "fileEmbed", "attrs" => { "id" => f.external_id, "uid" => SecureRandom.uuid } } },
    }
  end

  let(:files) { 4.times.map { |i| create(:product_file, link: product, display_name: "File #{i}") } }
  let(:pages) do
    product.product_files = files
    product.save!
    [
      create(:rich_content, entity: product, title: "Page 1", description: [folder_group("One", files[0, 2])]),
      create(:rich_content, entity: product, title: "Page 2", description: [folder_group("Two", files[2, 2])]),
    ]
  end
  let(:params) do
    {
      id: product.unique_permalink,
      name: product.name,
      description: "A description",
      price_currency_type: "usd",
      price_cents: product.price_cents,
      customizable_price: false,
      covers: [],
      files: files.each_with_index.map { |f, i| { external_id: f.external_id, url: f.url, display_name: f.display_name, description: "", position: i } },
      has_same_rich_content_for_all_variants: true,
      rich_content: pages.map { |p| { id: p.external_id, title: p.title, description: { type: "doc", content: p.description } } },
      variants: [],
      confirmed_removed_variant_ids: [],
      confirmed_removed_rich_content_ids: [],
      preserved_rich_content_ids: pages.map(&:external_id),
      rich_content_provenance_version: 2,
    }
  end

  it "enqueues archive generation after the save instead of running it inside the transaction" do
    expect_any_instance_of(Link).not_to receive(:generate_product_files_archives!)

    post :update, params: params, as: :json

    expect(response).to be_successful
    expect(GenerateProductFilesArchivesJob).to have_enqueued_sidekiq_job(product.id)
    expect(product.reload.product_files_archives.folder_archives.alive.count).to eq(0)
  end

  it "reports the committed save as successful even when archive generation would fail" do
    allow_any_instance_of(Link).to receive(:generate_product_files_archives!).and_raise(ActiveRecord::RecordInvalid)

    post :update, params: params, as: :json

    expect(response).to be_successful
    expect(product.reload.description).to eq("A description")
  end

  it "builds the folder archives and enqueues their zip builds when the job runs", :sidekiq_inline do
    post :update, params: params, as: :json

    expect(response).to be_successful
    archive_ids = product.reload.product_files_archives.folder_archives.alive.pluck(:id)
    expect(archive_ids.size).to eq(2)
  end
end
