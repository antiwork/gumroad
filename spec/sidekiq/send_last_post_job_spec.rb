# frozen_string_literal: true

require "spec_helper"

describe SendLastPostJob do
  describe "#perform" do
    let(:product) { create(:membership_product) }
    let(:tier) { product.default_tier }
    let(:purchase) { create(:membership_purchase, link: product, seller: product.user, tier:) }
    let(:recipient) { { email: purchase.email, purchase:, subscription: purchase.subscription } }
    let!(:product_post) { create(:post, :published, link: product, published_at: 1.day.ago) }
    let!(:variant_post) { create(:variant_post, :published, link: product, base_variant: tier, published_at: 1.day.ago) }
    let!(:seller_post) { create(:seller_post, :published, seller: product.user, published_at: 1.day.ago) }

    before do
      # invalid because different product
      create(:post, :published, link: create(:product, user: purchase.seller))
      # invalid because workflow post
      create(:post, :published, link: purchase.link, workflow: create(:workflow))
      # invalid because different variant
      base_variant = create(:variant, variant_category: create(:variant_category, link: product))
      create(:variant_post, :published, link: product, base_variant:)
      # invalid because not published
      create(:post, link: product)
      # invalid because deleted
      create(:post, :published, link: product, deleted_at: Time.current)
      # invalid because send_emails: false
      create(:post, :published, link: product, send_emails: false, shown_on_profile: true)
      # invalid because purchase does not pass filters
      create(:post, :published, link: product, created_before: 1.day.ago)
    end

    shared_examples_for "sending latest post" do
      before { post.update!(published_at: 1.minute.ago) }

      it "sends that post" do
        expect(PostSendgridApi).to receive(:process).with(post:, recipients: [recipient])
        described_class.new.perform(purchase.id)
      end
    end

    context "when the last valid post is a product post" do
      let(:post) { product_post }
      it_behaves_like "sending latest post"
    end

    context "when the last valid post is a variant post" do
      let(:post) { variant_post }
      it_behaves_like "sending latest post"
    end

    context "when the last valid post is a seller post" do
      let(:post) { seller_post }
      it_behaves_like "sending latest post"
    end

    context "when the post has files" do
      before do
        product_post.update!(published_at: 1.minute.ago)
        product_post.product_files << create(:pdf_product_file)
      end

      it "creates and uses UrlRedirect" do
        allow(PostSendgridApi).to receive(:process)

        expect do
          described_class.new.perform(purchase.id)
        end.to change { UrlRedirect.count }.by(1)

        url_redirect = UrlRedirect.last!
        expect(url_redirect.installment).to eq(product_post)
        expect(url_redirect.subscription).to eq(purchase.subscription)

        recipient[:url_redirect] = url_redirect
        expect(PostSendgridApi).to have_received(:process).with(post: product_post, recipients: [recipient])
      end
    end
  end
end
