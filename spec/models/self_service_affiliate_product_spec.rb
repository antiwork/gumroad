# frozen_string_literal: true

require "spec_helper"

describe SelfServiceAffiliateProduct do
  let(:creator) { create(:user) }

  describe "validations" do
    let(:product) { create(:product, user: creator) }
    subject(:self_service_affiliate_product) { build(:self_service_affiliate_product, product:, seller: creator) }

    it "validates without any error" do
      expect(self_service_affiliate_product).to be_valid
    end

    describe "presence" do
      subject(:self_service_affiliate_product) { described_class.new }

      it "validates presence of attributes" do
        expect(self_service_affiliate_product).to be_invalid
        expect(self_service_affiliate_product.errors.messages).to eq(
          seller: ["can't be blank"],
          product: ["can't be blank"],
        )
      end

      context "when enabled is set to true" do
        it "validates presence of affiliate_basis_points" do
          self_service_affiliate_product.enabled = true

          expect(self_service_affiliate_product).to be_invalid
          expect(self_service_affiliate_product.errors.messages).to eq(
            seller: ["can't be blank"],
            product: ["can't be blank"],
            affiliate_basis_points: ["can't be blank"]
          )
        end
      end
    end

    describe "affiliate_basis_points_must_fall_in_an_acceptable_range" do
      it "validates affiliate_basis_points is in valid range" do
        self_service_affiliate_product.enabled = true
        self_service_affiliate_product.affiliate_basis_points = 76

        expect(self_service_affiliate_product).to be_invalid
        expect(self_service_affiliate_product.errors.full_messages.first).to eq("Affiliate commission must be between 1% and 75%.")
      end
    end

    describe "destination_url_validation" do
      it "validates destination url format" do
        self_service_affiliate_product.destination_url = "invalid-url"

        expect(self_service_affiliate_product).to be_invalid
        expect(self_service_affiliate_product.errors.full_messages.first).to eq("The destination url you entered is invalid.")
      end
    end

    describe "product_is_not_a_collab" do
      let(:product) { create(:product, :is_collab, user: creator) }

      it "validates that the product is not a collab when enabled" do
        self_service_affiliate_product.enabled = true
        expect(self_service_affiliate_product).to be_invalid
        expect(self_service_affiliate_product.errors.full_messages).to match_array(["Collab products cannot have affiliates"])
      end

      it "does not validate that the product is not a collab when disabled" do
        self_service_affiliate_product.enabled = false
        expect(self_service_affiliate_product).to be_valid
      end
    end

    describe "product_user_and_seller_is_same" do
      let(:product) { create(:product) }

      it "validates that the product's creator is same as the seller" do
        expect(self_service_affiliate_product).to be_invalid
        expect(self_service_affiliate_product.errors.full_messages).to match_array(["The product '#{product.name}' does not belong to you (#{creator.email})."])
      end
    end
  end

  describe ".bulk_upsert!" do
    let(:published_product_one) { create(:product, user: creator) }
    let(:published_product_two) { create(:product, user: creator) }
    let!(:published_product_three) { create(:product, user: creator) }
    let!(:published_product_four) { create(:product, user: creator) }
    let!(:enabled_self_service_affiliate_product_for_published_product_one) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product_one, affiliate_basis_points: 1000) }
    let!(:enabled_self_service_affiliate_product_for_published_product_two) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product_two, destination_url: "https://example.com") }
    let(:products_with_details) do [
      { id: published_product_one.external_id_numeric, enabled: false, name: published_product_one.name, fee_percent: 10, destination_url: nil },
      { id: published_product_two.external_id_numeric, enabled: false, fee_percent: 5, destination_url: "https://example.com" },
      { id: published_product_three.external_id_numeric, enabled: false, name: published_product_three.name, fee_percent: nil, destination_url: nil },
      { id: published_product_four.external_id_numeric, enabled: true, name: published_product_four.name, fee_percent: 25, destination_url: "https://example.com/test" }
    ] end

    it "upserts the given products" do
      described_class.bulk_upsert!(products_with_details, creator.id)

      expect(enabled_self_service_affiliate_product_for_published_product_one.reload.enabled).to eq(false)
      expect(enabled_self_service_affiliate_product_for_published_product_two.reload.enabled).to eq(false)
      expect(enabled_self_service_affiliate_product_for_published_product_two.destination_url).to eq("https://example.com")
      expect(creator.self_service_affiliate_products.last.slice(:enabled, :product_id, :affiliate_basis_points, :destination_url)).to eq(
        "enabled" => true,
        "product_id" => published_product_four.id,
        "affiliate_basis_points" => 2500,
        "destination_url" => "https://example.com/test"
      )
    end

    it "raises an error with invalid params" do
      collab_product = create(:product, :is_collab, user: creator)

      products_with_details << {
        id: collab_product.external_id_numeric,
        enabled: true,
        name: collab_product.name,
        fee_percent: 10,
        destination_url: nil,
      }

      expect do
        described_class.bulk_upsert!(products_with_details, creator.id)
      end.to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Collab products cannot have affiliates")
    end
  end
end
