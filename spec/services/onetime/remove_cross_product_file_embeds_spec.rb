# frozen_string_literal: true

require "spec_helper"

describe Onetime::RemoveCrossProductFileEmbeds do
  let(:product) { create(:product) }
  let(:own_file) { create(:product_file, link: product) }
  let(:foreign_file) { create(:product_file, link: create(:product)) }
  let(:variant) { create(:variant, variant_category: create(:variant_category, link: product)) }

  def embed(file)
    { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
  end

  def seed_dirty_variant_content!
    rich_content = create(:rich_content, entity: variant, description: [embed(own_file)])
    rich_content.update_column(:description, [embed(own_file), embed(foreign_file)])
    variant.product_files << own_file
    variant.product_files << foreign_file
    rich_content
  end

  describe ".process" do
    it "removes cross-product embeds and stale join rows from variant content" do
      rich_content = seed_dirty_variant_content!

      described_class.process(dry_run: false)

      expect(rich_content.reload.embedded_product_file_ids_in_order).to eq([own_file.id])
      expect(variant.reload.product_files.pluck(:id)).to eq([own_file.id])
    end

    it "reports without mutating anything on a dry run" do
      rich_content = seed_dirty_variant_content!

      result = described_class.process(dry_run: true)

      expect(result[:cleaned]).to eq(1)
      expect(rich_content.reload.embedded_product_file_ids_in_order).to match_array([own_file.id, foreign_file.id])
      expect(variant.reload.product_files.pluck(:id)).to match_array([own_file.id, foreign_file.id])
    end

    it "leaves content that only embeds the product's own files untouched" do
      rich_content = create(:rich_content, entity: variant, description: [embed(own_file)])

      result = described_class.process(dry_run: false)

      expect(result[:cleaned]).to eq(0)
      expect(rich_content.reload.embedded_product_file_ids_in_order).to eq([own_file.id])
    end
  end
end
