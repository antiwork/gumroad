# frozen_string_literal: true

require "spec_helper"

describe HomePageLinkService do
  shared_examples_for "home page link" do |page|
    describe ".#{page}" do
      it "returns the full URL of the page" do
        expect(described_class.public_send(page)).to eq "#{UrlService.root_domain_with_protocol}/#{page}"
      end
    end
  end

  [:privacy, :terms, :about, :features, :university, :pricing, :affiliates, :prohibited].each do |page|
    include_examples "home page link", page
  end

  describe ".root" do
    it "returns root domain with protocol" do
      expect(described_class.root).to eq UrlService.root_domain_with_protocol
    end
  end
end
