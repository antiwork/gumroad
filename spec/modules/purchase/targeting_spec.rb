# frozen_string_literal: true

require "spec_helper"

describe Purchase::Targeting do
  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @product2 = create(:product, user: @seller)
    @product3 = create(:product, user: @seller)
    @purchase1 = create(:purchase, price_cents: 500, link: @product, created_at: 1.week.ago)
    @purchase2 = create(:purchase, price_cents: 100, link: @product, email: "anish@gumroad.com", created_at: 2.weeks.ago)
    @purchase3 = create(:purchase, price_cents: 1000, link: @product2, created_at: 1.week.ago)
    @purchase4 = create(:purchase, price_cents: 900, link: @product2, email: "anish@gumroad.com", created_at: 2.weeks.ago)
    @purchase5 = create(:purchase, price_cents: 800, link: @product2, email: "anish2@gumroad.com", created_at: 3.weeks.ago)
    @purchase6 = create(:purchase, price_cents: 2500, link: @product3, created_at: 1.week.ago)
    @purchase7 = create(:purchase, price_cents: 2000, link: @product3, email: "anish@gumroad.com", created_at: 2.weeks.ago)
    @purchase8 = create(:purchase, link: @product3, email: "anish3@gumroad.com", created_at: 3.weeks.ago)
  end

  describe "#by_variant" do
    before do
      category = create(:variant_category, title: "title", link: @product)
      @variant1 = create(:variant, variant_category: category, name: "V1")
      @variant2 = create(:variant, variant_category: category, name: "V2")

      @purchase1.variant_attributes << @variant1
      @purchase2.variant_attributes << @variant2
    end

    it "does nothing if no variant_id is passed" do
      expect(Purchase.by_variant(nil).count).to eq 8
    end

    it "filters by variant if variant_id is passed" do
      expect(Purchase.by_variant(@variant1.id).count).to eq 1
      expect(Purchase.by_variant(@variant1.id).first).to eq @purchase1
      expect(Purchase.by_variant(@variant2.id).count).to eq 1
      expect(Purchase.by_variant(@variant2.id).first).to eq @purchase2
    end
  end

  describe "#for_products" do
    it "does nothing if no bought products are passed" do
      expect(Purchase.for_products(nil).count).to eq 8
    end

    it "filters by product if only one bought product is passed" do
      expect(Purchase.for_products([@product.id]).count).to eq 2
      expect(Purchase.for_products([@product2.id]).count).to eq 3
    end

    it "filters by multiple products if more than one bought product is passed" do
      expect(Purchase.for_products([@product.id, @product2.id]).count).to eq 5
      expect(Purchase.for_products([@product3.id, @product2.id]).count).to eq 6
      expect(Purchase.for_products([@product.id, @product3.id, @product2.id]).count).to eq 8
    end
  end

  describe "#email_not" do
    it "excludes the purchases made with specific emails" do
      link = create(:product)
      purchase1 = create(:purchase, link:, email: "gum1@gr.co")
      create(:purchase, link: create(:product), email: "gum2@gr.co")
      purchase3 = create(:purchase, link:, email: "gum3@gr.co")
      create(:purchase, link: create(:product), email: "gum4@gr.co")

      result = Purchase.for_products([link.id])
      expect(result.map(&:id)).to match_array([purchase1.id, purchase3.id])
      result = Purchase.for_products([link.id]).email_not(["gum2@gr.co", "gum3@gr.co"])
      expect(result.map(&:id)).to eq([purchase1.id])
    end
  end

  describe "paid" do
    before do
      @purchase8.update_attribute(:price_cents, 0)
    end

    describe "#paid_more_than" do
      it "does nothing if no paid_more_than is passed" do
        expect(Purchase.paid_more_than(nil).count).to eq 8
      end

      it "filters by paid if paid_more_than is passed" do
        expect(Purchase.paid_more_than(100).count).to eq 6
        expect(Purchase.paid_more_than(500).count).to eq 5
        expect(Purchase.paid_more_than(1500).count).to eq 2
        expect(Purchase.paid_more_than(2000).count).to eq 1
        expect(Purchase.paid_more_than(5000).count).to eq 0
      end
    end

    describe "#paid_less_than" do
      it "does nothing if no paid_less_than is passed" do
        expect(Purchase.paid_less_than(nil).count).to eq 8
      end

      it "filters by paid if paid_less_than is passed" do
        expect(Purchase.paid_less_than(100).count).to eq 1
        expect(Purchase.paid_less_than(500).count).to eq 2
        expect(Purchase.paid_less_than(1500).count).to eq 6
        expect(Purchase.paid_less_than(2200).count).to eq 7
        expect(Purchase.paid_less_than(5000).count).to eq 8
      end
    end

    describe "paid between" do
      it "does nothing if no paid_more_than or paid_less_than are passed" do
        expect(Purchase.paid_less_than(nil).paid_more_than(nil).count).to eq 8
      end

      it "filters by paid between if both scopes are applied" do
        expect(Purchase.paid_more_than(0).paid_less_than(100).count).to eq 0
        expect(Purchase.paid_more_than(99).paid_less_than(500).count).to eq 1
        expect(Purchase.paid_more_than(400).paid_less_than(1500).count).to eq 4
        expect(Purchase.paid_more_than(600).paid_less_than(2200).count).to eq 4
        expect(Purchase.paid_more_than(2000).paid_less_than(5000).count).to eq 1
        expect(Purchase.paid_more_than(4000).paid_less_than(5000).count).to eq 0
      end
    end
  end

  describe "created" do
    describe "#created_after" do
      it "does nothing if no date passed" do
        expect(Purchase.created_after(nil).count).to eq 8
      end

      it "filters by created at if date is passed" do
        expect(Purchase.created_after(Date.today - 1.day).count).to eq 0
        expect(Purchase.created_after(Date.today - 8.days).count).to eq 3
        expect(Purchase.created_after(Date.today - 15.days).count).to eq 6
        expect(Purchase.created_after(Date.today - 22.days).count).to eq 8
      end
    end

    describe "#created_before" do
      it "does nothing if no date is passed" do
        expect(Purchase.created_before(nil).count).to eq 8
      end

      it "filters by created at if date is passed" do
        expect(Purchase.created_before(Date.today - 1.day).count).to eq 8
        expect(Purchase.created_before(Date.today - 8.days).count).to eq 5
        expect(Purchase.created_before(Date.today - 15.days).count).to eq 2
        expect(Purchase.created_before(Date.today - 22.days).count).to eq 0
      end
    end

    describe "created between" do
      it "does nothing if no after date or before date are passed" do
        expect(Purchase.created_after(nil).created_before(nil).count).to eq 8
      end

      it "filters by paid between if both scopes are applied" do
        expect(Purchase.created_after(Date.today - 22.days).created_before(Date.today - 1.day).count).to eq 8
        expect(Purchase.created_after(Date.today - 15.days).created_before(Date.today - 8.days).count).to eq 3
        expect(Purchase.created_after(Date.today - 8.days).created_before(Date.today).count).to eq 3
        expect(Purchase.created_after(Date.today - 18.days).created_before(Date.today - 5.days).count).to eq 6
        expect(Purchase.created_after(Date.today - 1.day).created_before(Date.today).count).to eq 0
      end
    end
  end

  describe "#filter_by_country_bought_from" do
    before do
      @purchase1.update_attribute(:country, "United States")
      @purchase2.update_attribute(:country, "Canada")
      @purchase3.update_attribute(:country, "Canada")
      @purchase4.update_attribute(:country, "United States")
      @purchase3.update_attribute(:ip_country, "United States")
      @purchase4.update_attribute(:ip_country, "Canada")
      @purchase5.update_attribute(:country, "Korea, Republic of")
      @purchase6.update_attribute(:country, "South Korea")
    end

    it "does nothing if no bought_from is passed" do
      expect(Purchase.country_bought_from(nil).count).to eq 8
    end

    it "filters by country or ip country if bought_from is passed" do
      expect(Purchase.country_bought_from("United States").count).to eq 2
      expect(Purchase.country_bought_from("United States").include?(@purchase3)).to eq false
      expect(Purchase.country_bought_from("Canada").count).to eq 2
      expect(Purchase.country_bought_from("Canada").include?(@purchase4)).to eq false
    end

    it "filters by country for a country whose name is different for `countries` gem and `iso_country_codes` gem" do
      expect(Purchase.country_bought_from("Korea, Republic of").count).to eq 2
      expect(Purchase.country_bought_from("South Korea").count).to eq 2
    end
  end

  describe "#by_external_variant_ids_or_products" do
    before do
      category = create(:variant_category, link: @product)
      @variant1 = create(:variant, variant_category: category, name: "V1")
      @variant2 = create(:variant, variant_category: category, name: "V2")
      @purchase1.variant_attributes << @variant1
      @purchase2.variant_attributes << @variant2
    end

    it "returns purchases for both products and variants" do
      result = Purchase.by_external_variant_ids_or_products(@variant1.external_id, [@product2.id, @product3.id])
      expect(result).to include(@purchase1, @purchase3, @purchase4, @purchase5, @purchase6, @purchase7, @purchase8)
      expect(result.length).to eq 7
    end

    it "returns purchases for variants if product_ids are blank" do
      result = Purchase.by_external_variant_ids_or_products(@variant2.external_id, nil)
      expect(result).to include(@purchase2)
      expect(result.length).to eq 1
    end

    it "returns purchase for products if external_variant_ids are nil" do
      result = Purchase.by_external_variant_ids_or_products(nil, @product)
      expect(result).to include(@purchase1, @purchase2)
      expect(result.length).to eq 2
    end
  end
end
