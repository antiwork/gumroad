# frozen_string_literal: true

require "spec_helper"

describe Product::VariantsUpdaterService do
  describe ".perform" do
    context "for products with variants" do
      before :each do
        @product = create(:product)
        @size_category = create(:variant_category, link: @product, title: "Size")
        @small = create(:variant, variant_category: @size_category, name: "Small")
        @large = create(:variant, variant_category: @size_category, name: "Large")

        @variants_params = {
          "0" => {
            name: "SIZE",
            id: @size_category.external_id,
            options: {
              "0" => {
                name: @small.name,
                id: @small.external_id,
              },
              "1" => {
                name: "LARGE",
                id: @large.external_id
              }
            }
          },
          "1" => {
            name: "Color",
            id: nil,
            options: {
              "0" => {
                name: "Red",
                id: nil
              },
              "1" => {
                name: "Blue",
                id: nil
              }
            }
          }
        }
      end

      it "updates the variants and variant categories" do
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: @variants_params
        ).perform

        new_category = @product.variant_categories.last
        expect(new_category.title).to eq "Color"
        expect(new_category.variants.pluck(:name)).to match_array ["Red", "Blue"]
        expect(@size_category.reload.title).to eq "SIZE"
        expect(@large.reload.name).to eq "LARGE"
      end

      context "missing category name" do
        it "sets the category title to nil" do
          @variants_params["0"].delete(:name)

          Product::VariantsUpdaterService.new(
            product: @product,
            variants_params: @variants_params
          ).perform

          expect(@size_category.reload.title).to be_nil
        end
      end

      context "with empty categories" do
        it "deletes all categories" do
          Product::VariantsUpdaterService.new(
            product: @product,
            variants_params: {}
          ).perform

          expect(@product.reload.variant_categories_alive).to be_empty
        end
      end
    end

    context "for tiered memberships" do
      it "updates the tiers" do
        product = create(:membership_product)
        tier_category = product.variant_categories.first
        effective_date = 7.days.from_now.to_date

        variant_categories = {
          "0" => {
            name: tier_category.title,
            id: tier_category.external_id,
            options: {
              "0" => {
                name: "First Tier",
                settings: {
                  apply_price_changes_to_existing_memberships: {
                    enabled: "1",
                    effective_date: effective_date.strftime("%Y-%m-%d"),
                    custom_message: "hello"
                  },
                },
              },
              "1" => {
                name: "Second Tier"
              }
            }
          }
        }

        Product::VariantsUpdaterService.new(
          product:,
          variants_params: variant_categories
        ).perform

        tiers = tier_category.reload.variants.alive
        tier = tiers.find_by(name: "First Tier")
        expect(tiers.pluck(:name)).to match_array ["First Tier", "Second Tier"]
        expect(tier.apply_price_changes_to_existing_memberships).to eq true
        expect(tier.subscription_price_change_effective_date).to eq effective_date
        expect(tier.subscription_price_change_message).to eq "hello"
      end
    end

    context "for SKUs" do
      before :each do
        @product = create(:physical_product)
        @default_sku = @product.skus.first
        category = create(:variant_category, link: @product, title: "Size")

        @large_sku = create(:sku, link: @product, name: "Large")
        @medium_sku = create(:sku, link: @product, name: "Medium")
        @small_sku = create(:sku, link: @product, name: "Small")
        @xs_sku = create(:sku, link: @product, name: "X-Small")

        large_variant = create(:variant, variant_category: category,  skus: [@large_sku], name: "Large")
        medium_variant = create(:variant, variant_category: category, skus: [@medium_sku], name: "Medium")
        small_variant = create(:variant, variant_category: category, skus: [@small_sku], name: "Small")
        create(:variant, variant_category: category, skus: [@xs_sku], name: "Small")

        @variants_params = {
          "0" => {
            id: category.external_id,
            title: category.title,
            options: {
              "0" => {
                id: large_variant.external_id,
                name: large_variant.name,
              },
              "1" => {
                id: medium_variant.external_id,
                name: medium_variant.name,
              },
              "2" => {
                id: small_variant.external_id,
                name: small_variant.name,
              }
            }
          }
        }

        @skus_params = {
          "0" => {
            id: @large_sku.external_id,
            price_difference: 0
          },
          "1" => {
            id: @medium_sku.external_id,
            price_difference: 10
          },
          "2" => {
            id: @small_sku.external_id,
            custom_sku: "small-sku",
            price_difference: 0
          }
        }
      end

      it "updates new SKUs and deletes old ones" do
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: @variants_params,
          skus_params: @skus_params
        ).perform

        updated_skus = [@default_sku, @large_sku, @medium_sku, @small_sku].map(&:reload)

        expect(@product.reload.skus.alive).to match_array updated_skus
        expect(@small_sku.custom_sku).to eq "small-sku"
        expect(@medium_sku.price_difference_cents).to eq 1000
        expect(@xs_sku.reload).to be_deleted
      end

      context "missing SKU id" do
        it "raises an error" do
          params = @skus_params
          params["0"].delete(:id)

          expect do
            Product::VariantsUpdaterService.new(
              product: @product,
              variants_params: @variants_params,
              skus_params: params
            ).perform
          end.to raise_error Link::LinkInvalid
        end
      end
    end

    describe "deleting categories" do
      before :each do
        @product = create(:product)
        @size_category = create(:variant_category, link: @product, title: "Size")
        @color_category = create(:variant_category, link: @product, title: "Color")

        @variant_categories = {
          "0" => {
            name: @color_category.title,
            id: @color_category.external_id,
            options: {
              "0" => {
                id: nil,
                name: "green"
              }
            }
          }
        }
      end

      it "marks a category deleted if not included in variant_category_params" do
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: @variant_categories
        ).perform

        expect(@color_category.reload).to be_alive
        expect(@size_category.reload).not_to be_alive
      end

      it "does not mark a category deleted if it has purchases and files" do
        small_variant = create(:variant, :with_product_file, variant_category: @size_category, name: "Small")
        create(:purchase, link: @product, variant_attributes: [small_variant])

        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: @variant_categories
        ).perform

        expect(@color_category.reload).to be_alive
        expect(@size_category.reload).to be_alive
      end
    end
  end
end
