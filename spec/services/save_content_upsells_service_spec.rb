# frozen_string_literal: true

describe SaveContentUpsellsService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }

  describe "#from_html" do
    let(:service) { described_class.new(seller:, content:, old_content:) }

    context "when adding a new upsell" do
      let(:old_content) { "<p>Old content</p>" }
      let(:content) { %(<p>Content with upsell</p><upsell-card productid="#{product.external_id}"></upsell-card>) }

      it "creates an upsell" do
        expect { service.from_html }.to change(Upsell, :count).by(1)

        upsell = Upsell.last
        expect(upsell.seller).to eq(seller)
        expect(upsell.product_id).to eq(product.id)
        expect(upsell.is_content_upsell).to be true
        expect(upsell.cross_sell).to be true
      end

      it "adds id to the upsell card" do
        result = Nokogiri::HTML.fragment(service.from_html)
        expect(result.at_css("upsell-card")["id"]).to be_present
      end

      context "with discount" do
        let(:content) do
          %(<p>Content with upsell</p><upsell-card productid="#{product.external_id}" discount='{"type":"fixed","cents":500}'></upsell-card>)
        end

        it "creates an offer code" do
          expect { service.from_html }.to change(OfferCode, :count).by(1)

          offer_code = OfferCode.last
          expect(offer_code.amount_cents).to eq(500)
          expect(offer_code.amount_percentage).to be_nil
          expect(offer_code.product_ids).to eq([product.id])
        end
      end
    end

    context "when removing an upsell" do
      let!(:upsell) { create(:upsell, seller:, product:, is_content_upsell: true) }
      let!(:offer_code) { create(:offer_code, user: seller, product_ids: [product.id]) }
      let(:old_content) { %(<p>Old content</p><upsell-card id="#{upsell.external_id}"></upsell-card>) }
      let(:content) { "<p>Content without upsell</p>" }

      before do
        upsell.update!(offer_code:)
      end

      it "marks upsell and offer code as deleted" do
        service.from_html

        expect(upsell.reload.deleted?).to be true
        expect(offer_code.reload.deleted?).to be true
      end
    end
  end

  describe "#from_rich_content" do
    let(:service) { described_class.new(seller:, content:, old_content:) }

    context "when adding a new upsell" do
      let(:old_content) { [{ "type" => "paragraph", "content" => "Old content" }] }
      let(:content) do
        [
          { "type" => "paragraph", "content" => "Content with upsell" },
          { "type" => "upsellCard", "attrs" => { "productId" => product.external_id } }
        ]
      end

      it "creates an upsell" do
        expect { service.from_rich_content }.to change(Upsell, :count).by(1)

        upsell = Upsell.last
        expect(upsell.seller).to eq(seller)
        expect(upsell.product_id).to eq(product.id)
        expect(upsell.is_content_upsell).to be true
        expect(upsell.cross_sell).to be true
      end

      it "adds id to the upsell node" do
        result = service.from_rich_content
        expect(result.last["attrs"]["id"]).to be_present
      end

      context "with discount" do
        let(:content) do
          [
            { "type" => "paragraph", "content" => "Content with upsell" },
            {
              "type" => "upsellCard",
              "attrs" => {
                "productId" => product.external_id,
                "discount" => { "type" => "percent", "percents" => 20 }
              }
            }
          ]
        end

        it "creates an offer code" do
          service.from_rich_content

          offer_code = OfferCode.last
          expect(offer_code.amount_cents).to be_nil
          expect(offer_code.amount_percentage).to eq(20)
          expect(offer_code.product_ids).to eq([product.id])
        end
      end
    end

    context "when removing an upsell" do
      let!(:upsell) { create(:upsell, seller:, product:, is_content_upsell: true) }
      let!(:offer_code) { create(:offer_code, user: seller, product_ids: [product.id]) }
      let(:old_content) do
        [
          { "type" => "paragraph", "content" => "Old content" },
          { "type" => "upsellCard", "attrs" => { "id" => upsell.external_id } }
        ]
      end
      let(:content) { [{ "type" => "paragraph", "content" => "Content without upsell" }] }

      before do
        upsell.update!(offer_code:)
      end

      it "marks upsell and offer code as deleted" do
        service.from_rich_content

        expect(upsell.reload.deleted?).to be true
        expect(offer_code.reload.deleted?).to be true
      end
    end
  end
end
