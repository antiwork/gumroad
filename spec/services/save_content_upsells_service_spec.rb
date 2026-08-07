# frozen_string_literal: true

describe SaveContentUpsellsService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }
  let(:variant_category) { create(:variant_category, link: product) }
  let(:variant) { create(:variant, variant_category:) }

  describe "#from_html" do
    let(:service) { described_class.new(seller:, content:, old_content:) }

    context "when adding a new upsell" do
      let(:old_content) { "<p>Old content</p>" }
      let(:content) { %(<p>Content with upsell</p><upsell-card productid="#{product.external_id}" variantid="#{variant.external_id}"></upsell-card>) }

      it "creates an upsell" do
        expect { service.from_html }.to change(Upsell, :count).by(1)

        upsell = Upsell.last
        expect(upsell.seller).to eq(seller)
        expect(upsell.product_id).to eq(product.id)
        expect(upsell.variant_id).to eq(variant.id)
        expect(upsell.is_content_upsell).to be true
        expect(upsell.cross_sell).to be true
      end

      it "adds id to the upsell card" do
        result = Nokogiri::HTML.fragment(service.from_html)
        expect(result.at_css("upsell-card")["id"]).to be_present
      end

      context "when the new content copies a persisted upsell id" do
        let!(:existing_upsell) { create(:upsell, seller:, product:, is_content_upsell: true) }
        let(:content) do
          %(<p>Copied content</p><upsell-card id="#{existing_upsell.external_id}" productid="#{product.external_id}"></upsell-card>)
        end

        it "creates an independent upsell" do
          expect { @result = service.from_html }.to change(Upsell, :count).by(1)

          copied_id = Nokogiri::HTML.fragment(@result).at_css("upsell-card")["id"]
          expect(copied_id).to eq(Upsell.last.external_id)
          expect(copied_id).not_to eq(existing_upsell.external_id)
          expect(existing_upsell.reload).to be_alive
        end
      end


      context "when the content duplicates its existing upsell" do
        let!(:existing_upsell) { create(:upsell, seller:, product:, is_content_upsell: true) }
        let(:old_content) do
          %(<upsell-card id="#{existing_upsell.external_id}" productid="#{product.external_id}"></upsell-card>)
        end
        let(:content) { old_content + old_content }

        it "keeps one id and creates one independent upsell" do
          result = nil
          expect { result = service.from_html }.to change(Upsell, :count).by(1)

          ids = Nokogiri::HTML.fragment(result).css("upsell-card").map { _1["id"] }
          expect(ids).to contain_exactly(existing_upsell.external_id, Upsell.last.external_id)
        end
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

        it "rejects a discount with an invalid shape" do
          invalid_content = %(<upsell-card productid="#{product.external_id}" discount="1"></upsell-card>)
          service = described_class.new(seller:, content: invalid_content, old_content:)

          expect { service.from_html }.to raise_error(ActiveRecord::RecordInvalid)
        end

        it "rejects a discount with an invalid value" do
          invalid_content = %(<upsell-card productid="#{product.external_id}" discount='{"type":"percent","percents":101}'></upsell-card>)
          service = described_class.new(seller:, content: invalid_content, old_content:)

          expect { service.from_html }.to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Content contains invalid upsell data.")
        end

        it "rejects a fixed discount outside the database integer range" do
          cents = SaveContentUpsellsService::MAX_FIXED_DISCOUNT_CENTS + 1
          invalid_content = %(<upsell-card productid="#{product.external_id}" discount='{"type":"fixed","cents":#{cents}}'></upsell-card>)
          service = described_class.new(seller:, content: invalid_content, old_content:)

          expect { service.from_html }.to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Content contains invalid upsell data.")
        end

        it "rejects a product that does not belong to the seller" do
          other_product = create(:product)
          invalid_content = %(<upsell-card productid="#{other_product.external_id}"></upsell-card>)
          service = described_class.new(seller:, content: invalid_content, old_content:)

          expect { service.from_html }.to raise_error(ActiveRecord::RecordInvalid)
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

      it "keeps the old upsell when a new card is invalid" do
        invalid_content = %(<upsell-card productid="invalid"></upsell-card>)
        service = described_class.new(seller:, content: invalid_content, old_content:)

        expect { service.from_html }.to raise_error(ActiveRecord::RecordInvalid)
        expect(upsell.reload).to be_alive
        expect(offer_code.reload).to be_alive
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
          { "type" => "upsellCard", "attrs" => { "productId" => product.external_id, "variantId" => variant.external_id } }
        ]
      end

      it "creates an upsell" do
        expect { service.from_rich_content }.to change(Upsell, :count).by(1)

        upsell = Upsell.last
        expect(upsell.seller).to eq(seller)
        expect(upsell.product_id).to eq(product.id)
        expect(upsell.variant_id).to eq(variant.id)
        expect(upsell.is_content_upsell).to be true
        expect(upsell.cross_sell).to be true
      end

      it "adds id to the upsell node" do
        result = service.from_rich_content
        expect(result.last["attrs"]["id"]).to be_present
      end

      context "when the new content copies a persisted upsell id" do
        let!(:existing_upsell) { create(:upsell, seller:, product:, is_content_upsell: true) }
        let(:content) do
          [
            {
              "type" => "upsellCard",
              "attrs" => { "id" => existing_upsell.external_id, "productId" => product.external_id }
            }
          ]
        end

        it "creates an independent upsell" do
          expect { service.from_rich_content }.to change(Upsell, :count).by(1)

          copied_id = content.first.dig("attrs", "id")
          expect(copied_id).to eq(Upsell.last.external_id)
          expect(copied_id).not_to eq(existing_upsell.external_id)
          expect(existing_upsell.reload).to be_alive
        end
      end

      context "when the content duplicates its existing upsell" do
        let!(:existing_upsell) { create(:upsell, seller:, product:, is_content_upsell: true) }
        let(:upsell_node) do
          {
            "type" => "upsellCard",
            "attrs" => { "id" => existing_upsell.external_id, "productId" => product.external_id }
          }
        end
        let(:old_content) { [upsell_node.deep_dup] }
        let(:content) { [upsell_node.deep_dup, upsell_node.deep_dup] }

        it "keeps one id and creates one independent upsell" do
          expect { service.from_rich_content }.to change(Upsell, :count).by(1)

          ids = content.map { _1.dig("attrs", "id") }
          expect(ids).to contain_exactly(existing_upsell.external_id, Upsell.last.external_id)
        end
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

    context "when the upsell node is nested inside a container node" do
      let(:old_content) { [{ "type" => "paragraph", "content" => "Old content" }] }
      let(:content) do
        [
          {
            "type" => "blockquote",
            "content" => [
              { "type" => "upsellCard", "attrs" => { "productId" => product.external_id } }
            ]
          }
        ]
      end

      it "creates an upsell and assigns its id on the nested node" do
        expect { service.from_rich_content }.to change(Upsell, :count).by(1)

        nested_node = content.first["content"].first
        expect(nested_node["attrs"]["id"]).to be_present
        expect(nested_node["attrs"]["id"]).to eq(Upsell.last.external_id)
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

      it "keeps the old upsell when a new node is invalid" do
        invalid_content = [{ "type" => "upsellCard", "attrs" => { "productId" => "invalid" } }]
        service = described_class.new(seller:, content: invalid_content, old_content:)

        expect { service.from_rich_content }.to raise_error(ActiveRecord::RecordInvalid)
        expect(upsell.reload).to be_alive
        expect(offer_code.reload).to be_alive
      end
    end
  end
end
