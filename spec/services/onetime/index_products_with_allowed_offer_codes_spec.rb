# frozen_string_literal: true

require "spec_helper"

describe Onetime::IndexProductsWithAllowedOfferCodes do
  let(:creator) { create(:user) }
  let(:product1) { create(:product, user: creator) }
  let(:product2) { create(:product, user: creator) }
  let(:product3) { create(:product, user: creator) }

  describe ".process", :sidekiq_inline do
    context "elasticsearch indexing", :elasticsearch_wait_for_refresh do
      before do
        Link.__elasticsearch__.create_index!(force: true)
      end

      context "with product-specific offer codes" do
        it "indexes offer codes into product documents" do
          product1.__elasticsearch__.index_document
          product2.__elasticsearch__.index_document

          es_product1 = Link.search(query: { term: { _id: product1.id } }).results.first
          es_product2 = Link.search(query: { term: { _id: product2.id } }).results.first

          expect(es_product1).to be_present
          expect(es_product2).to be_present
          expect(es_product1._source.offer_codes).to eq([])
          expect(es_product2._source.offer_codes).to eq([])

          create(:offer_code, user: creator, code: "BLACKFRIDAY2025", products: [product1, product2])

          described_class.process

          es_product1 = Link.search(query: { term: { _id: product1.id } }).results.first
          es_product2 = Link.search(query: { term: { _id: product2.id } }).results.first

          expect(es_product1._source.offer_codes).to eq(["BLACKFRIDAY2025"])
          expect(es_product2._source.offer_codes).to eq(["BLACKFRIDAY2025"])
        end
      end

      context "with universal offer codes" do
        it "indexes universal offer codes into all matching product documents" do
          product1.__elasticsearch__.index_document
          product2.__elasticsearch__.index_document
          product3.__elasticsearch__.index_document

          es_product1 = Link.search(query: { term: { _id: product1.id } }).results.first
          expect(es_product1._source.offer_codes).to eq([])

          create(:offer_code,
                 user: creator,
                 code: "BLACKFRIDAY2025",
                 universal: true,
                 currency_type: product1.price_currency_type,
                 amount_percentage: 20)

          described_class.process

          es_product1 = Link.search(query: { term: { _id: product1.id } }).results.first
          es_product2 = Link.search(query: { term: { _id: product2.id } }).results.first
          es_product3 = Link.search(query: { term: { _id: product3.id } }).results.first

          expect(es_product1._source.offer_codes).to eq(["BLACKFRIDAY2025"])
          expect(es_product2._source.offer_codes).to eq(["BLACKFRIDAY2025"])
          expect(es_product3._source.offer_codes).to eq(["BLACKFRIDAY2025"])
        end
      end
    end
  end
end
