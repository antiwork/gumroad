# frozen_string_literal: true

require "spec_helper"

describe AudienceMember::Searchable, :freeze_time do
  describe "#as_indexed_json" do
    it "includes all mapped fields" do
      member = create(
        :audience_member,
        purchases: [{ id: 1, product_id: 2, variant_ids: [3, 4], price_cents: 500, created_at: 3.days.ago.iso8601, country: "United States" }],
        follower: { id: 5, created_at: 7.days.ago.iso8601 },
        affiliates: [{ id: 6, product_id: 7, created_at: 1.day.ago.iso8601 }],
      ).reload

      expect(member.as_indexed_json).to eq(
        "seller_id" => member.seller_id,
        "email" => member.email,
        "customer" => true,
        "follower" => true,
        "affiliate" => true,
        "min_paid_cents" => 500,
        "max_paid_cents" => 500,
        "min_created_at" => 7.days.ago.as_json,
        "max_created_at" => 1.day.ago.as_json,
        "min_purchase_created_at" => 3.days.ago.as_json,
        "max_purchase_created_at" => 3.days.ago.as_json,
        "follower_id" => 5,
        "follower_created_at" => 7.days.ago.as_json,
        "min_affiliate_created_at" => 1.day.ago.as_json,
        "max_affiliate_created_at" => 1.day.ago.as_json,
        "purchases" => [{ "id" => 1, "product_id" => 2, "variant_ids" => [3, 4], "price_cents" => 500, "created_at" => 3.days.ago.iso8601, "country" => "United States" }],
        "affiliates" => [{ "id" => 6, "product_id" => 7, "created_at" => 1.day.ago.iso8601 }],
      )
    end

    it "allows only a selection of fields to be used" do
      member = create(:audience_member, follower: { id: 1, created_at: 7.days.ago.iso8601 }).reload

      expect(member.as_indexed_json(only: ["seller_id", "follower_id"])).to eq(
        "seller_id" => member.seller_id,
        "follower_id" => 1,
      )
    end

    it "handles rows with nil details" do
      member = create(:audience_member, follower: { id: 1, created_at: 7.days.ago.iso8601 })
      member.update_column(:details, nil)
      member.reload

      json = member.as_indexed_json
      expect(json["purchases"]).to eq([])
      expect(json["affiliates"]).to eq([])
      expect(json["follower_id"]).to be_nil
    end
  end

  describe "indexing callbacks" do
    it "enqueues indexing jobs on create, update, and destroy when the seller's flag is on" do
      seller = create(:user)
      Feature.activate_user(:audience_count_from_elasticsearch, seller)

      member = nil
      expect do
        member = create(:audience_member, seller:, purchases: [{ "id" => 1 }])
      end.to change { ElasticsearchIndexerWorker.jobs.size }.by(2)
      expect(ElasticsearchIndexerWorker.jobs.last["args"]).to eq(["index", { "record_id" => member.id, "class_name" => "AudienceMember" }])

      expect do
        member.details["purchases"] << { "id" => 2, "product_id" => 2, "price_cents" => 200, "created_at" => 1.day.ago.iso8601 }
        member.save!
      end.to change { ElasticsearchIndexerWorker.jobs.size }.by(2)
      operation, options = ElasticsearchIndexerWorker.jobs.last["args"]
      expect(operation).to eq("update")
      expect(options["record_id"]).to eq(member.id)
      expect(options["fields"]).to include("purchases", "max_paid_cents", "max_purchase_created_at")

      expect do
        member.destroy!
      end.to change { ElasticsearchIndexerWorker.jobs.size }.by(1)
      expect(ElasticsearchIndexerWorker.jobs.last["args"]).to eq(["delete", { "record_id" => member.id, "class_name" => "AudienceMember" }])
    end

    it "enqueues nothing when the seller's flag is off" do
      member = nil
      expect do
        member = create(:audience_member, purchases: [{ "id" => 1 }])
        member.details["purchases"] << { "id" => 2, "product_id" => 2, "price_cents" => 200, "created_at" => 1.day.ago.iso8601 }
        member.save!
        member.destroy!
      end.not_to change { ElasticsearchIndexerWorker.jobs.size }
    end
  end

  describe ".filter_count", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    let(:seller) { create(:user) }
    let(:seller_id) { seller.id }

    before do
      recreate_model_index(AudienceMember)
      Feature.activate_user(:audience_count_from_elasticsearch, seller)
    end

    it "counts all members of the seller with no params" do
      create_member(follower: {})
      create_member(purchases: [{}])
      create(:audience_member)

      expect_filter_count(2)
    end

    it "counts by type" do
      create_member(purchases: [{}])
      create_member(follower: {})
      create_member(affiliates: [{}])
      create_member(purchases: [{}], follower: {}, affiliates: [{}])

      expect_filter_count(2, type: "customer")
      expect_filter_count(2, type: "follower")
      expect_filter_count(2, type: "affiliate")
    end

    it "raises error for invalid type" do
      expect { AudienceMember.filter_count(seller_id:, params: { type: "invalid_type" }) }.to raise_error(ArgumentError, /Invalid type: invalid_type/)
    end

    it "counts by purchased and not-purchased products and variants" do
      create_member(purchases: [{ "product_id" => 1 }])
      create_member(purchases: [{ "product_id" => 2 }])
      create_member(purchases: [{ "product_id" => 2, "variant_ids" => [1] }])
      create_member(purchases: [{ "product_id" => 2, "variant_ids" => [2] }])
      create_member(purchases: [{ "product_id" => 1 }, { "product_id" => 2, "variant_ids" => [1] }])
      create_member(purchases: [{ "product_id" => 1 }, { "product_id" => 2, "variant_ids" => [1, 2] }])
      create_member(follower: {})

      expect_filter_count(3, bought_product_ids: [1])
      expect_filter_count(5, bought_product_ids: [2])
      expect_filter_count(6, bought_product_ids: [1, 2])
      expect_filter_count(3, bought_variant_ids: [1])
      expect_filter_count(2, bought_variant_ids: [2])
      expect_filter_count(4, bought_product_ids: [1], bought_variant_ids: [1])
      expect_filter_count(5, bought_product_ids: [2], bought_variant_ids: [2])

      expect_filter_count(4, not_bought_product_ids: [1])
      expect_filter_count(1, not_bought_product_ids: [1, 2])
      expect_filter_count(4, not_bought_variant_ids: [1])
      expect_filter_count(3, not_bought_variant_ids: [1, 2])
      expect_filter_count(3, not_bought_product_ids: [1], not_bought_variant_ids: [1])

      expect_filter_count(2, bought_product_ids: [2], not_bought_variant_ids: [1])
    end

    it "counts by prices, matching combined filters within a single purchase" do
      create_member(purchases: [{ "price_cents" => 0 }])
      create_member(purchases: [{ "price_cents" => 100 }])
      create_member(purchases: [{ "price_cents" => 200 }])
      create_member(purchases: [
                      { "product_id" => 7, "variant_ids" => [1], "price_cents" => 0 },
                      { "product_id" => 8, "variant_ids" => [2], "price_cents" => 200 },
                      { "product_id" => 9, "variant_ids" => [3], "price_cents" => 200 },
                    ])
      create_member(follower: {})

      expect_filter_count(3, paid_more_than_cents: 0)
      expect_filter_count(3, paid_more_than_cents: 50)
      expect_filter_count(2, paid_more_than_cents: 100)
      expect_filter_count(0, paid_more_than_cents: 250)

      expect_filter_count(4, paid_less_than_cents: 250)
      expect_filter_count(3, paid_less_than_cents: 200)
      expect_filter_count(2, paid_less_than_cents: 100)
      expect_filter_count(0, paid_less_than_cents: 0)

      expect_filter_count(1, paid_more_than_cents: 50, paid_less_than_cents: 150)

      expect_filter_count(0, paid_more_than_cents: 0, bought_product_ids: [7])
      expect_filter_count(0, paid_more_than_cents: 0, bought_variant_ids: [1])
      expect_filter_count(1, paid_more_than_cents: 0, bought_product_ids: [7, 8])
      expect_filter_count(1, paid_more_than_cents: 0, bought_variant_ids: [1, 2])
      expect_filter_count(1, paid_more_than_cents: 100, bought_product_ids: [9], bought_variant_ids: [2])
    end

    it "counts members with multiple matching purchases once" do
      create_member(purchases: [
                      { "price_cents" => 100 },
                      { "price_cents" => 200 },
                    ])

      expect_filter_count(1, paid_more_than_cents: 0, paid_less_than_cents: 300)
    end

    it "counts by creation dates" do
      create_member(follower: { "created_at" => 5.days.ago.iso8601 })
      create_member(follower: { "created_at" => 4.days.ago.iso8601 })
      create_member(
        follower: { "created_at" => 3.days.ago.iso8601 },
        purchases: [{ "product_id" => 6, "created_at" => 2.days.ago.iso8601 }]
      )
      create_member(purchases: [
                      { "product_id" => 7, "variant_ids" => [1], "created_at" => 5.days.ago.iso8601 },
                      { "product_id" => 8, "variant_ids" => [2], "created_at" => 1.day.ago.iso8601 }
                    ])

      expect_filter_count(2, created_after: 4.days.ago.iso8601)
      expect_filter_count(4, created_before: 2.days.ago.iso8601)
      expect_filter_count(1, created_after: 4.days.ago.iso8601, created_before: 2.days.ago.iso8601)
      expect_filter_count(0, created_after: 4.days.ago.iso8601, created_before: 2.days.ago.iso8601, bought_product_ids: [6])
      expect_filter_count(1, created_after: 4.days.ago.iso8601, created_before: 1.day.ago.iso8601, bought_product_ids: [6])
    end

    it "counts by type-specific creation dates" do
      create_member(follower: { "created_at" => 10.days.ago.iso8601 }, purchases: [{ "product_id" => 1, "created_at" => 3.days.ago.iso8601 }])
      create_member(follower: { "created_at" => 3.days.ago.iso8601 }, purchases: [{ "product_id" => 1, "created_at" => 10.days.ago.iso8601 }])
      create_member(follower: { "created_at" => 3.days.ago.iso8601 }, purchases: [{ "product_id" => 1, "created_at" => 2.days.ago.iso8601 }])
      create_member(follower: { "created_at" => 3.days.ago.iso8601 }, purchases: [
                      { "id" => 1, "product_id" => 1, "created_at" => 10.days.ago.iso8601 },
                      { "id" => 2, "product_id" => 1, "created_at" => 1.hour.ago.iso8601 },
                    ])

      expect_filter_count(3, type: "customer", created_after: 5.days.ago.iso8601)
      expect_filter_count(3, type: "follower", created_after: 5.days.ago.iso8601)
      expect_filter_count(1, type: "follower", created_after: 5.days.ago.iso8601, created_before: 1.day.ago.iso8601, bought_product_ids: [1])
      expect_filter_count(2, type: "customer", created_before: 5.days.ago.iso8601)

      expect_filter_count(2, type: "customer", created_after: 5.days.ago.iso8601, created_before: 1.day.ago.iso8601)
      expect_filter_count(3, type: "follower", created_after: 5.days.ago.iso8601, created_before: 1.day.ago.iso8601)
    end

    it "counts by affiliate creation dates" do
      create_member(follower: { "created_at" => 1.day.ago.iso8601 }, affiliates: [{ "product_id" => 1, "created_at" => 10.days.ago.iso8601 }])
      create_member(purchases: [{ "created_at" => 10.days.ago.iso8601 }], affiliates: [{ "product_id" => 1, "created_at" => 1.day.ago.iso8601 }])
      create_member(affiliates: [{ "product_id" => 2, "created_at" => 3.days.ago.iso8601 }])

      expect_filter_count(2, type: "affiliate", created_after: 5.days.ago.iso8601)
      expect_filter_count(1, type: "affiliate", created_before: 5.days.ago.iso8601)
      expect_filter_count(1, type: "affiliate", created_after: 5.days.ago.iso8601, created_before: 2.days.ago.iso8601)
      expect_filter_count(1, type: "affiliate", affiliate_product_ids: [1], created_after: 2.days.ago.iso8601)
    end

    it "counts by country" do
      create_member(purchases: [{ "product_id" => 1, "country" => "United States" }])
      create_member(purchases: [{ "product_id" => 1, "country" => "Canada" }])
      create_member(purchases: [
                      { "product_id" => 1, "country" => "United States" },
                      { "product_id" => 2, "country" => "Canada" }
                    ])
      create_member(follower: {})

      expect_filter_count(2, bought_from: "United States")
      expect_filter_count(2, bought_from: "Canada")
      expect_filter_count(1, bought_from: "Canada", bought_product_ids: [1, 3])
      expect_filter_count(0, bought_from: "Mexico")
    end

    it "matches countries exactly, not case-insensitively" do
      create_member(purchases: [
                      { "id" => 1, "product_id" => 4, "country" => "UNITED STATES" },
                      { "id" => 2, "product_id" => 5, "country" => "United States" },
                    ])

      expect_filter_count(1, bought_from: "United States")
      expect_filter_count(1, bought_from: "UNITED STATES")
      expect_filter_count(0, bought_from: "United States", bought_product_ids: [4])
      expect_filter_count(1, bought_from: "United States", bought_product_ids: [5])
    end

    it "counts consistently when cutoff dates carry timezone offsets" do
      create_member(purchases: [{ "id" => 1, "product_id" => 1, "created_at" => "2026-06-01T07:30:00Z" }])
      create_member(purchases: [{ "id" => 2, "product_id" => 1, "created_at" => "2026-06-01T08:30:00Z" }])

      expect_filter_count(1, created_before: "2026-05-31T23:59:59-08:00")
      expect_filter_count(1, created_after: "2026-05-31T23:59:59-08:00")
      expect_filter_count(1, bought_product_ids: [1], created_after: "2026-05-31T23:59:59-08:00", created_before: "2026-06-01T02:00:00-07:00")
    end

    it "counts by affiliate products" do
      create_member(affiliates: [{ "product_id" => 1 }])
      create_member(affiliates: [{ "product_id" => 2 }])
      create_member(affiliates: [
                      { "product_id" => 1, "created_at" => 3.days.ago.iso8601 },
                      { "product_id" => 2, "created_at" => 2.days.ago.iso8601 },
                      { "product_id" => 3, "created_at" => 1.day.ago.iso8601 },
                    ])

      expect_filter_count(2, affiliate_product_ids: [1])
      expect_filter_count(2, affiliate_product_ids: [2])
      expect_filter_count(3, affiliate_product_ids: [1, 2])
      expect_filter_count(0, affiliate_product_ids: [1, 2], created_after: 2.days.ago.iso8601)
      expect_filter_count(1, affiliate_product_ids: [1, 2], created_after: 3.days.ago.iso8601)
    end

    it "counts nothing when purchase and affiliate filters must match a single record" do
      create_member(
        purchases: [{ "product_id" => 1, "price_cents" => 200 }],
        affiliates: [{ "product_id" => 2 }],
      )

      expect_filter_count(1, bought_product_ids: [1], affiliate_product_ids: [2])
      expect_filter_count(0, bought_product_ids: [1], affiliate_product_ids: [2], paid_more_than_cents: 100)
    end

    it "caps the count at the limit" do
      create_member(purchases: [{ "product_id" => 1 }])
      create_member(purchases: [{ "product_id" => 1 }])
      create_member(purchases: [{ "product_id" => 1 }])

      expect(AudienceMember.filter_count(seller_id:, params: { bought_product_ids: [1] }, limit: 2)).to eq(2)
      expect(AudienceMember.filter_count(seller_id:, params: { bought_product_ids: [1] }, limit: 5)).to eq(3)
    end

    it "keeps counts in sync when a member's details change or the member is destroyed" do
      member = create(:audience_member, seller:, follower: { "id" => 1, "created_at" => 7.days.ago.iso8601 })

      expect_filter_count(0, type: "customer")
      expect_filter_count(1, type: "follower")

      member.details["purchases"] = [{ "id" => 1, "product_id" => 1, "price_cents" => 200, "created_at" => 1.day.ago.iso8601 }]
      member.save!

      expect_filter_count(1, type: "customer")
      expect_filter_count(1, paid_more_than_cents: 150)
      expect(EsClient.get(index: AudienceMember.index_name, id: member.id)["_source"]).to eq(member.reload.as_indexed_json)

      member.destroy!

      expect_filter_count(0)
    end

    it "excludes members whose details were cleared outside callbacks from single-record filters" do
      member = create_member(follower: { "created_at" => 5.days.ago.iso8601 })
      member.update_columns(details: nil)
      ElasticsearchIndexerWorker.new.perform("index", { "record_id" => member.id, "class_name" => "AudienceMember" })

      expect_filter_count(1, type: "follower", created_after: 10.days.ago.iso8601)
      expect_filter_count(0, type: "follower", created_after: 10.days.ago.iso8601, created_before: 1.day.ago.iso8601)
    end

    def expect_filter_count(expected, params = {})
      expect(AudienceMember.filter_count(seller_id:, params:)).to eq(expected)
      expect(AudienceMember.filter(seller_id:, params:).count).to eq(expected)
    end

    def create_member(details = {})
      create(:audience_member, seller:, **details.with_indifferent_access.slice(:purchases, :follower, :affiliates))
    end
  end
end
