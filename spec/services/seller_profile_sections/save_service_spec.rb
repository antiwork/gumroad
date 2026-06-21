# frozen_string_literal: true

require "spec_helper"

describe SellerProfileSections::SaveService do
  let(:seller) { create(:named_seller) }
  let(:service) { described_class.new(seller:) }

  def section_params(attributes)
    ActionController::Parameters.new(attributes).permit!
  end

  describe "#create!" do
    it "creates a section and decrypts obfuscated ids" do
      products = create_list(:product, 2, user: seller)
      section = service.create!(section_params(
                                  type: "SellerProfileProductsSection",
                                  header: "Products",
                                  shown_products: products.map(&:external_id),
                                  default_product_sort: "page_layout",
                                  show_filters: true,
                                  add_new_products: false,
                                ))

      expect(section).to be_persisted
      expect(section).to have_attributes(
        type: "SellerProfileProductsSection",
        header: "Products",
        hide_header: false,
        shown_products: products.map(&:id),
        default_product_sort: "page_layout",
        show_filters: true,
        add_new_products: false,
      )
    end

    it "derives hide_header from the header: a blank header hides the name" do
      with_name = service.create!(section_params(type: "SellerProfileSubscribeSection", header: "Subscribe", button_label: "Follow"))
      without_name = service.create!(section_params(type: "SellerProfileSubscribeSection", header: "", button_label: "Follow"))

      expect(with_name.hide_header?).to eq(false)
      expect(without_name.hide_header?).to eq(true)
    end

    it "decrypts the featured product id" do
      product = create(:product, user: seller)
      section = service.create!(section_params(type: "SellerProfileFeaturedProductSection", featured_product_id: product.external_id))

      expect(section.featured_product_id).to eq(product.id)
    end

    it "processes rich text content through SaveContentUpsellsService" do
      product = create(:product, user: seller)
      text = {
        "type" => "doc",
        "content" => [
          { "type" => "paragraph", "content" => [{ "text" => "hi", "type" => "text" }] },
          { "type" => "upsellCard", "attrs" => { "discount" => nil, "productId" => product.external_id } }
        ]
      }

      expect(SaveContentUpsellsService).to receive(:new).with(
        seller:,
        content: text["content"].map { ActionController::Parameters.new(_1).permit! },
        old_content: []
      ).and_call_original
      section = service.create!(section_params(type: "SellerProfileRichTextSection", text:))

      upsell = Upsell.last
      expect(upsell).to be_alive
      expect(upsell.product_id).to eq(product.id)
      expect(section.text["content"][1]["attrs"]["id"]).to eq(upsell.external_id)
    end

    it "raises for invalid attributes" do
      expect do
        service.create!(section_params(type: "SellerProfileProductsSection", show_filters: "nope"))
      end.to raise_error(ActiveRecord::RecordInvalid, /show_filters/)
    end

    it "raises for an invalid section type" do
      expect do
        service.create!(section_params(type: "SellerProfileFakeSection"))
      end.to raise_error(ActiveRecord::SubclassNotFound)
    end
  end

  describe "#update!" do
    let(:section) { create(:seller_profile_products_section, seller:, header: "A!", shown_products: [1], hide_header: true) }

    it "updates the section and decrypts obfuscated ids" do
      products = create_list(:product, 2, user: seller)
      service.update!(section, section_params(header: "B!", shown_products: products.map(&:external_id)))

      expect(section.reload).to have_attributes(header: "B!", shown_products: products.map(&:id), hide_header: false)
    end

    it "derives hide_header from the header on update" do
      service.update!(section, section_params(header: ""))
      expect(section.reload.hide_header?).to eq(true)

      service.update!(section, section_params(header: "Now visible"))
      expect(section.reload.hide_header?).to eq(false)
    end

    it "leaves hide_header untouched when the header is not part of the update" do
      section.update!(header: "Kept", hide_header: false)
      service.update!(section, section_params(shown_products: []))
      expect(section.reload).to have_attributes(header: "Kept", hide_header: false)
    end

    it "ignores type, product_id, and shown_posts by default" do
      post = create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, seller:, shown_on_profile: true)
      posts_section = create(:seller_profile_posts_section, seller:, shown_posts: [])
      service.update!(posts_section, section_params(type: "SellerProfileRichTextSection", product_id: create(:product, user: seller).external_id, shown_posts: [post.external_id], header: "B!"))

      expect(posts_section.reload).to have_attributes(type: "SellerProfilePostsSection", product_id: nil, shown_posts: [], header: "B!")
    end

    it "updates shown_posts and decrypts obfuscated ids when allow_shown_posts is true" do
      post = create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, seller:, shown_on_profile: true)
      posts_section = create(:seller_profile_posts_section, seller:, shown_posts: [])
      service.update!(posts_section, section_params(shown_posts: [post.external_id], header: "B!"), allow_shown_posts: true)

      expect(posts_section.reload).to have_attributes(shown_posts: [post.id], header: "B!")
    end

    it "processes rich text content with the existing content as old content" do
      product = create(:product, user: seller)
      upsell = create(:upsell, seller:, product:, is_content_upsell: true)
      rich_text_section = create(
        :seller_profile_rich_text_section,
        seller:,
        text: {
          "type" => "doc",
          "content" => [{ "type" => "upsellCard", "attrs" => { "discount" => nil, "id" => upsell.external_id, "productId" => product.external_id } }]
        }
      )
      new_text = {
        "type" => "doc",
        "content" => [{ "type" => "upsellCard", "attrs" => { "discount" => nil, "productId" => product.external_id } }]
      }

      expect(SaveContentUpsellsService).to receive(:new).with(
        seller:,
        content: new_text["content"].map { ActionController::Parameters.new(_1).permit! },
        old_content: rich_text_section.text["content"]
      ).and_call_original
      service.update!(rich_text_section, section_params(text: new_text))

      expect(upsell.reload).to be_deleted
      new_upsell = Upsell.last
      expect(new_upsell).to be_alive
      expect(rich_text_section.reload.text["content"][0]["attrs"]["id"]).to eq(new_upsell.external_id)
    end

    it "raises for invalid attributes" do
      expect do
        service.update!(section, section_params(show_filters: "nope"))
      end.to raise_error(ActiveRecord::RecordInvalid, /show_filters/)
    end
  end

  describe "#upsert!" do
    it "creates a new section when the id is a client-generated temporary id" do
      expect do
        service.upsert!(section_params(id: "0b8f3782-3a85-4f93-8e3c-2b1f5d3e8a90", type: "SellerProfileSubscribeSection", header: "Subscribe", button_label: "Follow"))
      end.to change { seller.seller_profile_subscribe_sections.count }.from(0).to(1)

      expect(seller.seller_profile_subscribe_sections.sole).to have_attributes(header: "Subscribe", button_label: "Follow")
    end

    it "creates a new section when no id is given" do
      expect do
        service.upsert!(section_params(type: "SellerProfileRichTextSection", text: { "type" => "doc", "content" => [] }))
      end.to change { seller.seller_profile_rich_text_sections.count }.from(0).to(1)
    end

    it "updates the existing section when the id is one of the seller's section external ids" do
      section = create(:seller_profile_products_section, seller:, header: "A!")

      expect do
        expect(service.upsert!(section_params(id: section.external_id, header: "B!"))).to eq(section)
      end.not_to change { seller.seller_profile_sections.count }

      expect(section.reload.header).to eq("B!")
    end

    it "creates a new section instead of updating another seller's section" do
      other_section = create(:seller_profile_products_section, header: "Theirs")

      expect do
        service.upsert!(section_params(id: other_section.external_id, type: "SellerProfileProductsSection", header: "Mine", shown_products: [], default_product_sort: "page_layout", show_filters: false, add_new_products: true))
      end.to change { seller.seller_profile_products_sections.count }.from(0).to(1)

      expect(other_section.reload.header).to eq("Theirs")
      expect(seller.seller_profile_products_sections.sole.header).to eq("Mine")
    end
  end
end
