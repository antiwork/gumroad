# frozen_string_literal: true

require "spec_helper"

RSpec.describe AudienceMember, :freeze_time do
  describe "validations" do
    it "validates json schema" do
      member = build(:audience_member, details: { "foo" => "bar" })
      expect(member).to be_invalid
      expect(member.errors[:details]).to be_present

      member = build(:audience_member, details: { "follower" => { "id" => 1 } })
      expect(member).to be_invalid
      expect(member.errors[:details]).to include(/The property '#\/follower' did not contain a required property of 'created_at'/)
    end

    it "validates email" do
      member = build(:audience_member, email: "invalid-email")
      expect(member).to be_invalid
      expect(member.errors[:email]).to be_present

      member = build(:audience_member, email: nil)
      expect(member).to be_invalid
      expect(member.errors[:email]).to be_present
    end
  end

  describe "callbacks" do
    it "saving assigns derived columns" do
      member = create(:audience_member, details: { "follower" => { "id" => 1, "created_at" => 7.days.ago.iso8601 } })
      expect(member.attributes).to include(
        "customer" => false,
        "follower" => true,
        "affiliate" => false,
        "min_paid_cents" => nil,
        "max_paid_cents" => nil,
        "min_purchase_created_at" => nil,
        "max_purchase_created_at" => nil,
        "min_created_at" => 7.days.ago,
        "max_created_at" => 7.days.ago,
        "follower_created_at" => 7.days.ago,
        "min_affiliate_created_at" => nil,
        "max_affiliate_created_at" => nil,
      )

      member.details["purchases"] = [
        { "id" => 1, "product_id" => 1, "price_cents" => 100, "created_at" => 3.days.ago.iso8601 },
        { "id" => 2, "product_id" => 1, "variant_ids" => [1, 2], "price_cents" => 200, "created_at" => 2.day.ago.iso8601 },
        { "id" => 3, "product_id" => 1, "variant_ids" => [1, 3], "price_cents" => 300, "created_at" => 1.day.ago.iso8601 },
      ]
      member.save!
      expect(member.attributes).to include(
        "customer" => true,
        "follower" => true,
        "affiliate" => false,
        "min_paid_cents" => 100,
        "max_paid_cents" => 300,
        "min_purchase_created_at" => 3.days.ago,
        "max_purchase_created_at" => 1.day.ago,
        "min_created_at" => 7.days.ago,
        "max_created_at" => 1.day.ago,
        "follower_created_at" => 7.days.ago,
        "min_affiliate_created_at" => nil,
        "max_affiliate_created_at" => nil,
      )

      member.details["affiliates"] = [
        { "id" => 1, "product_id" => 1, "created_at" => 30.minutes.ago.iso8601 },
        { "id" => 2, "product_id" => 1, "created_at" => 20.minutes.ago.iso8601 },
      ]
      member.save!
      expect(member.attributes).to include(
        "customer" => true,
        "follower" => true,
        "affiliate" => true,
        "min_paid_cents" => 100,
        "max_paid_cents" => 300,
        "min_purchase_created_at" => 3.days.ago,
        "max_purchase_created_at" => 1.day.ago,
        "min_created_at" => 7.days.ago,
        "max_created_at" => 20.minutes.ago,
        "follower_created_at" => 7.days.ago,
        "min_affiliate_created_at" => 30.minutes.ago,
        "max_affiliate_created_at" => 20.minutes.ago,
      )
    end
  end

  describe ".filter" do
    let(:seller) { create(:user) }
    let(:seller_id) { seller.id }

    it "works with no params" do
      member = create_member(follower: {})
      expect(filtered).to eq([member])
    end

    it "filters by type" do
      customer = create_member(purchases: [{}])
      follower = create_member(follower: {})
      affiliate = create_member(affiliates: [{}])
      all_types = create_member(purchases: [{}], follower: {}, affiliates: [{}])

      expect(filtered(type: "customer")).to eq([customer, all_types])
      expect(filtered(type: "follower")).to eq([follower, all_types])
      expect(filtered(type: "affiliate")).to eq([affiliate, all_types])
    end

    it "raises error for invalid type" do
      expect { filtered(type: "invalid_type") }.to raise_error(ArgumentError, /Invalid type: invalid_type/)
      expect { filtered(type: "'; DROP TABLE audience_members; --") }.to raise_error(ArgumentError, /Invalid type/)
    end

    it "filters by purchased and not-purchased products and variants" do
      member1 = create_member(purchases: [{ "product_id" => 1 }])
      member2 = create_member(purchases: [{ "product_id" => 2 }])
      member3 = create_member(purchases: [{ "product_id" => 2, "variant_ids" => [1] }])
      member4 = create_member(purchases: [{ "product_id" => 2, "variant_ids" => [2] }])
      member5 = create_member(purchases: [{ "product_id" => 1 }, { "product_id" => 2, "variant_ids" => [1] }])
      member6 = create_member(purchases: [{ "product_id" => 1 }, { "product_id" => 2, "variant_ids" => [1, 2] }])

      expect(filtered(bought_product_ids: [1])).to eq([member1, member5, member6])
      expect(filtered(bought_product_ids: [2])).to eq([member2, member3, member4, member5, member6])
      expect(filtered(bought_product_ids: [1, 2])).to eq([member1, member2, member3, member4, member5, member6])
      expect(filtered(bought_variant_ids: [1])).to eq([member3, member5, member6])
      expect(filtered(bought_variant_ids: [2])).to eq([member4, member6])
      expect(filtered(bought_product_ids: [1], bought_variant_ids: [1])).to eq([member1, member3, member5, member6])
      expect(filtered(bought_product_ids: [2], bought_variant_ids: [2])).to eq([member2, member3, member4, member5, member6])

      expect(filtered(not_bought_product_ids: [1])).to eq([member2, member3, member4])
      expect(filtered(not_bought_product_ids: [1, 2])).to eq([])
      expect(filtered(not_bought_variant_ids: [1])).to eq([member1, member2, member4])
      expect(filtered(not_bought_variant_ids: [1, 2])).to eq([member1, member2])
      expect(filtered(not_bought_product_ids: [1], not_bought_variant_ids: [1])).to eq([member2, member4])

      expect(filtered(bought_product_ids: [2], not_bought_variant_ids: [1])).to eq([member2, member4])
    end

    it "filters by prices" do
      member1 = create_member(purchases: [{ "price_cents" => 0 }])
      member2 = create_member(purchases: [{ "price_cents" => 100 }])
      member3 = create_member(purchases: [{ "price_cents" => 200 }])
      member4 = create_member(purchases: [
                                { "product_id" => 7, "variant_ids" => [1], "price_cents" => 0 },
                                { "product_id" => 8, "variant_ids" => [2], "price_cents" => 200 },
                                { "product_id" => 9, "variant_ids" => [3], "price_cents" => 200 },
                              ])

      expect(filtered(paid_more_than_cents: 0)).to eq([member2, member3, member4])
      expect(filtered(paid_more_than_cents: 50)).to eq([member2, member3, member4])
      expect(filtered(paid_more_than_cents: 100)).to eq([member3, member4])
      expect(filtered(paid_more_than_cents: 250)).to eq([])

      expect(filtered(paid_less_than_cents: 250)).to eq([member1, member2, member3, member4])
      expect(filtered(paid_less_than_cents: 200)).to eq([member1, member2, member4])
      expect(filtered(paid_less_than_cents: 100)).to eq([member1, member4])
      expect(filtered(paid_less_than_cents: 0)).to eq([])

      expect(filtered(paid_more_than_cents: 50, paid_less_than_cents: 150)).to eq([member2])

      expect(filtered(paid_more_than_cents: 0, bought_product_ids: [7])).to eq([])
      expect(filtered(paid_more_than_cents: 0, bought_variant_ids: [1])).to eq([])
      expect(filtered(paid_more_than_cents: 0, bought_product_ids: [7, 8])).to eq([member4])
      expect(filtered(paid_more_than_cents: 0, bought_variant_ids: [1, 2])).to eq([member4])
    end

    it "deduplicates rows joined by json_table" do
      member = create_member(purchases: [
                               { "price_cents" => 100 },
                               { "price_cents" => 200 },
                             ])

      expect(filtered(paid_more_than_cents: 0, paid_less_than_cents: 300)).to eq([member])
      expect(filtered_with_ids(paid_more_than_cents: 0, paid_less_than_cents: 300)).to eq([member])
    end

    it "filters by creation dates" do
      member1 = create_member(follower: { "created_at" => 5.days.ago.iso8601 })
      member2 = create_member(follower: { "created_at" => 4.days.ago.iso8601 })
      member3 = create_member(
        follower: { "created_at" => 3.days.ago.iso8601 },
        purchases: [{ "product_id" => 6, "created_at" => 2.days.ago.iso8601 }]
      )
      member4 = create_member(purchases: [
                                { "product_id" => 7, "variant_ids" => [1], "created_at" => 5.days.ago.iso8601 },
                                { "product_id" => 8, "variant_ids" => [2], "created_at" => 1.day.ago.iso8601 }
                              ])

      expect(filtered(created_after: 4.days.ago.iso8601)).to eq([member3, member4])
      expect(filtered(created_before: 2.days.ago.iso8601)).to eq([member1, member2, member3, member4])
      expect(filtered(created_after: 4.days.ago.iso8601, created_before: 2.days.ago.iso8601)).to eq([member3])
      expect(filtered(created_after: 4.days.ago.iso8601, created_before: 2.days.ago.iso8601, bought_product_ids: [6])).to eq([])
      expect(filtered(created_after: 4.days.ago.iso8601, created_before: 1.days.ago.iso8601, bought_product_ids: [6])).to eq([member3])
    end

    it "filters by country" do
      member1 = create_member(purchases: [{ "product_id" => 1, "country" => "United States" }])
      member2 = create_member(purchases: [{ "product_id" => 1, "country" => "Canada" }])
      member3 = create_member(purchases: [
                                { "product_id" => 1, "country" => "United States" },
                                { "product_id" => 2, "country" => "Canada" }
                              ])

      expect(filtered(bought_from: "United States")).to eq([member1, member3])
      expect(filtered(bought_from: "Canada")).to eq([member2, member3])
      expect(filtered(bought_from: "Canada", bought_product_ids: [1, 3])).to eq([member2])
      expect(filtered(bought_from: "Mexico")).to eq([])
    end

    it "filters by active customers, matching combined filters within a single purchase" do
      member1 = create_member(purchases: [{ "product_id" => 1 }])
      create_member(purchases: [{ "product_id" => 1, "subscription_cancelled" => true }])
      member3 = create_member(purchases: [
                                { "product_id" => 1, "subscription_cancelled" => true },
                                { "product_id" => 2 }
                              ])

      expect(filtered(active_customers_only: true)).to eq([member1, member3])
      expect(filtered(active_customers_only: true, bought_product_ids: [1])).to eq([member1])
      expect(filtered(active_customers_only: true, bought_product_ids: [2])).to eq([member3])
    end

    it "filters by minimum license uses, matching combined filters within a single purchase" do
      # The use count is read from the licenses table, not from a copy inside the member's
      # details JSON, so these members need real purchases with real licenses attached.
      member_without_uses = create_member_with_licenses([{ product_id: 1, uses: 0 }])
      member_with_three = create_member_with_licenses([{ product_id: 1, uses: 3 }])
      member_with_two_products = create_member_with_licenses([
                                                               { product_id: 1, uses: 1 },
                                                               { product_id: 2, uses: 5 }
                                                             ])
      member_without_license = create_member_with_licenses([{ product_id: 1, uses: nil }])

      product_ids = { 1 => member_with_three.details["purchases"].first["product_id"] }

      expect(filtered(minimum_license_uses: 1)).to eq([member_with_three, member_with_two_products])
      expect(filtered(minimum_license_uses: 3)).to eq([member_with_three, member_with_two_products])
      expect(filtered(minimum_license_uses: 5)).to eq([member_with_two_products])
      expect(filtered(minimum_license_uses: 1)).not_to include(member_without_uses, member_without_license)
      expect(filtered(minimum_license_uses: 3, bought_product_ids: [product_ids[1]])).to eq([member_with_three])
    end

    it "reads the CURRENT license use count, not a value copied into the member row" do
      # Regression guard for the row-lock removal: activations no longer rewrite the
      # buyer's audience_members row, so a filter that trusted a copy stored in that row
      # would go stale the moment a buyer activated a license.
      member = create_member_with_licenses([{ product_id: 1, uses: 1 }])
      license = Purchase.find(member.details["purchases"].first["id"]).license

      expect(filtered(minimum_license_uses: 5)).to eq([])

      license.update!(uses: 5)

      expect(filtered(minimum_license_uses: 5)).to eq([member])
    end

    it "filters by affiliate products" do
      member1 = create_member(affiliates: [{ "product_id" => 1 }])
      member2 = create_member(affiliates: [{ "product_id" => 2 }])
      member3 = create_member(affiliates: [
                                { "product_id" => 1, "created_at" => 3.day.ago.iso8601 },
                                { "product_id" => 2, "created_at" => 2.day.ago.iso8601 },
                                { "product_id" => 3, "created_at" => 1.day.ago.iso8601 },
                              ])

      expect(filtered(affiliate_product_ids: [1])).to eq([member1, member3])
      expect(filtered(affiliate_product_ids: [2])).to eq([member2, member3])
      expect(filtered(affiliate_product_ids: [1, 2])).to eq([member1, member2, member3])
      expect(filtered(affiliate_product_ids: [1, 2], created_after: 2.day.ago)).to eq([])
      expect(filtered(affiliate_product_ids: [1, 2], created_after: 3.day.ago)).to eq([member3])
    end

    context "with_ids" do
      it "returns the members, including the last record id matching the filters" do
        member_1 = create_member(
          purchases: [
            { "id" => 1, "price_cents" => 100 },
            { "id" => 2, "price_cents" => 90 },
            { "id" => 3, "price_cents" => 120 },
            { "id" => 4, "price_cents" => 70 },
          ],
          affiliates: [
            { "id" => 1, "created_at" => 7.days.ago.iso8601 },
            { "id" => 2, "created_at" => 4.days.ago.iso8601 },
          ]
        )

        member_2 = create_member(
          purchases: [
            { "id" => 5, "price_cents" => 100 },
            { "id" => 6, "price_cents" => 90 },
            { "id" => 7, "price_cents" => 120 },
            { "id" => 8, "price_cents" => 70 },
          ],
          follower: { "id" => 1, "created_at" => 5.days.ago.iso8601 }
        )

        member_3 = create_member(
          purchases: [
            { "id" => 9, "price_cents" => 200 },
          ]
        )

        results = filtered_with_ids
        expect(results.size).to eq(3)
        expect(results[0]).to eq(member_1)
        expect(results[0].purchase_id).to eq(4)
        expect(results[0].follower_id).to eq(nil)
        expect(results[0].affiliate_id).to eq(2)
        expect(results[1]).to eq(member_2)
        expect(results[1].purchase_id).to eq(8)
        expect(results[1].follower_id).to eq(1)
        expect(results[1].affiliate_id).to eq(nil)
        expect(results[2]).to eq(member_3)
        expect(results[2].purchase_id).to eq(9)
        expect(results[2].follower_id).to eq(nil)
        expect(results[2].affiliate_id).to eq(nil)

        results = filtered_with_ids(paid_more_than_cents: 75, paid_less_than_cents: 110)
        expect(results.size).to eq(2)
        expect(results[0]).to eq(member_1)
        expect(results[0].purchase_id).to eq(2)
        expect(results[0].follower_id).to eq(nil)
        expect(results[0].affiliate_id).to eq(nil)
        expect(results[1]).to eq(member_2)
        expect(results[1].purchase_id).to eq(6)
        expect(results[1].follower_id).to eq(nil)
        expect(results[1].affiliate_id).to eq(nil)

        results = filtered_with_ids(type: "follower", created_after: 6.days.ago.iso8601)
        expect(results.size).to eq(1)
        expect(results[0]).to eq(member_2)
        expect(results[0].purchase_id).to eq(nil)
        expect(results[0].follower_id).to eq(1)
        expect(results[0].affiliate_id).to eq(nil)
      end

      it "still returns the follower id when a bought-product filter is applied" do
        member = create_member(
          purchases: [{ "id" => 10, "product_id" => 42, "created_at" => 3.days.ago.iso8601 }],
          follower: { "id" => 7, "created_at" => 5.days.ago.iso8601 }
        )

        results = filtered_with_ids(type: "follower", bought_product_ids: [42])
        expect(results.size).to eq(1)
        expect(results[0]).to eq(member)
        expect(results[0].follower_id).to eq(7)
        expect(results[0].purchase_id).to eq(10)
      end
    end
  end

  describe ".refresh_all! and #refresh!" do
    let(:seller) { create(:user) }

    it "creates, updates, and soft-deletes members" do
      outdated_follower = create(:active_follower, user: seller)
      outdated_follower.update_column(:confirmed_at, nil) # simulate deleted follower outside of callbacks

      missing_purchase = create(:purchase, :from_seller, seller:)
      seller.audience_members.find_by(email: missing_purchase.email).delete # simulate missing purchase outside of callbacks

      normal_purchase = create(:purchase, :from_seller, seller:)
      refunded_purchase = create(:purchase, :from_seller, seller:, email: normal_purchase.email)
      refunded_purchase.update_column(:stripe_refunded, true) # simulate refunded purchase outside of callbacks

      affiliate = create(:direct_affiliate, seller:)
      affiliate.products << create(:product, user: seller)
      affiliate.products << create(:product, user: seller)
      affiliate.products << create(:product, user: seller)
      ProductAffiliate.find_by(affiliate:, product: affiliate.products[1]).delete # simulate product affiliation removed outside of callbacks

      # check that the outdated data, generated by callbacks, looks like what we expect
      expect(seller.audience_members.count).to eq(3)
      expect(seller.audience_members.where(email: outdated_follower.email, follower: true)).to be_present
      expect(seller.audience_members.where(email: missing_purchase.email, customer: true)).to be_blank
      member_with_several_purchases = seller.audience_members.find_by(email: normal_purchase.email, customer: true)
      expect(member_with_several_purchases).to be_present
      expect(member_with_several_purchases.details["purchases"].size).to eq(2)
      member_with_several_affiliate_products = seller.audience_members.find_by(email: affiliate.affiliate_user.email, affiliate: true)
      expect(member_with_several_affiliate_products).to be_present
      expect(member_with_several_affiliate_products.details["affiliates"].size).to eq(3)

      expect(described_class.refresh_all!(seller:)).to eq(3)

      expect(seller.audience_members.count).to eq(4)
      expect(seller.audience_members.active.count).to eq(3)
      outdated_member = seller.audience_members.find_by!(email: outdated_follower.email)
      expect(outdated_member.deleted_at).to be_present
      expect(outdated_member.details).to be_empty
      expect(seller.audience_members.where(email: missing_purchase.email, customer: true)).to be_present
      member_with_several_purchases = seller.audience_members.find_by(email: normal_purchase.email, customer: true)
      expect(member_with_several_purchases).to be_present
      expect(member_with_several_purchases.details["purchases"].size).to eq(1)
      expect(member_with_several_purchases.details["purchases"].first["id"]).to eq(normal_purchase.id)
      member_with_several_affiliate_products = seller.audience_members.find_by(email: affiliate.affiliate_user.email, affiliate: true)
      expect(member_with_several_affiliate_products).to be_present
      expect(member_with_several_affiliate_products.details["affiliates"].size).to eq(2)
      expect(member_with_several_affiliate_products.details["affiliates"].select { _1["product_id"] == affiliate.products[1].id }).to be_blank
    end
  end

  def filtered(params = {})
    described_class.filter(seller_id:, params:).order(:id).to_a
  end

  def filtered_with_ids(params = {})
    described_class.filter(seller_id:, params:, with_ids: true).order(:id).to_a
  end

  def create_member(details = {})
    create(:audience_member, seller:, **details.with_indifferent_access.slice(:purchases, :follower, :affiliates))
  end

  # Builds a real buyer: one product per spec, a successful purchase, and (when uses is
  # given) a license carrying that use count. The license filter joins the licenses table,
  # so a details-JSON-only member can never match it.
  def create_member_with_licenses(specs)
    email = generate(:email)
    purchases = specs.map do |spec|
      product = create(:product, user: seller, is_licensed: true)
      purchase = create(:purchase, :from_seller, link: product, seller:, email:)
      create(:license, purchase:, link: product, uses: spec[:uses]) unless spec[:uses].nil?
      purchase
    end
    AudienceMember.find_by!(email:, seller:).tap do |member|
      member.details["purchases"] = purchases.map do |purchase|
        {
          "id" => purchase.id,
          "product_id" => purchase.link_id,
          "price_cents" => purchase.price_cents,
          "created_at" => purchase.created_at.iso8601
        }
      end
      member.save!
    end
  end
end
