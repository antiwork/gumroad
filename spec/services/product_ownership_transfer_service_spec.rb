# frozen_string_literal: true

require "spec_helper"

describe ProductOwnershipTransferService do
  let(:previous_seller) { create(:user, name: "Origin Seller") }
  let(:new_seller) { create(:user, name: "Destination Seller") }
  let(:product) { create(:product, user: previous_seller, name: "The Premium Course") }

  before do
    allow(ProductIndexingService).to receive(:perform)
  end

  def transfer(**options)
    described_class.new(product:, new_seller:, **options).process
  end

  describe "ownership pointer" do
    it "repoints the product to the new seller" do
      transfer

      expect(product.reload.user).to eq(new_seller)
    end

    it "keeps the new owner consistent with the product's user for future sales" do
      transfer

      purchase = build(:purchase, link: product.reload)
      purchase.valid?
      expect(purchase.seller).to eq(new_seller)
      expect(purchase.errors[:base]).not_to include("link does not belong to user")
    end

    it "raises when the product already belongs to the new seller" do
      expect do
        described_class.new(product:, new_seller: previous_seller).process
      end.to raise_error(described_class::TransferError, /already belongs/)
    end

    it "raises when the new seller is suspended" do
      allow(new_seller).to receive(:suspended?).and_return(true)

      expect { transfer }.to raise_error(described_class::TransferError, /good standing/)
      expect(product.reload.user).to eq(previous_seller)
    end

    it "raises when the custom permalink collides in the new seller's namespace" do
      product.update!(custom_permalink: "small-bets")
      create(:product, user: new_seller, custom_permalink: "small-bets")

      expect { transfer }.to raise_error(described_class::TransferError, /custom permalink/)
      expect(product.reload.user).to eq(previous_seller)
    end
  end

  describe "installments and workflows" do
    it "moves product and variant installments to the new seller" do
      product_installment = create(:installment, link: product, seller: previous_seller, installment_type: Installment::PRODUCT_TYPE)
      seller_wide_installment = create(:seller_installment, seller: previous_seller)

      transfer

      expect(product_installment.reload.seller).to eq(new_seller)
      expect(seller_wide_installment.reload.seller).to eq(previous_seller)
    end

    it "moves the product's workflows to the new seller" do
      workflow = create(:workflow, seller: previous_seller, link: product)

      transfer

      expect(workflow.reload.seller).to eq(new_seller)
    end
  end

  describe "offer codes" do
    it "moves an offer code that is exclusive to the product" do
      offer_code = create(:offer_code, user: previous_seller, products: [product])

      transfer

      expect(offer_code.reload.user).to eq(new_seller)
      expect(product.reload.offer_codes).to include(offer_code)
    end

    it "detaches the product from an offer code shared with another product" do
      other_product = create(:product, user: previous_seller)
      offer_code = create(:offer_code, user: previous_seller, products: [product, other_product])

      transfer

      expect(offer_code.reload.user).to eq(previous_seller)
      expect(offer_code.products).to match_array([other_product])
    end

    it "leaves universal offer codes with the origin seller" do
      universal = create(:universal_offer_code, user: previous_seller)

      transfer

      expect(universal.reload.user).to eq(previous_seller)
    end
  end

  describe "UTM links" do
    it "moves UTM links that target the product" do
      utm_link = create(:utm_link, seller: previous_seller, target_resource_type: :product_page, target_resource_id: product.id)
      other_utm_link = create(:utm_link, seller: previous_seller, target_resource_type: :profile_page)

      transfer

      expect(utm_link.reload.seller).to eq(new_seller)
      expect(other_utm_link.reload.seller).to eq(previous_seller)
    end
  end

  describe "affiliates and collaborators" do
    it "detaches the product's affiliates and self-service enrollment" do
      affiliate = create(:direct_affiliate, seller: previous_seller)
      create(:product_affiliate, product:, affiliate:)
      create(:self_service_affiliate_product, seller: previous_seller, product:)

      transfer

      expect(product.reload.product_affiliates).to be_empty
      expect(SelfServiceAffiliateProduct.where(product_id: product.id)).to be_empty
    end

    it "clears the collab flag when a collaborator is detached" do
      collaborator = create(:collaborator, seller: previous_seller, apply_to_all_products: false)
      create(:product_affiliate, product:, affiliate: collaborator)
      expect(product.reload.is_collab).to be(true)

      transfer

      expect(product.reload.is_collab).to be(false)
    end
  end

  describe "seller profile" do
    it "repoints the product's own page sections to the new seller" do
      section = create(:seller_profile_products_section, seller: previous_seller, product:)

      transfer

      expect(section.reload.seller).to eq(new_seller)
    end

    it "removes the product from the origin seller's profile-level sections" do
      products_section = create(:seller_profile_products_section, seller: previous_seller, shown_products: [product.id])
      featured_section = create(:seller_profile_featured_product_section, seller: previous_seller)
      featured_section.update!(featured_product_id: product.id)

      transfer

      expect(products_section.reload.shown_products).to be_empty
      expect(SellerProfileSection.where(id: featured_section.id)).to be_empty
    end
  end

  describe "audit comments" do
    it "records a note on the origin and destination accounts" do
      transfer

      origin_comment = previous_seller.comments.last
      expect(origin_comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
      expect(origin_comment.content).to include("transferred to", new_seller.display_name, "The Premium Course")

      destination_comment = new_seller.comments.last
      expect(destination_comment.content).to include("received from", previous_seller.display_name, "The Premium Course")
    end

    it "attributes the note to the admin who performed the transfer" do
      admin = create(:admin_user, name: "Support Admin")

      described_class.new(product:, new_seller:, performed_by: admin).process

      comment = previous_seller.comments.last
      expect(comment.author_id).to eq(admin.id)
      expect(comment.content).to include("by Support Admin")
    end
  end

  describe "historical and financial records" do
    it "leaves existing purchases attributed to the origin seller" do
      purchase = create(:free_purchase, link: product, seller: previous_seller)

      transfer

      expect(purchase.reload.seller).to eq(previous_seller)
    end
  end

  describe "derived data" do
    it "busts the product cache when the owner changes" do
      expect(product).to receive(:invalidate_cache).at_least(:once).and_call_original

      transfer
    end

    it "reindexes the product for search under the new owner" do
      expect(ProductIndexingService).to receive(:perform).with(product:, action: "index", on_failure: :async)

      transfer
    end
  end

  describe "atomicity" do
    it "rolls the whole move back when a step fails" do
      installment = create(:installment, link: product, seller: previous_seller, installment_type: Installment::PRODUCT_TYPE)
      allow_any_instance_of(described_class).to receive(:leave_audit_comments).and_raise(StandardError, "boom")

      expect { transfer }.to raise_error(StandardError, "boom")

      expect(product.reload.user).to eq(previous_seller)
      expect(installment.reload.seller).to eq(previous_seller)
    end
  end
end
