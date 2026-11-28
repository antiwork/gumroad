# frozen_string_literal: true

describe OmnibarSearchPresenter do
  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  def products(query) = described_class.new(pundit_user:, query:, group: "products").props
  def sales(query) = described_class.new(pundit_user:, query:, group: "sales").props

  describe "#props" do
    describe "products" do
      let!(:widget) { create(:product, user: seller, name: "Beautiful widget") }

      it "finds the seller's products by any part of the name, whatever its case" do
        expect(products("WIDG")).to eq(products: [{ id: widget.external_id, name: "Beautiful widget", url: "/products/#{widget.unique_permalink}/edit" }])
      end

      it "puts a name that starts with the query before one that only contains it" do
        starts_with = create(:product, user: seller, name: "Widget pack", created_at: 1.year.ago)

        expect(products("widget")[:products].map { _1[:id] }).to eq([starts_with.external_id, widget.external_id])
      end

      it "leaves out other sellers' products and deleted or archived ones" do
        create(:product, name: "Someone else's widget")
        create(:product, user: seller, name: "Deleted widget", deleted_at: Time.current)
        create(:product, user: seller, name: "Archived widget", archived: true)

        expect(products("widget")[:products].map { _1[:id] }).to eq([widget.external_id])
      end

      it "returns at most five" do
        6.times { |index| create(:product, user: seller, name: "Widget #{index}") }

        expect(products("widget")[:products].size).to eq(described_class::RESULTS_PER_GROUP)
      end

      it "matches % and _ literally" do
        percent = create(:product, user: seller, name: "50% off bundle")

        expect(products("50%")[:products].map { _1[:id] }).to eq([percent.external_id])
        expect(products("%%")[:products]).to eq([])
        expect(products("__")[:products]).to eq([])
      end

      # Support and accountant roles can list products and cannot edit them.
      it "links to the public page for a team member who cannot edit the product" do
        support = create(:user)
        create(:team_membership, user: support, seller:, role: TeamMembership::ROLE_SUPPORT)
        pundit_user = SellerContext.new(user: support, seller:)

        found = described_class.new(pundit_user:, query: "widget", group: "products").props[:products]

        expect(found).to eq([{ id: widget.external_id, name: "Beautiful widget", url: widget.long_url }])
      end

      it "does not touch the sales index" do
        expect(PurchaseSearchService).not_to receive(:search)

        products("widget")
      end
    end

    describe "sales" do
      let!(:product) { create(:product, user: seller, name: "Beautiful widget") }

      it "finds the seller's successful sales by buyer email or name, newest first" do
        purchase = create(:purchase, link: product, seller:, full_name: "Ada Lovelace", email: "ada@example.com")
        older = create(:purchase, link: product, seller:, full_name: "Ada Lovelace", email: "ada@example.com", created_at: 1.day.ago)
        create(:purchase, link: product, seller:, full_name: "Ada Lovelace", email: "ada@example.com", purchase_state: "failed")
        create(:purchase, link: create(:product, name: "Another seller's product"), full_name: "Ada Lovelace", email: "ada@example.com")
        index_model_records(Purchase)
        row = ->(sale) { { id: sale.external_id, email: "ada@example.com", name: "Ada Lovelace", product_name: "Beautiful widget", url: "/customers/sale/#{sale.external_id}" } }

        expect(sales("ada@example.com")).to eq(sales: [row.(purchase), row.(older)], sales_unavailable: false)
        expect(sales("lovelace")[:sales].map { _1[:id] }).to eq([purchase.external_id, older.external_id])
      end

      it "says when the index could not answer" do
        [Faraday::TimeoutError, Faraday::ConnectionFailed.new("down"), Elasticsearch::Transport::Transport::Errors::ServiceUnavailable].each do |error|
          allow(PurchaseSearchService).to receive(:search).and_raise(error)

          expect(sales("widget")).to eq(sales: [], sales_unavailable: true)
        end
      end

      it "reports a query the index rejects" do
        allow(PurchaseSearchService).to receive(:search).and_raise(Elasticsearch::Transport::Transport::Errors::BadRequest)
        expect(ErrorNotifier).to receive(:notify).with(an_instance_of(Elasticsearch::Transport::Transport::Errors::BadRequest))

        expect(sales("widget")).to eq(sales: [], sales_unavailable: true)
      end
    end

    it "searches nothing until the query has two characters" do
      create(:product, user: seller, name: "Beautiful widget")
      expect(PurchaseSearchService).not_to receive(:search)

      [nil, "", " w ", "w"].each do |query|
        expect(products(query)).to eq(products: [])
        expect(sales(query)).to eq(sales: [], sales_unavailable: false)
      end
    end

    it "returns nothing from a group the signed-in team member may not open" do
      create(:product, user: seller, name: "Beautiful widget")
      allow_any_instance_of(LinkPolicy).to receive(:index?).and_return(false)
      allow_any_instance_of(Audience::PurchasePolicy).to receive(:index?).and_return(false)
      expect(PurchaseSearchService).not_to receive(:search)

      expect(products("widget")).to eq(products: [])
      expect(sales("widget")).to eq(sales: [], sales_unavailable: false)
    end
  end
end
