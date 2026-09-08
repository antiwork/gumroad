# frozen_string_literal: true

require "spec_helper"

describe AssetPreview do
  def preloaded_preview(id)
    described_class.includes(file_attachment: { blob: { variant_records: { image_attachment: :blob } } }).find(id)
  end

  it "returns the original and queues processing when the preloaded variants omit the requested size" do
    preview = create(:asset_preview)
    preview.file.variant(resize_to_limit: [20, 20]).processed
    preview = preloaded_preview(preview.id)
    original = preview.file.url

    expect { expect(preview.url_from_file).to eq(original) }.to change(ProcessAssetPreviewRetinaWorker.jobs, :size).by(1)
    expect(preview.file.blob.variant_records.reload.map(&:variation_digest)).not_to include(preview.retina_variant.variation.digest)
  end

  it "returns the newly generated variant when an inline worker fills a preloaded miss" do
    preview = preloaded_preview(create(:asset_preview).id)
    expect(preview.file.blob.variant_records).to be_empty

    returned = Sidekiq::Testing.inline! { preview.url_from_file }

    expect(returned).to eq(preview.reload.retina_variant.url)
    expect(returned).not_to eq(preview.file.url)
  end
end
