# frozen_string_literal: true

require "spec_helper"

describe Onetime::IdentifyClonedVariantContent do
  describe ".process" do
    let(:product) { create(:product, has_same_rich_content_for_all_variants: false) }
    let(:variant_category) { create(:variant_category, link: product) }
    let(:variant1) { create(:variant, variant_category:, name: "V1") }
    let(:variant2) { create(:variant, variant_category:, name: "V2") }
    let(:file1) { create(:product_file, link: product) }
    let(:file2) { create(:product_file, link: product) }

    def seed_identical_variant_content!
      [variant1, variant2].each do |v|
        create(:rich_content, entity: v, title: "Page", position: 0, description: [
                 { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } }
               ])
        v.product_files = [file1, file2]
      end
    end

    it "flags products where all variants share identical content with multiple files" do
      seed_identical_variant_content!
      io = StringIO.new
      allow($stdout).to receive(:puts) { |line| io.puts(line) }

      result = described_class.process

      expect(result[:scanned]).to be >= 1
      expect(result[:suspect]).to eq(1)
    end

    it "does not flag products where variants have distinct content" do
      create(:rich_content, entity: variant1, title: "V1", position: 0, description: [
               { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } }
             ])
      variant1.product_files = [file1]
      create(:rich_content, entity: variant2, title: "V2", position: 0, description: [
               { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } }
             ])
      variant2.product_files = [file2]

      result = described_class.process

      expect(result[:suspect]).to eq(0)
    end

    it "does not flag products with a single file per variant (no harmful leakage)" do
      [variant1, variant2].each do |v|
        create(:rich_content, entity: v, title: "Page", position: 0, description: [
                 { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } }
               ])
        v.product_files = [file1]
      end

      result = described_class.process

      expect(result[:suspect]).to eq(0)
    end

    it "skips products in shared-content mode" do
      product.update!(has_same_rich_content_for_all_variants: true)
      create(:rich_content, entity: product, title: "Shared", position: 0, description: [])

      result = described_class.process

      expect(result[:suspect]).to eq(0)
    end

    it "does not mutate any data" do
      seed_identical_variant_content!

      expect { described_class.process }
        .to not_change { variant1.reload.alive_rich_contents.size }
        .and not_change { variant2.reload.alive_rich_contents.size }
        .and not_change { variant1.reload.product_files.alive.size }
        .and not_change { variant2.reload.product_files.alive.size }
    end
  end
end
