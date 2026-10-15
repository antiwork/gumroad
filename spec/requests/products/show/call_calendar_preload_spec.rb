# frozen_string_literal: true

require "spec_helper"

describe "Product page calendar preload", type: :request do
  def calendar_preload
    Nokogiri::HTML(response.body).at_css('link[rel="modulepreload"][href*="/Calendar"]')
  end

  it "preloads the calendar on a call product's page" do
    product = create(:call_product, :available_for_a_year)

    get product.long_url

    expect(response).to be_successful
    expect(calendar_preload).to be_present
  end

  it "does not preload the calendar for other products" do
    product = create(:product)

    get product.long_url

    expect(response).to be_successful
    expect(calendar_preload).to be_nil
  end
end
