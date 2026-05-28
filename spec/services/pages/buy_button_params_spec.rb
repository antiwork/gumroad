# frozen_string_literal: true

require "spec_helper"

describe Pages::BuyButtonParams do
  def node_for(html)
    Nokogiri::HTML.fragment(html).at('[data-gumroad-action="buy"]')
  end

  describe ".from" do
    context "with a simple product (no variants, no PWYW, no quantity, no recurrence)" do
      let(:product) { create(:product, price_cents: 100) }

      it "returns an empty hash when no selection attributes are set" do
        result = described_class.from(node_for(%(<a data-gumroad-action="buy">Buy</a>)), product:)
        expect(result).to eq({})
      end

      it "drops every selection attribute the product can't honor" do
        node = node_for(%(<a data-gumroad-action="buy"
                            data-gumroad-option="Pro"
                            data-gumroad-quantity="2"
                            data-gumroad-price="9.99"
                            data-gumroad-recurrence="yearly">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end
    end

    context "variant (data-gumroad-option)" do
      let(:product) do
        product = create(:product_with_digital_versions)
        product.alive_variants.first.update!(name: "Pro plan")
        product
      end

      it "passes through a name that matches one of the product's variants" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-option="Pro plan">Buy</a>))
        expect(described_class.from(node, product:)).to eq(variant: "Pro plan")
      end

      it "drops a variant name the product doesn't have" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-option="Mystery">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end

      it "drops the attribute when blank" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-option="">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end
    end

    context "quantity (data-gumroad-quantity)" do
      let(:product) { create(:product, quantity_enabled: true) }

      it "passes through a positive integer when quantity is enabled" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-quantity="3">Buy</a>))
        expect(described_class.from(node, product:)).to eq(quantity: 3)
      end

      it "drops the attribute when quantity isn't enabled on the product" do
        product = create(:product, quantity_enabled: false)
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-quantity="3">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end

      it "drops a non-integer value" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-quantity="lots">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end

      it "drops a quantity below 1" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-quantity="0">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end

      it "drops a quantity above the product's max_purchase_count" do
        product.update!(max_purchase_count: 5)
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-quantity="6">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end
    end

    context "PWYW price (data-gumroad-price)" do
      let(:product) { create(:product, customizable_price: true, price_cents: 500) }

      it "passes through a price at or above the minimum" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-price="9.99">Buy</a>))
        expect(described_class.from(node, product:)).to eq(price: 9.99)
      end

      it "drops the attribute when the product isn't pay-what-you-want" do
        product = create(:product, customizable_price: false, price_cents: 500)
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-price="9.99">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end

      it "drops a price below the product's minimum" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-price="2.50">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end

      it "drops a non-numeric value" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-price="free">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end
    end

    context "recurrence (data-gumroad-recurrence)" do
      let(:product) { create(:membership_product_with_preset_tiered_pricing) }

      it "passes through a recurrence the product offers" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-recurrence="monthly">Buy</a>))
        expect(described_class.from(node, product:)).to eq(recurrence: "monthly")
      end

      it "drops a recurrence the product doesn't offer" do
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-recurrence="weekly">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end

      it "drops the attribute on a non-recurring product" do
        product = create(:product)
        node = node_for(%(<a data-gumroad-action="buy" data-gumroad-recurrence="monthly">Buy</a>))
        expect(described_class.from(node, product:)).to eq({})
      end
    end

    context "multiple attributes together" do
      let(:product) do
        product = create(:product_with_digital_versions, quantity_enabled: true)
        product.alive_variants.first.update!(name: "Pro plan")
        product
      end

      it "returns the validated subset, dropping invalid entries alongside valid ones" do
        node = node_for(%(<a data-gumroad-action="buy"
                            data-gumroad-option="Pro plan"
                            data-gumroad-quantity="2"
                            data-gumroad-recurrence="yearly">Buy</a>))
        expect(described_class.from(node, product:)).to eq(variant: "Pro plan", quantity: 2)
      end
    end
  end
end
