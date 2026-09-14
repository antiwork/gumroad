# frozen_string_literal: true

require "spec_helper"

# Archive rows are a derived cache, so this pass must run outside the save
# transaction — inside it, the `links` row lock stayed held through a query-heavy
# pass that concurrent saves were queued behind. These specs pin that ordering.
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

  it "generates folder archives after the save transaction closes, not inside it" do
    files = 4.times.map { |i| create(:product_file, link: product, display_name: "File #{i}") }
    product.product_files = files
    product.save!
    pages = [
      create(:rich_content, entity: product, title: "Page 1", description: [folder_group("One", files[0, 2])]),
      create(:rich_content, entity: product, title: "Page 2", description: [folder_group("Two", files[2, 2])]),
    ]

    params = {
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

    # The spec example itself runs in a transaction, so the absolute depth is not
    # zero — what matters is that the save's own transaction has closed by the
    # time archives are built.
    transaction_depth_before_save = ApplicationRecord.connection.open_transactions
    transaction_depth_during_archive_generation = nil

    allow_any_instance_of(Link).to receive(:generate_product_files_archives!).and_wrap_original do |original, *args, **kwargs|
      transaction_depth_during_archive_generation = ApplicationRecord.connection.open_transactions
      original.call(*args, **kwargs)
    end

    post :update, params: params, as: :json

    expect(response).to be_successful
    expect(transaction_depth_during_archive_generation).to eq(transaction_depth_before_save)
    expect(product.reload.product_files_archives.folder_archives.alive.count).to eq(2)
    # The archive row's own commit is what enqueues the zip build; moving the row
    # creation out of the save transaction must not lose that.
    archive_ids = product.product_files_archives.folder_archives.alive.pluck(:id)
    expect(UpdateProductFilesArchiveWorker.jobs.map { _1["args"].first }).to include(*archive_ids)
  end
end
