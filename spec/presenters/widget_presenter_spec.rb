# frozen_string_literal: true

require "spec_helper"

describe WidgetPresenter do
  include Rails.application.routes.url_helpers

  let!(:demo_product) { create(:product, unique_permalink: "demo") }

  describe "#widget_props" do
    context "when user is signed in" do
      let(:user) { create(:user) }

      subject { described_class.new(seller: user) }

      context "when user doesn't have own products" do
        it "returns a demo product" do
          expect(subject.widget_props).to eq(
            {
              display_product_select: true,
              default_product:
                {
                  name: "The Works of Edgar Gumstein",
                  url: demo_product.long_url,
                  gumroad_domain_url: demo_product.long_url,
                  script_base_url: UrlService.root_domain_with_protocol
                },
              products: [
                {
                  name: "The Works of Edgar Gumstein",
                  url: demo_product.long_url,
                  gumroad_domain_url: demo_product.long_url,
                  script_base_url: UrlService.root_domain_with_protocol
                }
              ],
              affiliated_products: [],
            })
        end
      end

      context "when user has own products" do
        let!(:product) { create(:product, user:) }

        it "returns user's own products" do
          expect(subject.widget_props).to eq(
            {
              display_product_select: true,
              default_product: {
                name: product.name,
                url: product.long_url,
                gumroad_domain_url: product.long_url,
                script_base_url: UrlService.root_domain_with_protocol
              },
              products: [
                {
                  name: product.name,
                  url: product.long_url,
                  gumroad_domain_url: product.long_url,
                  script_base_url: UrlService.root_domain_with_protocol
                }
              ],
              affiliated_products: [],
            })
        end
      end

      context "when user has affiliated products" do
        let(:affiliate_product) { create(:product) }
        let!(:direct_affiliate) { create(:direct_affiliate, affiliate_user: user, products: [affiliate_product]) }

        it "returns demo product and affiliated products" do
          expect(subject.widget_props).to eq(
            {
              display_product_select: true,
              default_product: {
                name: demo_product.name,
                url: demo_product.long_url,
                gumroad_domain_url: demo_product.long_url,
                script_base_url: UrlService.root_domain_with_protocol
              },
              products: [
                {
                  name: demo_product.name,
                  url: demo_product.long_url,
                  gumroad_domain_url: demo_product.long_url,
                  script_base_url: UrlService.root_domain_with_protocol
                }
              ],
              affiliated_products: [
                {
                  name: affiliate_product.name,
                  url: affiliate_product_url(affiliate_id: direct_affiliate.external_id_numeric,
                                             unique_permalink: affiliate_product.unique_permalink,
                                             host: UrlService.root_domain_with_protocol),
                  gumroad_domain_url: affiliate_product_url(affiliate_id: direct_affiliate.external_id_numeric,
                                                            unique_permalink: affiliate_product.unique_permalink,
                                                            host: UrlService.root_domain_with_protocol),
                  script_base_url: UrlService.root_domain_with_protocol
                }
              ],
            })
        end
      end

      context "when user has multiple products" do
        let!(:new_product) { create(:product, user:, name: "New Product", created_at: DateTime.current - 1.hour) }
        let!(:old_product) { create(:product, user:, name: "Old Product", created_at: DateTime.current - 2.hours) }

        context "when product argument is provided" do
          subject { described_class.new(seller: user, product: old_product) }

          it "returns the default_product as the provided product" do
            expect(subject.widget_props).to eq(
              {
                display_product_select: false,
                default_product: {
                  name: "Old Product",
                  url: old_product.long_url,
                  gumroad_domain_url: old_product.long_url,
                  script_base_url: UrlService.root_domain_with_protocol
                },
                products: [
                  {
                    name: "New Product",
                    url: new_product.long_url,
                    gumroad_domain_url: new_product.long_url,
                    script_base_url: UrlService.root_domain_with_protocol
                  },
                  {
                    name: "Old Product",
                    url: old_product.long_url,
                    gumroad_domain_url: old_product.long_url,
                    script_base_url: UrlService.root_domain_with_protocol
                  }
                ],
                affiliated_products: [],
              })
          end
        end

        context "when product argument is not provided" do
          subject { described_class.new(seller: user) }

          it "returns the default_product as the newest user product" do
            expect(subject.widget_props).to eq(
              {
                display_product_select: true,
                default_product: {
                  name: "New Product",
                  url: new_product.long_url,
                  gumroad_domain_url: new_product.long_url,
                  script_base_url: UrlService.root_domain_with_protocol
                },
                products: [
                  {
                    name: "New Product",
                    url: new_product.long_url,
                    gumroad_domain_url: new_product.long_url,
                    script_base_url: UrlService.root_domain_with_protocol
                  },
                  {
                    name: "Old Product",
                    url: old_product.long_url,
                    gumroad_domain_url: old_product.long_url,
                    script_base_url: UrlService.root_domain_with_protocol
                  }
                ],
                affiliated_products: [],
              })
          end
        end
      end
    end

    context "when user is not signed in" do
      subject { described_class.new(seller: nil) }

      it "returns a demo product" do
        expect(subject.widget_props).to eq(
          {
            display_product_select: false,
            default_product:
              {
                name: "The Works of Edgar Gumstein",
                url: demo_product.long_url,
                gumroad_domain_url: demo_product.long_url,
                script_base_url: UrlService.root_domain_with_protocol
              },
            products: [
              {
                name: "The Works of Edgar Gumstein",
                url: demo_product.long_url,
                gumroad_domain_url: demo_product.long_url,
                script_base_url: UrlService.root_domain_with_protocol
              }
            ],
            affiliated_products: [],
          })
      end
    end
  end
end
