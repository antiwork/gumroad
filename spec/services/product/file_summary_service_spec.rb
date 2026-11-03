# frozen_string_literal: true

require "spec_helper"

describe Product::FileSummaryService do
  let(:product) { create(:product) }

  def file(filetype:, size:, **attrs)
    create(:product_file, link: product, **attrs).tap { _1.update_columns(filetype:, size:) }
  end

  def summary = described_class.new(product).perform

  it "returns nothing for a product without files" do
    expect(summary).to eq(product: nil, options: {})
  end

  it "summarizes formats, total size and count without names" do
    file(filetype: "mp3", size: 1_000)
    file(filetype: "wav", size: 2_000)
    file(filetype: "mp3", size: 500)

    expect(summary[:product]).to eq(formats: %w[MP3 WAV], total_size: 3_500, count: 3)
    expect(summary.to_s).not_to include("display_name")
  end

  it "omits the total when a size is unknown and ignores deleted files and external links" do
    file(filetype: "pdf", size: nil)
    file(filetype: "zip", size: 10, deleted_at: Time.current)
    create(:product_file, link: product, filetype: "link", url: "https://example.com", size: nil)

    expect(summary[:product]).to eq(formats: %w[PDF], total_size: nil, count: 1)
  end

  it "summarizes only the files embedded in the pages when there are any" do
    kept = file(filetype: "wav", size: 300)
    file(filetype: "mp3", size: 7)
    create(:rich_content, entity: product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => kept.external_id, "uid" => SecureRandom.uuid } }])

    expect(summary[:product]).to eq(formats: %w[WAV], total_size: 300, count: 1)
  end

  context "with versions that have their own content" do
    let(:category) { create(:variant_category, link: product) }
    let!(:small) { create(:variant, variant_category: category, name: "MP3") }
    let!(:large) { create(:variant, variant_category: category, name: "WAV") }

    before do
      product.update!(has_same_rich_content_for_all_variants: false)
      small.product_files << file(filetype: "mp3", size: 6_600_000)
      large.product_files << file(filetype: "wav", size: 250_000_000)
      large.product_files << file(filetype: "wav", size: 250_000_000)
    end

    it "summarizes each option from its own files" do
      expect(summary[:options]).to eq(
        small.external_id => { formats: %w[MP3], total_size: 6_600_000, count: 1 },
        large.external_id => { formats: %w[WAV], total_size: 500_000_000, count: 2 },
      )
    end
  end
end
