# frozen_string_literal: true

require "spec_helper"

describe Affiliate::Sorting do
  describe ".sorted_by" do
    let!(:seller) { create(:named_seller) }
    let!(:product1) { create(:product, user: seller, name: "p1") }
    let!(:product2) { create(:product, user: seller, name: "p2") }
    let!(:product3) { create(:product, user: seller, name: "p3") }
    let!(:affiliate_user_1) { create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "aff1"), products: [product1]) }
    let!(:affiliate_user_2) { create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "aff2"), products: [product1, product2, product3]) }
    let!(:affiliate_user_3) { create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "aff3"), products: [product1, product3]) }

    before do
      ProductAffiliate.where(affiliate_id: affiliate_user_1.id).each.with_index do |affiliate, idx|
        affiliate.update_columns(affiliate_basis_points: 3000 + 100 * idx)
      end
      ProductAffiliate.where(affiliate_id: affiliate_user_2.id).each.with_index do |affiliate, idx|
        affiliate.update_columns(affiliate_basis_points: 2000 + 100 * idx)
      end
      ProductAffiliate.where(affiliate_id: affiliate_user_3.id).each.with_index do |affiliate, idx|
        affiliate.update_columns(affiliate_basis_points: 1000 + 100 * idx)
      end

      create_list(:purchase_with_balance, 2, link: product1, affiliate_credit_cents: 100, affiliate: affiliate_user_1)
      create_list(:purchase_with_balance, 3, link: product2, affiliate_credit_cents: 100, affiliate: affiliate_user_2)
      create(:purchase_with_balance, link: product3, affiliate_credit_cents: 100, affiliate: affiliate_user_3)
    end

    it "returns affiliates sorted by the affiliate user's name" do
      order = [affiliate_user_1, affiliate_user_2, affiliate_user_3]

      expect(seller.direct_affiliates.sorted_by(key: "affiliate_user_name", direction: "asc")).to eq(order)
      expect(seller.direct_affiliates.sorted_by(key: "affiliate_user_name", direction: "desc")).to eq(order.reverse)
    end

    context "affiliate username is their external_id because a custom username has not been set" do
      it "returns affiliates sorted by the affiliate user's unconfirmed e-mail if present" do
        affiliate_user_1.affiliate_user.update_columns(name: nil, username: nil, unconfirmed_email: "bob@example.com", email: nil)
        affiliate_user_2.affiliate_user.update_columns(name: nil, username: nil, unconfirmed_email: "charlie@example.com", email: nil)
        affiliate_user_3.affiliate_user.update_columns(name: nil, username: nil, unconfirmed_email: "alice@example.com", email: nil)
        order = [affiliate_user_3, affiliate_user_1, affiliate_user_2]

        expect(seller.direct_affiliates.sorted_by(key: "affiliate_user_name", direction: "asc")).to eq(order)
        expect(seller.direct_affiliates.sorted_by(key: "affiliate_user_name", direction: "desc")).to eq(order.reverse)
      end

      it "returns affiliates sorted by the affiliate user's e-mail if unconfirmed e-mail is not present" do
        affiliate_user_1.affiliate_user.update_columns(name: nil, username: nil, email: "bob@example.com", unconfirmed_email: nil)
        affiliate_user_2.affiliate_user.update_columns(name: nil, username: nil, email: "charlie@example.com", unconfirmed_email: nil)
        affiliate_user_3.affiliate_user.update_columns(name: nil, username: nil, email: "alice@example.com", unconfirmed_email: nil)
        order = [affiliate_user_3, affiliate_user_1, affiliate_user_2]

        expect(seller.direct_affiliates.sorted_by(key: "affiliate_user_name", direction: "asc")).to eq(order)
        expect(seller.direct_affiliates.sorted_by(key: "affiliate_user_name", direction: "desc")).to eq(order.reverse)
      end
    end

    it "returns affiliates sorted by the affiliate user's username if name is not present and a custom username is set" do
      affiliate_user_1.affiliate_user.update_columns(name: nil, email: nil, username: "charlie", unconfirmed_email: nil)
      affiliate_user_2.affiliate_user.update_columns(name: nil, email: nil, username: "bob", unconfirmed_email: nil)
      affiliate_user_3.affiliate_user.update_columns(name: nil, email: nil, username: "alice", unconfirmed_email: nil)
      order = [affiliate_user_3, affiliate_user_2, affiliate_user_1]

      expect(seller.direct_affiliates.sorted_by(key: "affiliate_user_name", direction: "asc")).to eq(order)
      expect(seller.direct_affiliates.sorted_by(key: "affiliate_user_name", direction: "desc")).to eq(order.reverse)
    end

    it "returns affiliates sorted by # of products" do
      order = [affiliate_user_1, affiliate_user_3, affiliate_user_2]

      expect(seller.direct_affiliates.sorted_by(key: "products", direction: "asc")).to eq(order)
      expect(seller.direct_affiliates.sorted_by(key: "products", direction: "desc")).to eq(order.reverse)
    end

    it "returns affiliates sorted by the lowest product commission percentage" do
      order = [affiliate_user_3, affiliate_user_2, affiliate_user_1]

      expect(seller.direct_affiliates.sorted_by(key: "fee_percent", direction: "asc")).to eq(order)
      expect(seller.direct_affiliates.sorted_by(key: "fee_percent", direction: "desc")).to eq(order.reverse)
    end

    it "returns affiliates sorted by total sales" do
      order = [affiliate_user_3, affiliate_user_1, affiliate_user_2]

      expect(seller.direct_affiliates.sorted_by(key: "volume_cents", direction: "asc")).to eq(order)
      expect(seller.direct_affiliates.sorted_by(key: "volume_cents", direction: "desc")).to eq(order.reverse)
    end
  end
end
