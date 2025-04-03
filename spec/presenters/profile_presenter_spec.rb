# frozen_string_literal: true

describe ProfilePresenter do
  include Rails.application.routes.url_helpers

  let(:seller) { create(:named_seller, bio: "Bio") }
  let(:logged_in_user) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: logged_in_user, seller:) }
  let!(:post) do
    create(
      :published_installment,
      installment_type: Installment::AUDIENCE_TYPE,
      seller:,
      shown_on_profile: true
    )
  end
  let!(:tag1) { create(:tag) }
  let!(:tag2) { create(:tag) }
  let!(:membership_product) { create(:membership_product, user: seller, name: "Product", tags: [tag1, tag2]) }
  let!(:simple_product) { create(:product, user: seller) }
  let!(:featured_product) { create(:product, user: seller, name: "Featured Product", archived: true, deleted_at: Time.current) }
  let(:presenter) { described_class.new(pundit_user:, seller: seller.reload) }
  let(:request) { ActionDispatch::TestRequest.create }
  let!(:section) { create(:seller_profile_products_section, header: "Section 1", hide_header: true, seller:, shown_products: [membership_product.id, simple_product.id]) }
  let!(:section2) { create(:seller_profile_posts_section, header: "Section 2", seller:, shown_posts: [post.id]) }
  let!(:section3) { create(:seller_profile_featured_product_section, header: "Section 3", seller:, featured_product_id: featured_product.id) }
  let(:tabs) { [{ name: "Tab 1", sections: [section.id, section2.id] }, { name: "Tab2", sections: [] }] }

  before do
    seller.seller_profile.json_data[:tabs] = tabs
    seller.seller_profile.save!
    create(:team_membership, user: logged_in_user, seller:, role: TeamMembership::ROLE_ADMIN)
  end

  describe "#creator_profile" do
    it "returns profile data object" do
      expect(presenter.creator_profile).to eq(
        {
          avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
          external_id: seller.external_id,
          name: seller.name,
          twitter_handle: nil,
          subdomain: seller.subdomain,
        }
      )
    end
  end

  describe "#profile_props" do
    it "returns the props for the profile products tab" do
      Link.import(force: true, refresh: true)
      pundit_user = SellerContext.new(user: logged_in_user, seller: create(:user))
      sections_presenter = ProfileSectionsPresenter.new(seller:, query: seller.seller_profile_sections.on_profile)
      expect(ProfileSectionsPresenter).to receive(:new).with(seller:, query: seller.seller_profile_sections.on_profile).and_call_original
      props = described_class.new(pundit_user:, seller: seller.reload).profile_props(request:, seller_custom_domain_url: nil)
      expect(props).to match(
        {
          **sections_presenter.props(request:, pundit_user:, seller_custom_domain_url: nil),
          bio: "Bio",
          tabs: tabs.map { | tab| { **tab, sections: tab[:sections].map { ObfuscateIds.encrypt(_1) } } }
        }
      )
    end

    it "includes data for the edit view when logged in as the seller" do
      props = presenter.profile_props(seller_custom_domain_url: nil, request:)
      expect(props).to match a_hash_including(ProfileSectionsPresenter.new(seller:, query: seller.seller_profile_sections.on_profile).props(request:, pundit_user:, seller_custom_domain_url: nil))
    end
  end

  describe "#profile_settings_props" do
    it "returns profile settings props object" do
      Link.import(force: true, refresh: true)
      expect(presenter.profile_settings_props(request:)).to match(
        {
          profile_settings: {
            name: seller.name,
            username: seller.username,
            bio: seller.bio,
            background_color: "#ffffff",
            highlight_color: "#ff90e8",
            font: "ABC Favorit",
            profile_picture_blob_id: nil,
          },
          memberships: [ProductPresenter.card_for_web(product: membership_product, show_seller: false)],
          **described_class.new(pundit_user: SellerContext.logged_out, seller:).profile_props(request:, seller_custom_domain_url: nil),
        }
      )
    end
  end
end
