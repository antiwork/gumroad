# frozen_string_literal: true

require "spec_helper"

describe TaxjarApi, :vcr do
  let(:origin) do
    {
      country: "US",
      state: "CA",
      zip: "94104"
    }
  end

  let(:destination) do
    {
      country: "US",
      state: "CA",
      zip: "94107"
    }
  end

  let(:nexus_address) do
    {
      country: "US",
      state: "CA"
    }
  end

  let(:expected_calculation) do
    {
      "order_total_amount" => 120.0,
      "shipping" => 20.0,
      "taxable_amount" => 100.0,
      "amount_to_collect" => 8.63,
      "rate" => 0.08625,
      "has_nexus" => true,
      "freight_taxable" => false,
      "tax_source" => "destination",
      "jurisdictions" => {
        "country" => "US",
        "state" => "CA",
        "county" => "SAN FRANCISCO",
        "city" => "SAN FRANCISCO"
      },
      "breakdown" => {
        "taxable_amount" => 100.0,
        "tax_collectable" => 8.63,
        "combined_tax_rate" => 0.08625,
        "state_taxable_amount" => 100.0,
        "state_tax_rate" => 0.0625,
        "state_tax_collectable" => 6.25,
        "county_taxable_amount" => 100.0,
        "county_tax_rate" => 0.01,
        "county_tax_collectable" => 1.0,
        "city_taxable_amount" => 0.0,
        "city_tax_rate" => 0.0,
        "city_tax_collectable" => 0.0,
        "special_district_taxable_amount" => 100.0,
        "special_tax_rate" => 0.01375,
        "special_district_tax_collectable" => 1.38,
        "line_items" => [
          {
            "id" => "1",
            "taxable_amount" => 100.0,
            "tax_collectable" => 8.63,
            "combined_tax_rate" => 0.08625,
            "state_taxable_amount" => 100.0,
            "state_sales_tax_rate" => 0.0625,
            "state_amount" => 6.25,
            "county_taxable_amount" => 100.0,
            "county_tax_rate" => 0.01,
            "county_amount" => 1.0,
            "city_taxable_amount" => 0.0,
            "city_tax_rate" => 0.0,
            "city_amount" => 0.0,
            "special_district_taxable_amount" => 100.0,
            "special_tax_rate" => 0.01375,
            "special_district_amount" => 1.38
          }
        ]
      }
    }
  end

  let(:expected_calculation_digital_product) do
    {
      "order_total_amount" => 120.0,
      "shipping" => 20.0,
      "taxable_amount" => 0.0,
      "amount_to_collect" => 0.0,
      "rate" => 0.0,
      "has_nexus" => true,
      "freight_taxable" => false,
      "tax_source" => "destination",
      "jurisdictions" => {
        "country" => "US",
        "state" => "CA",
        "county" => "SAN FRANCISCO",
        "city" => "SAN FRANCISCO"
      },
      "breakdown" => {
        "taxable_amount" => 0.0,
        "tax_collectable" => 0.0,
        "combined_tax_rate" => 0.0,
        "state_taxable_amount" => 0.0,
        "state_tax_rate" => 0.0,
        "state_tax_collectable" => 0.0,
        "county_taxable_amount" => 0.0,
        "county_tax_rate" => 0.0,
        "county_tax_collectable" => 0.0,
        "city_taxable_amount" => 0.0,
        "city_tax_rate" => 0.0,
        "city_tax_collectable" => 0.0,
        "special_district_taxable_amount" => 0.0,
        "special_tax_rate" => 0.0,
        "special_district_tax_collectable" => 0.0,
        "line_items" => [
          {
            "id" => "1",
            "taxable_amount" => 0.0,
            "tax_collectable" => 0.0,
            "combined_tax_rate" => 0.0,
            "state_taxable_amount" => 0.0,
            "state_sales_tax_rate" => 0.0,
            "state_amount" => 0.0,
            "county_taxable_amount" => 0.0,
            "county_tax_rate" => 0.0,
            "county_amount" => 0.0,
            "city_taxable_amount" => 0.0,
            "city_tax_rate" => 0.0,
            "city_amount" => 0.0,
            "special_district_taxable_amount" => 0.0,
            "special_tax_rate" => 0.0,
            "special_district_amount" => 0.0
          }
        ]
      }
    }
  end

  let(:expected_calculation_quantity_three) do
    {
      "order_total_amount" => 320.0,
      "shipping" => 20.0,
      "taxable_amount" => 300.0,
      "amount_to_collect" => 25.88,
      "rate" => 0.08625,
      "has_nexus" => true,
      "freight_taxable" => false,
      "tax_source" => "destination",
      "jurisdictions" => {
        "country" => "US",
        "state" => "CA",
        "county" => "SAN FRANCISCO",
        "city" => "SAN FRANCISCO"
      },
      "breakdown" => {
        "taxable_amount" => 300.0,
        "tax_collectable" => 25.88,
        "combined_tax_rate" => 0.08625,
        "state_taxable_amount" => 300.0,
        "state_tax_rate" => 0.0625,
        "state_tax_collectable" => 18.75,
        "county_taxable_amount" => 300.0,
        "county_tax_rate" => 0.01,
        "county_tax_collectable" => 3.0,
        "city_taxable_amount" => 0.0,
        "city_tax_rate" => 0.0,
        "city_tax_collectable" => 0.0,
        "special_district_taxable_amount" => 300.0,
        "special_tax_rate" => 0.01375,
        "special_district_tax_collectable" => 4.13,
        "line_items" => [
          {
            "id" => "1",
            "taxable_amount" => 300.0,
            "tax_collectable" => 25.88,
            "combined_tax_rate" => 0.08625,
            "state_taxable_amount" => 300.0,
            "state_sales_tax_rate" => 0.0625,
            "state_amount" => 18.75,
            "county_taxable_amount" => 300.0,
            "county_tax_rate" => 0.01,
            "county_amount" => 3.0,
            "city_taxable_amount" => 0.0,
            "city_tax_rate" => 0.0,
            "city_amount" => 0.0,
            "special_district_taxable_amount" => 300.0,
            "special_tax_rate" => 0.01375,
            "special_district_amount" => 4.13
          }
        ]
      }
    }
  end

  let(:expected_create_order_transaction_response) do
    {
      "transaction_id" => "G_-mnBf9b1j9A7a4ub4nFQ==",
      "user_id" => 126159,
      "provider" => "api",
      "transaction_date" => "2023-08-28T20:06:20.000Z",
      "transaction_reference_id" => nil,
      "customer_id" => nil,
      "exemption_type" => nil,
      "from_country" => "US",
      "from_zip" => "94104",
      "from_state" => "CA",
      "from_city" => nil,
      "from_street" => nil,
      "to_country" => "US",
      "to_zip" => "19106",
      "to_state" => "PA",
      "to_city" => nil,
      "to_street" => nil,
      "amount" => "15.0",
      "shipping" => "5.0",
      "sales_tax" => "1.0",
      "line_items" =>
      [
        {
          "id" => 0,
          "quantity" => 1,
          "product_identifier" => nil,
          "product_tax_code" => "31000",
          "description" => nil,
          "unit_price" => "10.0",
          "discount" => "0.0",
          "sales_tax" => "1.0"
        }
      ]
    }
  end

  describe "#calculate_tax_for_order" do
    it "calculates the tax" do
      expect(described_class.new.calculate_tax_for_order(origin:,
                                                         destination:,
                                                         nexus_address:,
                                                         quantity: 1,
                                                         product_tax_code: nil,
                                                         unit_price_dollars: 100.0,
                                                         shipping_dollars: 20.0)).to eq(expected_calculation)
    end

    it "calculates the tax for quantity greater than 1" do
      expect(described_class.new.calculate_tax_for_order(origin:,
                                                         destination:,
                                                         nexus_address:,
                                                         quantity: 3,
                                                         product_tax_code: nil,
                                                         unit_price_dollars: 100.0,
                                                         shipping_dollars: 20.0)).to eq(expected_calculation_quantity_three)
    end

    it "calculates the tax for product tax code 31000" do
      expect(described_class.new.calculate_tax_for_order(origin:,
                                                         destination:,
                                                         nexus_address:,
                                                         quantity: 1,
                                                         product_tax_code: "31000",
                                                         unit_price_dollars: 100.0,
                                                         shipping_dollars: 20.0)).to eq(expected_calculation_digital_product)
    end

    it "caches the response and returns a cache hit on the next request" do
      expect(described_class.new.calculate_tax_for_order(origin:,
                                                         destination:,
                                                         nexus_address:,
                                                         quantity: 1,
                                                         product_tax_code: nil,
                                                         unit_price_dollars: 100.0,
                                                         shipping_dollars: 20.0)).to eq(expected_calculation)

      expect_any_instance_of(Taxjar::Client).to_not receive(:tax_for_order)

      expect(described_class.new.calculate_tax_for_order(origin:,
                                                         destination:,
                                                         nexus_address:,
                                                         quantity: 1,
                                                         product_tax_code: nil,
                                                         unit_price_dollars: 100.0,
                                                         shipping_dollars: 20.0)).to eq(expected_calculation)
    end

    it "notifies Bugsnag and propagates a TaxJar client error" do
      expect_any_instance_of(Taxjar::Client).to receive(:tax_for_order).and_raise(Taxjar::Error::BadRequest)

      expect(Bugsnag).to receive(:notify).exactly(:once)

      expect do
        described_class.new.calculate_tax_for_order(origin:,
                                                    destination: destination.except(:zip),
                                                    nexus_address:,
                                                    quantity: 1,
                                                    product_tax_code: nil,
                                                    unit_price_dollars: 100.0,
                                                    shipping_dollars: 20.0)
      end.to raise_error(Taxjar::Error::BadRequest)
    end

    it "propagates a TaxJar server error" do
      allow_any_instance_of(Taxjar::Client).to receive(:tax_for_order).and_raise(Taxjar::Error::InternalServerError)

      expect do
        described_class.new.calculate_tax_for_order(origin:,
                                                    destination:,
                                                    nexus_address:,
                                                    quantity: 1,
                                                    product_tax_code: nil,
                                                    unit_price_dollars: 100.0,
                                                    shipping_dollars: 20.0)
      end.to raise_error(Taxjar::Error::InternalServerError)
    end
  end

  describe "#create_order_transaction" do
    it "creates an order transaction in TaxJar" do
      expect(described_class.new.create_order_transaction(transaction_id: "G_-mnBf9b1j9A7a4ub4nFQ==",
                                                          transaction_date: "2023-08-28T20:06:20Z",
                                                          destination: { country: "US", state: "PA", zip: "19106" },
                                                          quantity: 1,
                                                          product_tax_code: "31000",
                                                          amount_dollars: 15.0,
                                                          shipping_dollars: 5.0,
                                                          sales_tax_dollars: 1.0,
                                                          unit_price_dollars: 10.0)).to eq(expected_create_order_transaction_response)
    end
  end
end
