# frozen_string_literal: true

require "spec_helper"

describe SaveUtmLinkService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:post) { create(:audience_post, :published, shown_on_profile: true, seller:) }

  describe "#perform" do
    context "when 'utm_link' is not provided" do
      it "creates a UTM link for a product page" do
        expect do
          described_class.new(
            seller:,
            params: {
              title: "Test Link",
              target_resource_id: product.external_id,
              target_resource_type: "product_page",
              permalink: "abc12345",
              utm_source: "facebook",
              utm_medium: "social",
              utm_campaign: "summer",
              utm_term: "sale",
              utm_content: "banner",
              ip_address: "192.168.1.1",
              browser_guid: "1234567890"
            }
          ).perform
        end.to change { seller.utm_links.count }.by(1)

        utm_link = seller.utm_links.last
        expect(utm_link).to have_attributes(
          title: "Test Link",
          target_resource_type: "product_page",
          target_resource_id: product.id,
          permalink: "abc12345",
          utm_source: "facebook",
          utm_medium: "social",
          utm_campaign: "summer",
          utm_term: "sale",
          utm_content: "banner",
          ip_address: "192.168.1.1",
          browser_guid: "1234567890"
        )
      end

      it "creates a UTM link for a post page" do
        expect do
          described_class.new(
            seller:,
            params: {
              title: "Test Link",
              target_resource_id: post.external_id,
              target_resource_type: "post_page",
              permalink: "abc12345",
              utm_source: "twitter",
              utm_medium: "social",
              utm_campaign: "winter"
            }
          ).perform
        end.to change { seller.utm_links.count }.by(1)

        utm_link = seller.utm_links.last
        expect(utm_link).to have_attributes(
          title: "Test Link",
          target_resource_type: "post_page",
          target_resource_id: post.id,
          permalink: "abc12345",
          utm_source: "twitter",
          utm_medium: "social",
          utm_campaign: "winter",
          utm_term: nil,
          utm_content: nil
        )
      end

      it "creates a UTM link for the profile page" do
        expect do
          described_class.new(
            seller:,
            params: {
              title: "Test Link",
              target_resource_id: nil,
              target_resource_type: "profile_page",
              permalink: "abc12345",
              utm_source: "instagram",
              utm_medium: "social",
              utm_campaign: "spring"
            }
          ).perform
        end.to change { seller.utm_links.count }.by(1)

        utm_link = seller.utm_links.last
        expect(utm_link).to have_attributes(
          title: "Test Link",
          target_resource_type: "profile_page",
          target_resource_id: nil,
          permalink: "abc12345",
          utm_source: "instagram",
          utm_medium: "social",
          utm_campaign: "spring"
        )
      end

      it "creates a UTM link for the subscribe page" do
        expect do
          described_class.new(
            seller:,
            params: {
              title: "Test Link",
              target_resource_type: "subscribe_page",
              permalink: "abc12345",
              utm_source: "newsletter",
              utm_medium: "email",
              utm_campaign: "subscribe"
            }
          ).perform
        end.to change { seller.utm_links.count }.by(1)

        utm_link = seller.utm_links.last
        expect(utm_link).to have_attributes(
          title: "Test Link",
          target_resource_type: "subscribe_page",
          target_resource_id: nil,
          permalink: "abc12345",
          utm_source: "newsletter",
          utm_medium: "email",
          utm_campaign: "subscribe"
        )
      end

      it "raises an error if the UTM link fails to save" do
        expect do
          described_class.new(
            seller:,
            params: {
              title: "Test Link",
              target_resource_type: "product_page",
              target_resource_id: product.external_id,
              permalink: "abc",
              utm_source: "facebook",
              utm_medium: "social",
              utm_campaign: "summer",
            }
          ).perform
        end.to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Permalink is invalid")
      end
    end

    context "when 'utm_link' is provided" do
      let(:utm_link) { create(:utm_link, seller:, ip_address: "192.168.1.1", browser_guid: "1234567890") }
      let(:params) do
        {
          title: "Updated Title",
          target_resource_id: product.external_id,
          target_resource_type: "product_page",
          permalink: "abc12345",
          utm_source: "facebook",
          utm_medium: "social",
          utm_campaign: "summer",
          utm_term: "sale",
          utm_content: "banner",
          ip_address: "172.0.0.1",
          browser_guid: "9876543210"
        }
      end

      it "updates only the permitted attributes" do
        old_permalink = utm_link.permalink

        described_class.new(seller:, params:, utm_link:).perform

        utm_link.reload
        expect(utm_link.title).to eq("Updated Title")
        expect(utm_link.target_resource_id).to be_nil
        expect(utm_link.target_resource_type).to eq("profile_page")
        expect(utm_link.permalink).to eq(old_permalink)
        expect(utm_link.utm_source).to eq("facebook")
        expect(utm_link.utm_medium).to eq("social")
        expect(utm_link.utm_campaign).to eq("summer")
        expect(utm_link.utm_term).to eq("sale")
        expect(utm_link.utm_content).to eq("banner")
        expect(utm_link.ip_address).to eq("192.168.1.1")
        expect(utm_link.browser_guid).to eq("1234567890")
      end

      it "raises an error if the UTM link fails to save" do
        params[:utm_source] = "a" * 256

        expect do
          described_class.new(seller:, params:, utm_link:).perform
        end.to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Utm source is too long (maximum is 200 characters)")
      end
    end
  end
end
