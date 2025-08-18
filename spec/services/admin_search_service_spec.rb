# frozen_string_literal: true

require "spec_helper"

describe AdminSearchService do
  describe "#search_purchases" do
    it "returns no Purchases if query is invalid" do
      purchases = AdminSearchService.new.search_purchases(query: "invalidquery")

      expect(purchases.size).to eq(0)
    end

    it "returns purchases matching email, directly and through gifts" do
      email = "user@example.com"
      purchase_1 = create(:purchase, email:)
      purchase_2 = create(:gift, gifter_email: email, gifter_purchase: create(:purchase)).gifter_purchase
      purchase_3 = create(:gift, giftee_email: email, giftee_purchase: create(:purchase)).giftee_purchase

      purchases = AdminSearchService.new.search_purchases(query: email)
      expect(purchases).to include(purchase_1, purchase_2, purchase_3)
    end

    it "returns purchases for products created by a seller" do
      seller = create(:user, email: "seller@example.com")
      purchase = create(:purchase, link: create(:product, user: seller))
      create(:purchase)

      purchases = AdminSearchService.new.search_purchases(creator_email: seller.email)
      expect(purchases).to eq([purchase])
    end

    it "returns no purchases when creator email is not found" do
      create(:purchase)
      purchases = AdminSearchService.new.search_purchases(creator_email: "nonexistent@example.com")
      expect(purchases.size).to eq(0)
    end

    it "returns purchase associated with a license key" do
      purchase = create(:purchase)
      license = create(:license, purchase:)
      create(:purchase)

      purchases = AdminSearchService.new.search_purchases(license_key: license.serial)
      expect(purchases).to eq([purchase])
    end

    it "returns no purchases when license key is not found" do
      create(:purchase)
      purchases = AdminSearchService.new.search_purchases(license_key: "nonexistent-key")
      expect(purchases.size).to eq(0)
    end

    describe "searching by card" do
      let(:purchase_visa) do
        create(:purchase,
               card_type: "visa",
               card_visual: "**** **** **** 1234",
               created_at: Time.zone.local(2019, 1, 17, 1, 2, 3),
               price_cents: 777,
               card_expiry_year: 2022,
               card_expiry_month: 10)
      end

      let(:purchase_amex) do
        create(:purchase,
               card_type: "amex",
               card_visual: "**** ****** *7531",
               created_at: Time.zone.local(2019, 2, 22, 1, 2, 3),
               price_cents: 1337,
               card_expiry_year: 2021,
               card_expiry_month: 7)
      end

      context "when transaction_date value is not a date" do
        it "raises an error" do
          expect do
            AdminSearchService.new.search_purchases(transaction_date: "2021-01", card_type: "other")
          end.to raise_error(AdminSearchService::InvalidDateError)
        end
      end

      it "supports filtering by card_type" do
        purchases = AdminSearchService.new.search_purchases(card_type: "visa")
        expect(purchases).to eq [purchase_visa]
      end

      it "supports filtering by card_visual" do
        purchases = AdminSearchService.new.search_purchases(last_4: "7531")
        expect(purchases).to eq [purchase_amex]
      end

      it "supports filtering by expiry date" do
        purchases = AdminSearchService.new.search_purchases(expiry_date: "7/21")
        expect(purchases).to eq [purchase_amex]
      end

      it "supports filtering by price" do
        purchases = AdminSearchService.new.search_purchases(price: "7")
        expect(purchases).to eq [purchase_visa]
      end

      it "supports filtering by decimal price" do
        purchase_decimal = create(:purchase, price_cents: 1999, stripe_fingerprint: "test_fingerprint")
        purchases = AdminSearchService.new.search_purchases(price: "19.99")
        expect(purchases).to eq [purchase_decimal]
      end

      it "supports filtering by combination of params" do
        purchases = AdminSearchService.new.search_purchases(card_type: "visa", last_4: "1234", price: "7", transaction_date: "2019-01-17", expiry_date: "10/22")
        expect(purchases).to eq [purchase_visa]
      end
    end

    describe "searching by ip_address" do
      let(:ip_v4) { "203.0.113.42" }
      let(:ip_v6) { "2001:db8::1" }
      let(:other_ip) { "198.51.100.10" }

      it "returns purchases matching ip_address" do
        purchase_from_ip_v4 = create(:purchase, ip_address: ip_v4)
        purchase_from_ip_v6 = create(:purchase, ip_address: ip_v6)

        purchases = AdminSearchService.new.search_purchases(query: ip_v4)
        expect(purchases).to contain_exactly(purchase_from_ip_v4)

        purchases = AdminSearchService.new.search_purchases(query: ip_v6)
        expect(purchases).to contain_exactly(purchase_from_ip_v6)

        purchases = AdminSearchService.new.search_purchases(query: other_ip)
        expect(purchases).to be_empty
      end
    end
  end
end
