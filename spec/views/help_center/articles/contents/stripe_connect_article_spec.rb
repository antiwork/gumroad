# frozen_string_literal: true

require "spec_helper"

describe "Stripe Connect help article" do
  let(:text) { HelpCenter::ArticleText.plain_text(HelpCenter::Article.find_by!(slug: "330-stripe-connect")).squish }

  it "says we handle disputes and respond through the connected account" do
    expect(text).not_to include("Gumroad will no longer fight disputes on your behalf")
    expect(text).to include("We handle disputes on your Stripe Connect sales the same way as on other card sales, and submit any response through your connected Stripe account.")
    expect(text).to include("rather than responding in your Stripe dashboard: our payment processor accepts only one response per dispute.")
  end
end
