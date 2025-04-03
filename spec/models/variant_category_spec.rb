# frozen_string_literal: true

require "spec_helper"

describe VariantCategory do
  describe "scopes" do
    describe ".is_tier_category" do
      it "returns variant categories with title 'Tier'" do
        create(:variant_category)
        tier_category = create(:variant_category, title: "Tier")
        second_tier_category = create(:variant_category, title: "Tier")

        result = VariantCategory.is_tier_category

        expect(result).to eq [tier_category, second_tier_category]
      end
    end
  end

  describe "#has_alive_grouping_variants_with_purchases?" do
    describe "non-product file grouping category" do
      before do
        @variant_category = create(:variant_category, link: create(:product))
      end

      describe "has no variants" do
        it "returns false" do
          expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
        end
      end

      describe "has alive variants" do
        before do
          @variant = create(:variant, variant_category: @variant_category)
        end
        describe "variants have no purchases" do
          it "returns false" do
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
          end
        end

        describe "variants have purchases" do
          it "returns false" do
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
            @purchase = create(:purchase)
            @purchase.variant_attributes << @variant
            @purchase.save
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
          end
        end
      end

      describe "has dead variants" do
        before do
          @variant = create(:variant, variant_category: @variant_category)
          @variant.deleted_at = Time.current
          @variant.save
        end

        describe "variants have no purchases" do
          it "returns false" do
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
          end
        end

        describe "variants have purchases" do
          it "returns false" do
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
            @purchase = create(:purchase)
            @purchase.variant_attributes << @variant
            @purchase.save
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
          end
        end
      end
    end

    describe "with associated files" do
      before do
        @product = create(:product)
        @product_file_a = create(:product_file, link: @product)
        @variant_category = create(:variant_category, link: @product)
      end

      describe "has no variants" do
        it "returns false" do
          expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
        end
      end

      describe "has alive variants" do
        before do
          @variant = build(:variant, variant_category: @variant_category)
          @variant.product_files << @product_file_a
          @variant.save!
        end
        describe "variants have no purchases" do
          it "returns false" do
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
          end
        end

        describe "variants have successful purchases" do
          it "returns true" do
            purchase = create(:purchase, variant_attributes: [@variant])

            %w(preorder_authorization_successful successful not_charged gift_receiver_purchase_successful).each do |purchase_state|
              purchase.update!(purchase_state:)
              expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq true
            end
          end
        end

        describe "variants have non-successful or test purchases" do
          it "returns false" do
            %w(test_successful failed in_progress preorder_authorization_failed).each do |purchase_state|
              create(:purchase, variant_attributes: [@variant], purchase_state:)
            end

            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq false
          end
        end
      end

      describe "has dead variants" do
        before do
          @variant = build(:variant, variant_category: @variant_category)
          @variant.product_files << @product_file_a
          @variant.save!
          @variant.deleted_at = Time.current
          @variant.save
        end

        describe "variants have no purchases" do
          it "returns false" do
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
          end
        end

        describe "variants have purchases" do
          it "returns false" do
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
            @purchase = create(:purchase)
            @purchase.variant_attributes << @variant
            @purchase.save
            expect(@variant_category.has_alive_grouping_variants_with_purchases?).to eq(false)
          end
        end
      end
    end
  end
end
