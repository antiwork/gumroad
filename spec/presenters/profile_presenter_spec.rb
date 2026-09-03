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
  let(:encrypted_tabs) { tabs.map { |tab| { **tab, sections: tab[:sections].map { ObfuscateIds.encrypt(_1) } } } }

  before do
    seller.seller_profile.json_data[:tabs] = tabs
    seller.seller_profile.save!
    create(:team_membership, user: logged_in_user, seller:, role: TeamMembership::ROLE_ADMIN)
  end

  describe "#creator_profile" do
    it "returns profile data object" do
      expect(presenter.creator_profile).to eq(
        {
          avatar_url: ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png"),
          external_id: seller.external_id,
          name: seller.name,
          twitter_handle: nil,
          youtube_channel_id: nil,
          subdomain: seller.subdomain,
          is_verified: false,
          can_edit: true,
          follow_recaptcha_site_key: FollowRecaptcha.site_key,
          hide_follow_form: false,
        }
      )
    end


    it "includes the YouTube channel id on the public profile and the handle only on settings props" do
      create(:user_youtube_identity, user: seller, channel_id: "UC123", handle: "googledevelopers")
      seller.reload

      expect(described_class.new(pundit_user: SellerContext.logged_out, seller:).creator_profile).not_to have_key(:youtube_handle)
      expect(described_class.new(pundit_user: SellerContext.logged_out, seller:).creator_profile[:youtube_channel_id]).to eq("UC123")
      expect(described_class.new(pundit_user:, seller:).profile_settings_props(request:)[:youtube_handle]).to eq("googledevelopers")
      expect(described_class.new(pundit_user:, seller:).profile_settings_props(request:)[:youtube_connected]).to eq(true)
    end

    it "includes hide_follow_form when the seller has turned it on" do
      seller.update!(hide_follow_form: true)

      expect(described_class.new(pundit_user:, seller: seller.reload).creator_profile[:hide_follow_form]).to eq(true)
    end

    it "omits the follow CAPTCHA key for a compliant seller" do
      seller.update!(user_risk_state: "compliant")

      expect(described_class.new(pundit_user:, seller: seller.reload).creator_profile[:follow_recaptcha_site_key]).to be_nil
    end

    it "includes the follow CAPTCHA key for a seller who has not been reviewed" do
      expect(seller.user_risk_state).to eq("not_reviewed")

      expect(presenter.creator_profile[:follow_recaptcha_site_key]).to eq(FollowRecaptcha.site_key)
    end

    it "sets can_edit to false when viewing as another seller" do
      other_seller = create(:user)
      pundit_user = SellerContext.new(user: logged_in_user, seller: other_seller)

      expect(described_class.new(pundit_user:, seller:).creator_profile[:can_edit]).to eq(false)
    end

    describe "reputation" do
      it "omits the key when the seller_reputation_summary flag is off" do
        expect(presenter.creator_profile).not_to have_key(:reputation)
      end

      it "includes the summary when the flag is on" do
        Feature.activate_user(:seller_reputation_summary, seller)
        summary = { average: 4.8, count: 12, products_count: 2 }
        allow(seller).to receive(:seller_reputation_summary).and_return(summary)

        expect(presenter.creator_profile[:reputation]).to eq(summary)
      end

      it "includes a nil summary when the flag is on but thresholds are unmet" do
        Feature.activate_user(:seller_reputation_summary, seller)

        expect(presenter.creator_profile[:reputation]).to be_nil
      end
    end

    it "sets can_edit to false for profile view-only team members" do
      support_user = create(:user)
      create(:team_membership, user: support_user, seller:, role: TeamMembership::ROLE_SUPPORT)
      pundit_user = SellerContext.new(user: support_user, seller:)

      expect(described_class.new(pundit_user:, seller:).creator_profile[:can_edit]).to eq(false)
    end

    it "sets can_edit to false when logged out" do
      expect(described_class.new(pundit_user: SellerContext.logged_out, seller:).creator_profile[:can_edit]).to eq(false)
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
          tabs: encrypted_tabs,
          seller_analytics: {
            seller_id: seller.external_id,
            analytics: {
              google_analytics_id: nil,
              facebook_pixel_id: nil,
              tiktok_pixel_id: nil,
              free_sales: true,
            },
            has_universal_third_party_analytics: false,
            username: seller.username,
          }
        }
      )
    end

    it "returns visitor-style section props when logged in as the seller" do
      props = presenter.profile_props(seller_custom_domain_url: nil, request:)

      expect(props[:creator_profile][:can_edit]).to eq(true)
      expect(props).not_to have_key(:products)
      expect(props).not_to have_key(:posts)
      expect(props).not_to have_key(:wishlist_options)
      expect(props[:sections].first).not_to have_key(:shown_products)
    end

    it "reflects the logged-in viewer's state rather than a logged-out view" do
      wishlist = create(:wishlist, user: seller)
      follower = create(:user)
      create(:wishlist_follower, wishlist:, follower_user: follower)
      wishlist_section = create(:seller_profile_wishlists_section, seller:, shown_wishlists: [wishlist.id])

      pundit_user = SellerContext.new(user: follower, seller: follower)
      props = described_class.new(pundit_user:, seller: seller.reload).profile_props(seller_custom_domain_url: nil, request:)

      wishlist_props = props[:sections].find { _1[:id] == wishlist_section.external_id }[:wishlists].first
      expect(wishlist_props[:following]).to eq(true)
    end

    it "keeps the seller's own viewer state while serving visitor-shaped sections" do
      seller.update!(currency_type: "eur")
      pundit_user = SellerContext.new(user: seller, seller:)
      props = described_class.new(pundit_user:, seller: seller.reload).profile_props(seller_custom_domain_url: nil, request:)

      expect(props[:currency_code]).to eq("eur")
      expect(props).not_to have_key(:products)
      expect(props[:sections].first).not_to have_key(:shown_products)
    end

    context "when the seller has products but no profile sections" do
      let(:new_seller) { create(:user, name: "New Seller") }
      let!(:new_seller_product) { create(:product, user: new_seller) }
      let(:visitor_pundit_user) { SellerContext.new(user: logged_in_user, seller: logged_in_user) }

      before { Link.import(force: true, refresh: true) }

      it "serves the virtual default products section with a matching tab" do
        props = described_class.new(pundit_user: visitor_pundit_user, seller: new_seller).profile_props(seller_custom_domain_url: nil, request:)

        expect(props[:sections].size).to eq(1)
        expect(props[:sections].first[:id]).to eq(ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID)
        expect(props[:sections].first[:type]).to eq("SellerProfileProductsSection")
        # The frontend only renders sections referenced by a tab, so the virtual section needs
        # one pointing at it.
        expect(props[:tabs]).to eq([{ name: "Products", sections: [ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID] }])
      end

      it "does not serve the virtual section in the profile editor payload" do
        pundit_user = SellerContext.new(user: new_seller, seller: new_seller)
        props = described_class.new(pundit_user:, seller: new_seller).profile_settings_props(request:)

        expect(props[:editable_profile][:sections]).to eq([])
      end
    end

    context "when the seller's tabs reference none of their saved sections" do
      let(:broken_seller) { create(:user, name: "Broken Seller") }
      let!(:broken_seller_product) { create(:product, user: broken_seller) }
      let!(:text_section) { create(:seller_profile_rich_text_section, seller: broken_seller) }
      let!(:products_section) { create(:seller_profile_products_section, seller: broken_seller, header: "Products") }
      let(:visitor_pundit_user) { SellerContext.new(user: logged_in_user, seller: logged_in_user) }

      before do
        broken_seller.seller_profile.update!(json_data: { tabs: [{ name: "New page", sections: [] }] })
        Link.import(force: true, refresh: true)
      end

      it "serves a single tab pointing at every saved section instead of the empty saved tab" do
        props = described_class.new(pundit_user: visitor_pundit_user, seller: broken_seller).profile_props(seller_custom_domain_url: nil, request:)

        expect(props[:sections].map { _1[:id] }).to match_array([text_section.external_id, products_section.external_id])
        expect(props[:tabs]).to eq([{ name: "New page", sections: [text_section.external_id, products_section.external_id] }])
      end

      it "orders the fallback tab's sections by id regardless of the query's return order" do
        # The sections query has no ORDER BY; simulate the database returning rows in a
        # different plan-dependent order.
        allow_any_instance_of(ProfileSectionsPresenter).to receive(:props).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap { _1[:sections] = _1[:sections].reverse }
        end

        props = described_class.new(pundit_user: visitor_pundit_user, seller: broken_seller).profile_props(seller_custom_domain_url: nil, request:)

        expect(props[:tabs]).to eq([{ name: "New page", sections: [text_section.external_id, products_section.external_id] }])
      end

      it "repairs tabs whose only references point at sections that no longer exist" do
        broken_seller.seller_profile.update!(json_data: { tabs: [{ name: "New page", sections: [products_section.id + 100] }] })

        props = described_class.new(pundit_user: visitor_pundit_user, seller: broken_seller).profile_props(seller_custom_domain_url: nil, request:)

        expect(props[:tabs]).to eq([{ name: "New page", sections: [text_section.external_id, products_section.external_id] }])
      end

      it "leaves the saved tabs alone when any tab references a saved section" do
        broken_seller.seller_profile.update!(json_data: { tabs: [{ name: "Empty page", sections: [] }, { name: "Store", sections: [products_section.id] }] })

        props = described_class.new(pundit_user: visitor_pundit_user, seller: broken_seller).profile_props(seller_custom_domain_url: nil, request:)

        expect(props[:tabs]).to eq(
          [
            { name: "Empty page", sections: [] },
            { name: "Store", sections: [products_section.external_id] },
          ]
        )
      end

      it "does not repair the profile editor payload" do
        pundit_user = SellerContext.new(user: broken_seller, seller: broken_seller)
        props = described_class.new(pundit_user:, seller: broken_seller).profile_settings_props(request:)

        expect(props[:editable_profile][:tabs]).to eq([{ name: "New page", sections: [] }])
      end
    end

    context "when the seller has no products and no profile sections" do
      it "keeps the empty-sections shape so the email signup fallback still renders" do
        new_seller = create(:user, name: "New Seller")
        visitor_pundit_user = SellerContext.new(user: logged_in_user, seller: logged_in_user)

        props = described_class.new(pundit_user: visitor_pundit_user, seller: new_seller).profile_props(seller_custom_domain_url: nil, request:)

        expect(props[:sections]).to eq([])
        expect(props[:tabs]).to eq([])
      end
    end
  end

  describe "#profile_settings_props" do
    it "returns profile settings props object" do
      Link.import(force: true, refresh: true)
      props = presenter.profile_settings_props(request:)

      expect(props).to match(
        {
          profile_settings: {
            name: seller.name,
            bio: seller.bio,
            font: seller.seller_profile.font,
            background_color: seller.seller_profile.background_color,
            highlight_color: seller.seller_profile.highlight_color,
            profile_picture_blob_id: nil,
            product_page_storefront_enabled: seller.product_page_storefront_enabled?,
            hide_follow_form: seller.hide_follow_form?,
          },
          editable_profile: {
            **ProfileSectionsPresenter.new(seller:, query: seller.seller_profile_sections.on_profile).props(request:, pundit_user:, seller_custom_domain_url: nil),
            bio: "Bio",
            tabs: encrypted_tabs,
          },
          memberships: [ProductPresenter.card_for_web(product: membership_product, show_seller: false)],
          profile_version: a_kind_of(String),
          seller_fonts_css_source: SellerProfile.seller_fonts_css_source,
          email_confirmation: nil,
          custom_html_pages_enabled: false,
          youtube_connect_enabled: false,
          youtube_connected: false,
          youtube_handle: nil,
          has_custom_landing_page: false,
          username: seller.username,
          # seller_analytics is only added to the public profile_props — the settings
          # editor never boots visitor tracking.
          **described_class.new(pundit_user: SellerContext.logged_out, seller:).profile_props(request:, seller_custom_domain_url: nil).except(:seller_analytics),
        }
      )
      expect(props[:profile_settings]).not_to have_key(:username)
    end

    describe "email_confirmation" do
      it "is nil when the seller's email is confirmed" do
        expect(presenter.profile_settings_props(request:)[:email_confirmation]).to be_nil
      end

      it "includes confirmation details when the seller's email is unconfirmed" do
        seller.update_columns(confirmed_at: nil)
        owner_pundit_user = SellerContext.new(user: seller, seller:)
        props = described_class.new(pundit_user: owner_pundit_user, seller: seller.reload).profile_settings_props(request:)

        expect(props[:email_confirmation]).to eq(
          {
            email: seller.email,
            can_resend: true,
          }
        )
      end

      it "is nil when a confirmed seller has a pending email change" do
        seller.update_columns(unconfirmed_email: "new-address@example.com")

        expect(presenter.profile_settings_props(request:)[:email_confirmation]).to be_nil
      end

      it "doesn't allow resending for a non-owner team member" do
        seller.update_columns(confirmed_at: nil)

        expect(presenter.profile_settings_props(request:)[:email_confirmation][:can_resend]).to eq(false)
      end

      it "names the pending address when an unconfirmed seller also has an email change in flight" do
        seller.update_columns(confirmed_at: nil, unconfirmed_email: "new-address@example.com")

        expect(presenter.profile_settings_props(request:)[:email_confirmation][:email]).to eq("new-address@example.com")
      end

      it "represents an unconfirmed seller with no email without offering a resend" do
        seller.update_columns(confirmed_at: nil, email: nil, unconfirmed_email: nil)

        expect(presenter.profile_settings_props(request:)[:email_confirmation]).to eq(
          {
            email: nil,
            can_resend: false,
          }
        )
      end
    end

    context "when the custom_html_pages feature is enabled and a custom profile page is live" do
      before do
        Feature.activate_user(:custom_html_pages, seller)
        seller.update!(custom_html: "<h1 data-gumroad-field=\"name\"></h1>")
      end

      it "exposes the custom-HTML props for the Build-with-your-agent affordance" do
        props = presenter.profile_settings_props(request:)

        expect(props[:custom_html_pages_enabled]).to be(true)
        expect(props[:has_custom_landing_page]).to be(true)
        expect(props[:username]).to eq(seller.username)
      end
    end
  end
end
