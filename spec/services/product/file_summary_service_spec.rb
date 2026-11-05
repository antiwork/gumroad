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

  it "returns nothing for physical products and bundles" do
    [create(:physical_product), create(:product, :bundle)].each do |excluded|
      create(:product_file, link: excluded)
      expect(described_class.new(excluded).perform).to eq(product: nil, options: {})
    end
  end

  it "gives every option the product's files when versions share content" do
    category = create(:variant_category, link: product)
    versions = create_list(:variant, 2, variant_category: category)
    file(filetype: "pdf", size: 10)
    product.update!(has_same_rich_content_for_all_variants: true)

    shared = { formats: %w[PDF], total_size: 10, count: 1 }
    expect(summary).to eq(product: shared, options: versions.to_h { [_1.external_id, shared] })
  end

  it "summarizes each option's own pages when the shared flag hides them" do
    category = create(:variant_category, link: product)
    version = create(:variant, variant_category: category)
    pdf = file(filetype: "pdf", size: 10)
    file(filetype: "zip", size: 20)
    version.product_files << pdf
    create(:rich_content, entity: version, description: [{ "type" => "fileEmbed", "attrs" => { "id" => pdf.external_id, "uid" => SecureRandom.uuid } }])
    product.update!(has_same_rich_content_for_all_variants: true)

    expect(summary).to eq(product: nil, options: { version.external_id => { formats: %w[PDF], total_size: 10, count: 1 } })
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

    it "reads the options' pages and files without a query per option" do
      expect(count_queries(matching: /FROM `rich_contents`/) { summary }).to eq(1)
      expect(count_queries(matching: /FROM `product_files`/) { summary }).to eq(1)
    end

    it "summarizes each option from its own files and none for the unselected product" do
      expect(product).not_to receive(:product_files)

      expect(summary[:product]).to be_nil
      expect(summary[:options]).to eq(
        small.external_id => { formats: %w[MP3], total_size: 6_600_000, count: 1 },
        large.external_id => { formats: %w[WAV], total_size: 500_000_000, count: 2 },
      )
    end
  end
end
