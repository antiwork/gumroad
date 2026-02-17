# frozen_string_literal: true

require "spec_helper"

describe AudienceMember::Searchable do
  describe "#as_indexed_json" do
    let(:seller) { create(:user) }
    let(:audience_member) do
      create(:audience_member, seller:, purchases: [
               { id: 100, product_id: 10, variant_ids: [100], price_cents: 500, created_at: "2024-01-01T00:00:00Z", country: "US" }
             ])
    end

    it "includes all fields" do
      expect(audience_member.as_indexed_json).to eq(
        "id" => audience_member.id,
        "seller_id" => audience_member.seller_id,
        "email" => audience_member.email,
        "customer" => true,
        "follower" => false,
        "affiliate" => false,
        "min_paid_cents" => 500,
        "max_paid_cents" => 500,
        "min_purchase_created_at" => audience_member.min_purchase_created_at.as_json,
        "max_purchase_created_at" => audience_member.max_purchase_created_at.as_json,
        "follower_created_at" => nil,
        "min_affiliate_created_at" => nil,
        "max_affiliate_created_at" => nil,
        "min_created_at" => audience_member.min_created_at.as_json,
        "max_created_at" => audience_member.max_created_at.as_json,
        "created_at" => audience_member.created_at.as_json,
        "updated_at" => audience_member.updated_at.as_json,
        "purchased_product_ids" => [10],
        "purchased_variant_ids" => [100],
        "purchase_countries" => ["US"],
        "affiliate_product_ids" => [],
        "purchases" => [
          {
            "id" => 100,
            "product_id" => 10,
            "variant_ids" => [100],
            "price_cents" => 500,
            "created_at" => "2024-01-01T00:00:00Z",
            "country" => "US"
          }
        ],
        "follower_details" => nil,
        "affiliates" => []
      )
    end

    it "allows only a selection of fields to be used" do
      expect(audience_member.as_indexed_json(only: ["email", "seller_id"])).to eq(
        "email" => audience_member.email,
        "seller_id" => audience_member.seller_id
      )
    end
  end
end
