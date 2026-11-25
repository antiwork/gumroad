# frozen_string_literal: true

describe OmnibarSearchPresenter do
  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  def props(query) = described_class.new(pundit_user:, query:).props

  describe "#props" do
    describe "products" do
      let!(:widget) { create(:product, user: seller, name: "Beautiful widget") }

      it "finds the seller's products by any part of the name, whatever its case" do
        expect(props("WIDG")[:products]).to eq([{ id: widget.external_id, name: "Beautiful widget", url: "/products/#{widget.unique_permalink}/edit" }])
      end

      it "puts a name that starts with the query before one that only contains it" do
        starts_with = create(:product, user: seller, name: "Widget pack", created_at: 1.year.ago)

        expect(props("widget")[:products].map { _1[:id] }).to eq([starts_with.external_id, widget.external_id])
      end

      it "leaves out other sellers' products and deleted or archived ones" do
        create(:product, name: "Someone else's widget")
        create(:product, user: seller, name: "Deleted widget", deleted_at: Time.current)
        create(:product, user: seller, name: "Archived widget", archived: true)

        expect(props("widget")[:products].map { _1[:id] }).to eq([widget.external_id])
      end

      it "returns at most five" do
        6.times { |index| create(:product, user: seller, name: "Widget #{index}") }

        expect(props("widget")[:products].size).to eq(described_class::RESULTS_PER_GROUP)
      end

      it "matches % and _ literally" do
        percent = create(:product, user: seller, name: "50% off bundle")

        expect(props("50%")[:products].map { _1[:id] }).to eq([percent.external_id])
        expect(props("%%")[:products]).to eq([])
        expect(props("__")[:products]).to eq([])
      end
    end

    describe "customers" do
      let!(:product) { create(:product, user: seller, name: "Beautiful widget") }

      it "finds the seller's sales by buyer email or name" do
        purchase = create(:purchase, link: product, seller:, full_name: "Ada Lovelace", email: "ada@example.com")
        create(:purchase, link: create(:product, name: "Another seller's product"), full_name: "Ada Lovelace", email: "ada@example.com")
        index_model_records(Purchase)
        expected = { id: purchase.external_id, email: "ada@example.com", name: "Ada Lovelace", product_name: "Beautiful widget", url: "/customers/sale/#{purchase.external_id}" }

        expect(props("ada@example.com")[:customers]).to eq([expected])
        expect(props("lovelace")[:customers]).to eq([expected])
      end

      it "says when sales could not be searched and still returns products" do
        [Faraday::TimeoutError, Faraday::ConnectionFailed.new("down"), Elasticsearch::Transport::Transport::Errors::ServiceUnavailable].each do |error|
          allow(PurchaseSearchService).to receive(:search).and_raise(error)

          expect(props("widget")).to include(customers: [], customers_unavailable: true, products: [hash_including(id: product.external_id)])
        end
      end

      it "reports a query the index rejects" do
        allow(PurchaseSearchService).to receive(:search).and_raise(Elasticsearch::Transport::Transport::Errors::BadRequest)
        expect(ErrorNotifier).to receive(:notify).with(an_instance_of(Elasticsearch::Transport::Transport::Errors::BadRequest))

        expect(props("widget")).to include(customers: [], customers_unavailable: true)
      end
    end

    it "searches nothing until the query has two characters" do
      create(:product, user: seller, name: "Beautiful widget")
      expect(PurchaseSearchService).not_to receive(:search)

      [nil, "", " w ", "w"].each do |query|
        expect(props(query)).to eq(products: [], customers: [], customers_unavailable: false)
      end
    end

    it "returns only the groups the signed-in team member may open" do
      create(:product, user: seller, name: "Beautiful widget")
      allow_any_instance_of(LinkPolicy).to receive(:index?).and_return(false)
      allow_any_instance_of(Audience::PurchasePolicy).to receive(:index?).and_return(false)
      expect(PurchaseSearchService).not_to receive(:search)

      expect(props("widget")).to eq(products: [], customers: [], customers_unavailable: false)
    end
  end
end
