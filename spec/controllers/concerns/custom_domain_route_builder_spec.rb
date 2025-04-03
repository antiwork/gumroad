# frozen_string_literal: true

require "spec_helper"

describe CustomDomainRouteBuilder, type: :controller do
  controller(ApplicationController) do
    include CustomDomainRouteBuilder

    def action
      head :ok
    end
  end

  before do
    routes.draw { get :action, to: "anonymous#action" }
  end

  let!(:custom_domain) { "store.example1.com" }

  describe "#build_view_post_route" do
    let!(:post) { create(:installment) }
    let!(:purchase) { create(:purchase) }

    it "returns the correct URL for requests from a custom domain" do
      @request.host = custom_domain
      get :action

      result = controller.build_view_post_route(post:, purchase_id: purchase.external_id)

      expect(result).to eq(custom_domain_view_post_path(slug: post.slug, purchase_id: purchase.external_id))
    end

    it "returns the correct URL for requests from a non-custom domain" do
      get :action

      result = controller.build_view_post_route(post:, purchase_id: purchase.external_id)

      expect(result).to eq(view_post_path(
                             username: post.user.username,
                             slug: post.slug,
                             purchase_id: purchase.external_id))
    end
  end

  describe "#seller_custom_domain_url" do
    let!(:user) { create(:user, username: "example") }

    context "when the request is through a custom domain" do
      before do
        @request.host = custom_domain
      end

      it "returns root path" do
        get :action

        expect(controller.seller_custom_domain_url).to eq "http://#{custom_domain}/"
      end
    end

    context "when the request is through a product custom domain" do
      before do
        create(:custom_domain, domain: custom_domain, product: create(:product))
        @request.host = custom_domain
      end

      it "returns nil" do
        get :action

        expect(controller.seller_custom_domain_url).to be_nil
      end
    end

    context "when the request is from a product custom domain page and there is an older dead matching domain" do
      before do
        create(:custom_domain, domain: custom_domain, deleted_at: DateTime.parse("2020-01-01"))
        create(:custom_domain, :with_product, domain: custom_domain)
        @request.host = custom_domain
      end

      it "returns nil" do
        get :action

        expect(controller.seller_custom_domain_url).to be_nil
      end
    end

    context "when the request is not through a custom domain" do
      it "returns nil" do
        get :action

        expect(controller.seller_custom_domain_url).to be_nil
      end
    end
  end
end
