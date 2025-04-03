# frozen_string_literal: true

require "spec_helper"

describe UtmLinkPresenter do
  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller, name: "Product A") }
  let!(:deleted_product) { create(:product, user: seller, name: "Deleted Product", deleted_at: Time.current) }
  let!(:post) { create(:audience_post, :published, seller:, name: "Post A", shown_on_profile: true) }
  let!(:hidden_post) { create(:audience_post, :published, seller:, name: "Hidden Post", shown_on_profile: false) }
  let!(:workflow_post) { create(:workflow_installment, :published, seller:, name: "Workflow email") }
  let!(:unpublished_post) { create(:audience_post, seller:, name: "Draft Post", published_at: nil) }
  let!(:utm_link) do
    create(:utm_link, seller:,
                      utm_campaign: "spring",
                      utm_medium: "social",
                      utm_source: "facebook",
                      utm_term: "sale",
                      utm_content: "banner",
    )
  end

  describe "#utm_link_props" do
    it "returns the UTM link props" do
      props = described_class.new(seller:, utm_link:).utm_link_props
      expect(props).to eq({ id: utm_link.external_id,
                            title: utm_link.title,
                            short_url: utm_link.short_url,
                            utm_url: utm_link.utm_url,
                            created_at: utm_link.created_at.iso8601,
                            source: utm_link.utm_source,
                            medium: utm_link.utm_medium,
                            campaign: utm_link.utm_campaign,
                            term: utm_link.utm_term,
                            content: utm_link.utm_content,
                            clicks: utm_link.unique_clicks,
                            destination_option: {
                              id: "profile_page",
                              label: "Profile page",
                              url: seller.profile_url
                            },
                            sales_count: nil,
                            revenue_cents: nil,
                            conversion_rate: nil
                          })
    end

    it "returns correct 'destination_option' depending on the 'target_resource_type'" do
      product = create(:product, user: seller, name: "Product A")
      post = create(:audience_post, seller:, name: "Post A")

      # resource_type: product_page
      utm_link.update!(target_resource_type: "product_page", target_resource_id: product.id)
      expect(described_class.new(seller:, utm_link:).utm_link_props[:destination_option]).to eq({
                                                                                                  id: "product_page-#{product.external_id}",
                                                                                                  label: "Product A",
                                                                                                  url: product.long_url
                                                                                                })

      # resource_type: post_page
      utm_link.update!(target_resource_type: "post_page", target_resource_id: post.id)
      expect(described_class.new(seller:, utm_link:).utm_link_props[:destination_option]).to eq({
                                                                                                  id: "post_page-#{post.external_id}",
                                                                                                  label: "Post A",
                                                                                                  url: post.full_url
                                                                                                })

      # resource_type: subscribe_page
      utm_link.update!(target_resource_type: "subscribe_page")
      expect(described_class.new(seller:, utm_link:).utm_link_props[:destination_option]).to eq({
                                                                                                  id: "subscribe_page",
                                                                                                  label: "Subscribe page",
                                                                                                  url: Rails.application.routes.url_helpers.custom_domain_subscribe_url(host: seller.subdomain_with_protocol)
                                                                                                })

      # resource_type: profile_page
      utm_link.update!(target_resource_type: "profile_page")
      expect(described_class.new(seller:, utm_link:).utm_link_props[:destination_option]).to eq({
                                                                                                  id: "profile_page",
                                                                                                  label: "Profile page",
                                                                                                  url: seller.profile_url
                                                                                                })
    end
  end

  describe "#new_page_react_props" do
    it "returns the form context props" do
      allow(SecureRandom).to receive(:alphanumeric).and_return("unique01")

      props = described_class.new(seller:).new_page_react_props

      expect(props).to eq({
                            context: {
                              destination_options: [
                                { id: "profile_page", label: "Profile page", url: seller.profile_url },
                                {
                                  id: "subscribe_page",
                                  label: "Subscribe page",
                                  url: Rails.application.routes.url_helpers.custom_domain_subscribe_url(host: seller.subdomain_with_protocol)
                                },
                                { id: "product_page-#{product.external_id}", label: "Product — Product A", url: product.long_url },
                                { id: "post_page-#{post.external_id}", label: "Post — Post A", url: post.full_url }
                              ],
                              short_url: "#{UrlService.short_domain_with_protocol}/u/unique01",
                              utm_fields_values: {
                                campaigns: ["spring"],
                                mediums: ["social"],
                                sources: ["facebook"],
                                terms: ["sale"],
                                contents: ["banner"]
                              }
                            },
                            utm_link: nil
                          })
    end

    it "returns 'utm_link' in the props when 'copy_from' is provided" do
      utm_link.update!(title: "Existing UTM Link")

      props = described_class.new(seller:).new_page_react_props(copy_from: utm_link.external_id)

      expected_utm_link_props = described_class.new(seller:, utm_link:).utm_link_props.except(:id)
      expected_utm_link_props[:short_url] = props[:context][:short_url]
      expect(props[:utm_link]).to eq(expected_utm_link_props)
    end

    it "returns empty arrays for utm_fields_values when no UTM links exist" do
      props = described_class.new(seller: create(:user)).new_page_react_props

      expect(props[:context][:utm_fields_values]).to eq({
                                                          campaigns: [],
                                                          mediums: [],
                                                          sources: [],
                                                          terms: [],
                                                          contents: []
                                                        })
    end
  end

  describe "#edit_page_react_props" do
    it "returns the form context props and the UTM link props" do
      props = described_class.new(seller:, utm_link:).edit_page_react_props

      expect(props).to eq({
                            context: {
                              destination_options: [
                                { id: "profile_page", label: "Profile page", url: seller.profile_url },
                                {
                                  id: "subscribe_page",
                                  label: "Subscribe page",
                                  url: Rails.application.routes.url_helpers.custom_domain_subscribe_url(host: seller.subdomain_with_protocol)
                                },
                                { id: "product_page-#{product.external_id}", label: "Product — Product A", url: product.long_url },
                                { id: "post_page-#{post.external_id}", label: "Post — Post A", url: post.full_url }
                              ],
                              short_url: utm_link.short_url,
                              utm_fields_values: {
                                campaigns: ["spring"],
                                mediums: ["social"],
                                sources: ["facebook"],
                                terms: ["sale"],
                                contents: ["banner"]
                              }
                            },
                            utm_link: described_class.new(seller:, utm_link:).utm_link_props
                          })
    end
  end
end
