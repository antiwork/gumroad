# frozen_string_literal: true

require "spec_helper"

describe Admin::ProductPresenter::MultipleMatches do
  describe "#props" do
    let(:user) { create(:user, name: "Test User") }
    let(:product) { create(:product, user:, name: "Test Product") }
    let(:presenter) { described_class.new(product:) }

    subject(:props) { presenter.props }

    describe "basic structure" do
      it "returns a hash with all expected keys" do
        expect(props).to include(
          :external_id,
          :name,
          :created_at,
          :long_url,
          :price_formatted,
          :user
        )
      end
    end

    describe "fields" do
      it "returns the correct field values" do
        expect(props[:external_id]).to eq(product.external_id)
        expect(props[:name]).to eq(product.name)
        expect(props[:created_at]).to eq(product.created_at)
        expect(props[:long_url]).to eq(product.long_url)
        expect(props[:price_formatted]).to eq(product.price_formatted)
      end
    end

    describe "user association" do
      it "returns user information" do
        expect(props[:user]).to eq(
          external_id: user.external_id,
          name: user.name
        )
      end

      it "returns the correct user external_id and name" do
        expect(props[:user][:external_id]).to eq(user.external_id)
        expect(props[:user][:name]).to eq("Test User")
      end
    end
  end
end
