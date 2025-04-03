# frozen_string_literal: true

require "spec_helper"

describe Product::SkusUpdaterService do
  describe ".perform" do
    before do
      @product = create(:physical_product, skus_enabled: true)
      @category1 = create(:variant_category, title: "Size", link: @product)
      @variant1 = create(:variant, variant_category: @category1, name: "Small")
      @category2 = create(:variant_category, title: "Color", link: @product)
      @variant2 = create(:variant, variant_category: @category2, name: "Red")
    end

    subject { Product::SkusUpdaterService.new(product: @product) }

    it "creates the proper skus" do
      subject.perform

      expect(Sku.count).to eq 2
      expect(Sku.not_is_default_sku.count).to eq 1
      expect(Sku.not_is_default_sku.last.name).to eq "Small - Red"
      expect(Sku.not_is_default_sku.last.variants).to eq [@variant1, @variant2]
      expect(Sku.not_is_default_sku.last.link).to eq @product
    end

    it "creates the proper skus" do
      variant1_1 = create(:variant, variant_category: @category1, name: "Large")
      variant2_2 = create(:variant, variant_category: @category2, name: "Blue")
      subject.perform

      expect(Sku.count).to eq 5
      expect(Sku.not_is_default_sku.count).to eq 4
      skus = Sku.not_is_default_sku
      expect(skus.map(&:link)).to all eq(@product)
      expect(skus[0].name).to eq "Small - Red"
      expect(skus[0].variants).to match_array [@variant1, @variant2]

      expect(skus[1].name).to eq "Small - Blue"
      expect(skus[1].variants).to match_array [@variant1, variant2_2]

      expect(skus[2].name).to eq "Large - Red"
      expect(skus[2].variants).to match_array [variant1_1, @variant2]

      expect(skus[3].name).to eq "Large - Blue"
      expect(skus[3].variants).to match_array [variant1_1, variant2_2]
    end

    it "renames the existing sku if the variant name has changed" do
      subject.perform
      sku = Sku.last

      @variant1.update!(name: "S")
      subject.perform

      expect(Sku.count).to eq 2
      expect(Sku.not_is_default_sku.count).to eq 1
      expect(Sku.not_is_default_sku.last.name).to eq "S - Red"
      expect(Sku.not_is_default_sku.last.variants).to eq [@variant1, @variant2]
      expect(Sku.not_is_default_sku.last.id).to eq sku.id
    end

    it "removes the old skus and creates new ones if a new category has been added" do
      subject.perform
      old_sku = Sku.last

      @category2 = create(:variant_category, title: "Pattern", link: @product)
      @variant2 = create(:variant, variant_category: @category2, name: "Plaid")
      subject.perform

      expect(Sku.count).to eq 3
      expect(Sku.not_is_default_sku.count).to eq 2
      expect(Sku.not_is_default_sku.last.name).to eq "Small - Red - Plaid"
      expect(old_sku.reload.deleted_at.present?).to be(true)
    end

    it "deletes the skus if there are no variant categories left" do
      subject.perform

      @category1.mark_deleted
      @category2.mark_deleted

      subject.perform

      expect(Sku.count).to eq 2
      expect(Sku.not_is_default_sku.count).to eq 1
      expect(Sku.not_is_default_sku.last.deleted_at.present?).to be(true)
    end

    it "does not delete the default sku" do
      subject.perform

      @category1.mark_deleted
      @category2.mark_deleted

      subject.perform

      expect(Sku.alive.count).to eq 1
      expect(Sku.alive.is_default_sku.count).to eq 1
      expect(Sku.alive.not_is_default_sku.count).to eq 0
    end

    it "sets the price and quantity properly on existing skus" do
      variant1_1 = create(:variant, variant_category: @category1, name: "Large")
      variant2_2 = create(:variant, variant_category: @category2, name: "Blue")
      subject.perform

      expect(Sku.count).to eq 5
      expect(Sku.not_is_default_sku.count).to eq 4
      skus = Sku.not_is_default_sku
      expect(skus[0].name).to eq "Small - Red"
      expect(skus[0].variants).to eq [@variant1, @variant2]

      expect(skus[1].name).to eq "Small - Blue"
      expect(skus[1].variants).to eq [@variant1, variant2_2]

      expect(skus[2].name).to eq "Large - Red"
      expect(skus[2].variants).to eq [variant1_1, @variant2]

      expect(skus[3].name).to eq "Large - Blue"
      expect(skus[3].variants).to eq [variant1_1, variant2_2]

      skus_params = [
        {
          price_difference: "1",
          max_purchase_count: "2",
          id: skus[0].external_id
        },
        {
          price_difference: "3",
          max_purchase_count: "4",
          id: skus[1].external_id
        },
        {
          price_difference: "5",
          max_purchase_count: "6",
          id: skus[2].external_id
        },
        {
          price_difference: "7",
          max_purchase_count: "8",
          id: skus[3].external_id
        }
      ]
      Product::SkusUpdaterService.new(product: @product, skus_params:).perform

      skus = Sku.not_is_default_sku
      expect(skus[0].price_difference_cents).to eq 100
      expect(skus[0].max_purchase_count).to eq 2

      expect(skus[1].price_difference_cents).to eq 300
      expect(skus[1].max_purchase_count).to eq 4

      expect(skus[2].price_difference_cents).to eq 500
      expect(skus[2].max_purchase_count).to eq 6

      expect(skus[3].price_difference_cents).to eq 700
      expect(skus[3].max_purchase_count).to eq 8
    end

    context "invalid SKU id in params" do
      it "raises an error" do
        subject.perform

        skus = Sku.not_is_default_sku
        skus_params = [
          {
            price_difference: "1",
            max_purchase_count: "2",
            id: skus[0].external_id
          },
          {
            price_difference: "3",
            max_purchase_count: "4",
            id: "not_a_valid_sku"
          },
        ]
        expect do
          Product::SkusUpdaterService.new(product: @product, skus_params:).perform
        end.to raise_error(Link::LinkInvalid)
      end
    end
  end
end
