# frozen_string_literal: true

require "spec_helper"

describe User::FeatureStatus do
  describe "#merchant_migration_enabled?" do
    let(:user) { create(:user) }

    before { Feature.activate_user(:merchant_migration, user) }

    def stub_representative_country(country)
      create(:user_compliance_info_business, user:, country:, business_country: "United States")
    end

    context "when the representative lives in a Connect-supported country and the business is registered elsewhere" do
      before { create(:user_compliance_info_business, user:, country: "France", business_country: "Algeria") }

      it "routes by the representative country while the flag is off" do
        expect(user.reload.merchant_migration_enabled?).to be(true)
      end

      it "routes by the business country once the flag is on" do
        Feature.activate_user(:stripe_connect_routing_by_legal_entity_country, user)

        expect(user.reload.merchant_migration_enabled?).to be(false)
      end
    end

    context "when the business is registered in a Connect-supported country and the representative lives elsewhere" do
      before { stub_representative_country("Algeria") }

      it "stays disabled while the flag is off" do
        expect(user.reload.merchant_migration_enabled?).to be(false)
      end

      it "is enabled once the flag is on" do
        Feature.activate_user(:stripe_connect_routing_by_legal_entity_country, user)

        expect(user.reload.merchant_migration_enabled?).to be(true)
      end
    end

    it "ignores the flag for an individual account" do
      create(:user_compliance_info, user:, country: "Algeria")
      Feature.activate_user(:stripe_connect_routing_by_legal_entity_country, user)

      expect(user.reload.merchant_migration_enabled?).to be(false)
    end
  end
end
