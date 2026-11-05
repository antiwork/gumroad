# frozen_string_literal: true

require "spec_helper"

describe "Analytics opt-out meta tag for anonymous visitors", type: :request do
  before { allow(Rails.env).to receive(:production?).and_return(true) }

  let(:seller) { create(:user, username: "optoutseller") }
  let(:product) { create(:product, user: seller) }

  def meta_enabled
    response.body[/gr:google_analytics:enabled" content="(\w+)"/, 1] ||
      response.body[/content="(\w+)"[^>]*gr:google_analytics:enabled/, 1]
  end

  [true, false].each do |opted_out|
    context "when disable_third_party_analytics is #{opted_out}" do
      before { seller.update!(disable_third_party_analytics: opted_out) }

      it "reflects the seller setting on the product page" do
        get "#{seller.subdomain_with_protocol}/l/#{product.unique_permalink}"
        expect(meta_enabled).to eq((!opted_out).to_s)
      end

      it "reflects the seller setting on the profile page" do
        get "#{seller.subdomain_with_protocol}/"
        expect(meta_enabled).to eq((!opted_out).to_s)
      end
    end
  end
end
