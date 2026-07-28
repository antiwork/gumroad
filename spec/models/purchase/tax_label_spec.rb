# frozen_string_literal: true

require "spec_helper"

describe "Purchase tax labels" do
  # The name of the tax comes from the buyer's country on the applied ZipTaxRate. These specs pin
  # the wording per country, because the receipt is the copy the buyer keeps and it has to agree
  # with what the checkout page told them.
  def purchase_taxed_in(country, rate: 0.18, tax_excluded_from_price: true)
    zip_tax_rate = create(:zip_tax_rate, country:, state: nil, zip_code: nil, combined_rate: rate)
    build(
      :purchase,
      zip_tax_rate:,
      was_purchase_taxable: true,
      was_tax_excluded_from_price: tax_excluded_from_price,
      gumroad_tax_cents: 180
    )
  end

  describe "#tax_label" do
    it "calls the tax GST for India" do
      expect(purchase_taxed_in("IN").tax_label).to eq("GST (18%)")
    end

    it "calls the tax GST for New Zealand" do
      expect(purchase_taxed_in("NZ", rate: 0.15).tax_label).to eq("GST (15%)")
    end

    it "calls the tax GST for Australia and Singapore" do
      expect(purchase_taxed_in("AU", rate: 0.1).tax_label).to eq("GST (10%)")
      expect(purchase_taxed_in("SG", rate: 0.09).tax_label).to eq("GST (9%)")
    end

    it "calls the tax CT for Japan" do
      expect(purchase_taxed_in("JP", rate: 0.1).tax_label).to eq("CT (10%)")
    end

    it "calls the tax service tax for Malaysia" do
      expect(purchase_taxed_in("MY", rate: 0.08).tax_label).to eq("Service tax (8%)")
    end

    it "still calls the tax VAT in the EU, the UK and Norway" do
      expect(purchase_taxed_in("DE", rate: 0.19).tax_label).to eq("VAT (19%)")
      expect(purchase_taxed_in("GB", rate: 0.2).tax_label).to eq("VAT (20%)")
      expect(purchase_taxed_in("NO", rate: 0.25).tax_label).to eq("VAT (25%)")
    end

    it "still calls the tax VAT in other countries that collect tax on digital products" do
      expect(purchase_taxed_in("ZA", rate: 0.15).tax_label).to eq("VAT (15%)")
    end

    it "omits the rate when asked" do
      expect(purchase_taxed_in("IN").tax_label(include_tax_rate: false)).to eq("GST")
    end

    it "keeps calling US tax sales tax" do
      purchase = purchase_taxed_in("US", rate: 0.01, tax_excluded_from_price: false)
      expect(purchase.tax_label).to eq("Sales tax (included)")
    end

    it "falls back to sales tax when there is no rate row to read a country from" do
      # has_tax_label? is also satisfied by gumroad_tax_cents alone, so the label has to cope
      # with a taxable purchase that has no zip_tax_rate rather than blowing up on nil.
      purchase = build(:purchase, zip_tax_rate: nil, was_purchase_taxable: true, gumroad_tax_cents: 180)
      expect(purchase.tax_label).to eq("Sales tax (included)")
    end
  end

  describe "#seller_tax_label" do
    it "uses the same per-country naming the buyer sees" do
      expect(purchase_taxed_in("IN").seller_tax_label).to eq("GST")
      expect(purchase_taxed_in("JP").seller_tax_label).to eq("CT")
      expect(purchase_taxed_in("MY").seller_tax_label).to eq("Service tax")
    end

    it "keeps the EU and Norway prefixes that tell the seller which regime applied" do
      expect(purchase_taxed_in("DE").seller_tax_label).to eq("EU VAT")
      expect(purchase_taxed_in("NO").seller_tax_label).to eq("Norway VAT")
    end

    it "marks the tax as included when it was not added on top of the price" do
      purchase = purchase_taxed_in("IN", tax_excluded_from_price: false)
      expect(purchase.seller_tax_label).to eq("GST (included)")
    end

    it "treats a purchase that never recorded the flag as tax-included" do
      # was_tax_excluded_from_price is nil on older rows, which has always meant "included".
      purchase = purchase_taxed_in("IN", tax_excluded_from_price: nil)
      expect(purchase.seller_tax_label).to eq("GST (included)")
    end
  end
end
