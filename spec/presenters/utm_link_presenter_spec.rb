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

  let(:profile_page_option) { { id: "profile_page", label: "Profile page", url: seller.profile_url } }

  let(:subscribe_page_option) { { id: "subscribe_page", label: "Subscribe page", url: Rails.application.routes.url_helpers.custom_domain_subscribe_url(host: seller.subdomain_with_protocol) } }

  def product_page_option(product, add_label_prefix: true)
    label = add_label_prefix ? "Product — #{product.name}" : product.name
    { id: "product_page-#{product.external_id}", label:, url: product.long_url }
  end

  def post_page_option(post, add_label_prefix: true)
    label = add_label_prefix ? "Post — #{post.name}" : post.name
    { id: "post_page-#{post.external_id}", label:, url: post.full_url }
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
                            destination_option: profile_page_option,
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
      expect(described_class.new(seller:, utm_link:).utm_link_props[:destination_option]).to eq(product_page_option(product, add_label_prefix: false))

      # resource_type: post_page
      utm_link.update!(target_resource_type: "post_page", target_resource_id: post.id)
      expect(described_class.new(seller:, utm_link:).utm_link_props[:destination_option]).to eq(post_page_option(post, add_label_prefix: false))

      # resource_type: subscribe_page
      utm_link.update!(target_resource_type: "subscribe_page")
      expect(described_class.new(seller:, utm_link:).utm_link_props[:destination_option]).to eq(subscribe_page_option)

      # resource_type: profile_page
      utm_link.update!(target_resource_type: "profile_page")
      expect(described_class.new(seller:, utm_link:).utm_link_props[:destination_option]).to eq(profile_page_option)
    end
  end

  describe "#new_page_react_props" do
    it "returns the form props for a new UTM link" do
      allow(SecureRandom).to receive(:alphanumeric).and_return("unique01")

      props = described_class.new(seller:).new_page_react_props.deep_symbolize_keys

      expect(props).to eq(
                           {
                             target_resource_type: nil,
                             utm_source: nil,
                             utm_medium: nil,
                             utm_campaign: nil,
                             utm_term: nil,
                             utm_content: nil,
                             title: "",
                             target_resource_id: nil,
                             destination_option: nil,
                             permalink: "unique01"
                           }
                          )
    end

    it "returns 'utm_link', and 'destination_option' in the props when 'copy_from' is provided" do
      utm_link.update!(title: "Existing UTM Link")

      props = described_class.new(seller:).new_page_react_props(copy_from: utm_link.external_id).deep_symbolize_keys

      expect(props).to eq({
                            target_resource_type: "profile_page",
                            permalink: props[:permalink],
                            utm_source: "facebook",
                            utm_medium: "social",
                            utm_campaign: "spring",
                            utm_term: "sale",
                            utm_content: "banner",
                            title: "Existing UTM Link (copy)",
                            target_resource_id: nil,
                            destination_option: profile_page_option
                          })

      product = create(:product, user: seller, name: "Product A")
      post = create(:audience_post, seller:, name: "Post A")

      utm_link.update!(target_resource_type: "product_page", target_resource_id: product.id)
      props = described_class.new(seller:).new_page_react_props(copy_from: utm_link.external_id).deep_symbolize_keys
      expect(props[:destination_option]).to eq(product_page_option(product, add_label_prefix: true))

      utm_link.update!(target_resource_type: "post_page", target_resource_id: post.id)
      props = described_class.new(seller:).new_page_react_props(copy_from: utm_link.external_id).deep_symbolize_keys
      expect(props[:destination_option]).to eq(post_page_option(post, add_label_prefix: true))

      utm_link.update!(target_resource_type: "subscribe_page")
      props = described_class.new(seller:).new_page_react_props(copy_from: utm_link.external_id).deep_symbolize_keys
      expect(props[:destination_option]).to eq(subscribe_page_option)
    end
  end

  describe "#edit_page_react_props" do
    it "returns the form props for an existing UTM link" do
      props = described_class.new(seller:, utm_link:).edit_page_react_props.deep_symbolize_keys

      expect(props).to eq({
                            target_resource_type: "profile_page",
                            permalink: utm_link.permalink,
                            utm_source: "facebook",
                            utm_medium: "social",
                            utm_campaign: "spring",
                            utm_term: "sale",
                            utm_content: "banner",
                            title: utm_link.title,
                            id: utm_link.external_id,
                            target_resource_id: nil,
                            destination_option: profile_page_option
                          })

      utm_link.update!(target_resource_type: "product_page", target_resource_id: product.id)
      props = described_class.new(seller:, utm_link:).edit_page_react_props.deep_symbolize_keys
      expect(props[:destination_option]).to eq(product_page_option(product, add_label_prefix: true))

      utm_link.update!(target_resource_type: "post_page", target_resource_id: post.id)
      props = described_class.new(seller:, utm_link:).edit_page_react_props.deep_symbolize_keys
      expect(props[:destination_option]).to eq(post_page_option(post, add_label_prefix: true))

      utm_link.update!(target_resource_type: "subscribe_page")
      props = described_class.new(seller:, utm_link:).edit_page_react_props.deep_symbolize_keys
      expect(props[:destination_option]).to eq(subscribe_page_option)
    end
  end

  describe "#utm_link_form_context_props" do
    it "returns the props with destination options, short URL prefix, short URL protocol, and UTM fields values" do
      props = described_class.new(seller:).utm_link_form_context_props.deep_symbolize_keys

      expect(props).to eq({
                            destination_options: [
                              profile_page_option,
                              subscribe_page_option,
                              product_page_option(product),
                              post_page_option(post)
                            ],
                            short_url_prefix: UtmLink.short_url_prefix,
                            short_url_protocol: PROTOCOL,
                            utm_fields_values: {
                              campaigns: ["spring"],
                              mediums: ["social"],
                              sources: ["facebook"],
                              terms: ["sale"],
                              contents: ["banner"]
                            }
                          })
    end

    it "returns empty arrays for utm_fields_values when no UTM links exist" do
      new_seller = create(:user)
      props = described_class.new(seller: new_seller).utm_link_form_context_props.deep_symbolize_keys

      expect(props[:utm_fields_values]).to eq({
                                                campaigns: [],
                                                mediums: [],
                                                sources: [],
                                                terms: [],
                                                contents: []
                                              })
    end
  end
end
