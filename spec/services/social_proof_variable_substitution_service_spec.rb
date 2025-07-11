# frozen_string_literal: true

require 'rails_helper'

describe SocialProofVariableSubstitutionService do
  let(:user) { create(:user) }
  let(:product) { create(:product, user: user, name: "Test Product", price_cents: 2999) }
  let(:widget) { create(:social_proof_widget,
                       user: user,
                       title: "Join {total_sales} customers who bought {product} for {price}!",
                       description: "Recently, {customer} from {country} purchased this",
                       cta_text: "Join {recent_sales} recent buyers") }

  before do
    widget.links = [product]
    # Create some purchases for the product
    create_list(:purchase, 15, link: product, purchase_state: "successful")
    create_list(:purchase, 5, link: product, purchase_state: "successful", created_at: 3.days.ago)
  end

  describe '#substitute_variables' do
    it 'replaces variables with actual values' do
      service = described_class.new(widget: widget, context: { product: product })

      result = service.substitute_variables("Join {total_sales} customers!")
      expect(result).to eq("Join 20 customers!")
    end

    it 'handles missing variables gracefully' do
      service = described_class.new(widget: widget, context: { product: product })

      result = service.substitute_variables("Join {unknown_variable} customers!")
      expect(result).to eq("Join {unknown_variable} customers!")
    end

    it 'returns original text when blank' do
      service = described_class.new(widget: widget, context: { product: product })

      expect(service.substitute_variables("")).to eq("")
      expect(service.substitute_variables(nil)).to eq(nil)
    end
  end

  describe '#processed_widget_data' do
    it 'processes all widget text fields' do
      service = described_class.new(widget: widget, context: {
        product: product,
        customer_name: "John",
        customer_country: "United States"
      })

      result = service.processed_widget_data

      expect(result[:title]).to eq("Join 20 customers who bought Test Product for $29.99!")
      expect(result[:description]).to eq("Recently, John from United States purchased this")
      expect(result[:cta_text]).to eq("Join 5 recent buyers")
    end
  end

  describe 'variable substitution' do
    let(:service) { described_class.new(widget: widget, context: { product: product }) }

    it 'substitutes total_sales correctly' do
      result = service.substitute_variables("{total_sales}")
      expect(result).to eq("20")
    end

    it 'substitutes recent_sales correctly' do
      result = service.substitute_variables("{recent_sales}")
      expect(result).to eq("5")
    end

    it 'substitutes product name correctly' do
      result = service.substitute_variables("{product}")
      expect(result).to eq("Test Product")
    end

    it 'substitutes product in complete sentence' do
      result = service.substitute_variables("Check out {product} for only {price}!")
      expect(result).to eq("Check out Test Product for only $29.99!")
    end

    it 'substitutes price correctly' do
      result = service.substitute_variables("{price}")
      expect(result).to eq("$29.99")
    end

    it 'uses context values when provided' do
      service = described_class.new(widget: widget, context: {
        product: product,
        customer_name: "Jane",
        customer_country: "Canada"
      })

      expect(service.substitute_variables("{customer}")).to eq("Jane")
      expect(service.substitute_variables("{country}")).to eq("Canada")
    end

    it 'falls back to defaults when context not provided' do
      service = described_class.new(widget: widget, context: { product: product })

      expect(service.substitute_variables("{customer}")).to eq("someone")
      expect(service.substitute_variables("{country}")).to eq("somewhere")
    end
  end

  describe 'universal widgets' do
    let(:universal_widget) { create(:social_proof_widget,
                                   user: user,
                                   title: "Join {total_sales} customers!",
                                   universal: true) }
    let(:product2) { create(:product, user: user) }

    before do
      create_list(:purchase, 10, link: product, purchase_state: "successful")
      create_list(:purchase, 5, link: product2, purchase_state: "successful")
    end

    it 'calculates total sales across all user products for universal widgets' do
      service = described_class.new(widget: universal_widget, context: {})

      result = service.substitute_variables("{total_sales}")
      expect(result).to eq("15")
    end
  end
end
