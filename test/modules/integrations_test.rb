# frozen_string_literal: true

require "test_helper"

class IntegrationsTest < ActiveSupport::TestCase
  self.described_class = Integrations



  context_ Integrations do
  context_ "#find_integration_by_name" do
  context_ "when called on a Link record" do
        # TODO: Change one of the integrations to have a different type after newer ones are added
  test "returns the first integration of the given type" do
          integration_1 = create(:circle_integration)
          product = create(:product, active_integrations: [integration_1, create(:circle_integration)])

          expect(product.find_integration_by_name(Integration::CIRCLE)).to eq(integration_1)
        end
      end

  context_ "when called on a Base Variant record" do
        # TODO: Change one of the integrations to have a different type after newer ones are added
  test "returns the first integration of the given type" do
          integration_1 = create(:circle_integration)
          category = create(:variant_category, title: "versions", link: create(:product))
          variant = create(:variant, variant_category: category, name: "v1", active_integrations: [integration_1, create(:circle_integration)])

          expect(variant.find_integration_by_name(Integration::CIRCLE)).to eq(integration_1)
        end
      end
    end
  end
end
