# frozen_string_literal: true

require "spec_helper"

describe "UserCustomDomainScenario", type: :system, js: true do
  include FillInUserProfileHelpers

  before do
    allow(Resolv::DNS).to receive_message_chain(:new, :getresources).and_return([double(name: "domains.gumroad.com")])
    Link.__elasticsearch__.create_index!(force: true)
    @user = create(:user, username: "test")
    section = create(:seller_profile_products_section, seller: @user)
    create(:seller_profile, seller: @user, json_data: { tabs: [{ name: "", sections: [section.id] }] })
    @custom_domain = CustomDomain.new
    @custom_domain.user = @user
    @custom_domain.domain = "test-custom-domain.gumroad.com"
    @custom_domain.save
    @product = create(:product, user: @user)
    @port = Capybara.current_session.server.port
    @product.__elasticsearch__.index_document
    Link.__elasticsearch__.refresh_index!
  end

  describe "Follow / Unfollow" do
    it "loads the user profile page and sends create follower request" do
      visit "http://#{@custom_domain.domain}:#{@port}"
      submit_follow_form(with: "follower@gumroad.com")
      expect(page).to have_alert(text: "Check your inbox to confirm your follow request.")
    end

    it "handles the follow confirmation request" do
      follower = create(:follower, user: @user)
      expect(follower.confirmed_at).to be(nil)
      visit "http://#{@custom_domain.domain}:#{@port}#{confirm_follow_path(follower.external_id)}"
      expect(page).to have_alert(text: "Thanks for the follow!")
      expect(follower.reload.confirmed_at).not_to be(nil)
    end

    it "handles the follow cancellation request" do
      follower = create(:active_follower, user: @user)

      visit "http://#{@custom_domain.domain}:#{@port}#{cancel_follow_path(follower.external_id)}"

      expect(page).to have_text("You have been unsubscribed.")
      expect(page).to have_text("You will no longer get posts from this creator.")
      expect(follower.reload).to be_unconfirmed
      expect(follower.reload).to be_deleted
    end
  end

  describe "product share_url" do
    it "contains link to individual product page with custom domain" do
      visit "http://#{@custom_domain.domain}:#{@port}/"
      find_product_card(@product).click
      expect(page).to have_current_path("http://#{@custom_domain.domain}:#{@port}/l/#{@product.unique_permalink}?layout=profile")
    end
  end

  describe "gumroad logo" do
    it "links to the homepage via Gumroad logo in the footer" do
      visit "http://#{@custom_domain.domain}:#{@port}/"
      expect(find("main > footer")).to have_link("Gumroad", href: "#{UrlService.root_domain_with_protocol}/")
    end
  end

  describe "Custom domain support in widgets" do
    let(:custom_domain_base_uri) { "http://#{@custom_domain.domain}:#{@port}" }
    let(:product_url) { "#{custom_domain_base_uri}/l/#{@product.unique_permalink}" }
    let(:js_nonce) { SecureRandom.base64(32).chomp }

    describe "Embed widget" do
      include EmbedHelpers

      after(:all) { cleanup_embed_artifacts }

      it "allows displaying and purchasing a product in Embed using its custom domain URL" do
        visit(create_embed_page(@product, url: product_url, gumroad_params: "&email=sam@test.com", outbound: false, custom_domain_base_uri:))

        within_frame { click_on "Add to cart" }

        check_out(@product)
      end
    end
  end
end
