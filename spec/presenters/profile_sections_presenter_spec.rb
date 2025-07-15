# frozen_string_literal: true

describe ProfileSectionsPresenter do
  let(:seller) { create(:named_seller, bio: "Bio") }
  let(:logged_in_user) { create(:user) }
  let(:request) { ActionDispatch::TestRequest.create }
  let(:pundit_user) { SellerContext.new(user: logged_in_user, seller: logged_in_user) }
  let(:pundit_user_seller) { SellerContext.new(user: seller, seller:) }
  let(:tags) { create_list(:tag, 2) }
  let!(:products) { create_list(:product, 2, user: seller, tags:) }
  let!(:seller_post) { create(:seller_installment, seller:, shown_on_profile: true, published_at: 1.day.ago) }
  let!(:posts) { build_list(:published_installment, 2, installment_type: Installment::AUDIENCE_TYPE, seller:, shown_on_profile: true) { |p, i| p.update!(published_at: p.published_at - i.days) } }
  let!(:wishlists) { create_list(:wishlist, 2, user: seller) }
  let(:products_section) { create(:seller_profile_products_section, seller:, header: "Section!", shown_products: products.map(&:id)) }
  let(:posts_section) { create(:seller_profile_posts_section, seller:, header: "Section!", shown_posts: posts.map(&:id)) }
  let(:featured_product_section) { create(:seller_profile_featured_product_section, seller:, header: "Section!", featured_product_id: products.first.id) }
  let(:rich_text_section) { create(:seller_profile_rich_text_section, seller:, header: "Section!", text: { something: "thing" }) }
  let(:subscribe_section) { create(:seller_profile_subscribe_section, seller:, header: "Section!", hide_header: true) }
  let(:wishlists_section) { create(:seller_profile_wishlists_section, seller:, header: "Section!", shown_wishlists: wishlists.map(&:id)) }
  let!(:sections) { [products_section, posts_section, featured_product_section, rich_text_section, subscribe_section, wishlists_section] }
  let!(:extra_section) { create(:seller_profile_products_section, seller:) }
  subject { described_class.new(seller:, query: seller.seller_profile_sections.where(id: sections.map(&:id))) }

  before do
    Link.import(force: true, refresh: true)
  end

  def common_props(section)
    { id: section.external_id, type: section.type, header: section.header }
  end

  def cached_sections_props
    [
      {
        **common_props(products_section),
        default_product_sort: "page_layout",
        search_results: {
          total: 2,
          filetypes_data: [],
          tags_data: a_collection_containing_exactly(*tags.map { { "doc_count" => 2, "key" => _1.name } }),
          products: products.map { _1.id.to_s }
        },
        show_filters: false,
      },
      common_props(posts_section),
      {
        **common_props(featured_product_section),
        featured_product_id: products.first.external_id
      },
      {
        **common_props(rich_text_section),
        text: rich_text_section.text
      },
      {
        **common_props(subscribe_section),
        header: nil,
        button_label: subscribe_section.button_label
      },
      {
        **common_props(wishlists_section),
        shown_wishlists: wishlists.map(&:external_id)
      }
    ]
  end

  describe "#cached_sections" do
    it "returns the cached array of sections for the given query" do
      expect(subject.cached_sections).to match(cached_sections_props)
    end
  end

  describe "#props" do
    def common_sections_props
      sections = cached_sections_props
      sections[0][:search_results][:products] = products.map do |product|
        ProductPresenter.card_for_web(product:, request:, target: Product::Layout::PROFILE, show_seller: false, compute_description: false)
      end
      sections
    end

    def post_data(post)
      {
        id: post.external_id,
        name: post.name,
        slug: post.slug,
        published_at: post.published_at,
      }
    end

    it "returns the correct props for the seller" do
      sections = common_sections_props
      sections[0].merge!({ hide_header: false, shown_products: products.map(&:external_id), add_new_products: true })
      sections[1].merge!({ shown_posts: posts.map(&:external_id), hide_header: false })
      sections[2].merge!({ hide_header: false })
      sections[3].merge!({ hide_header: false })
      sections[4].merge!({ hide_header: true, header: subscribe_section.header })
      sections[5].merge!(hide_header: false, wishlists: WishlistPresenter.cards_props(wishlists: Wishlist.where(id: wishlists.map(&:id)), pundit_user: pundit_user_seller, layout: Product::Layout::PROFILE))

      expect(subject.props(request:, pundit_user: pundit_user_seller, seller_custom_domain_url: nil)).to match({
                                                                                                                 currency_code: pundit_user_seller.user.currency_type,
                                                                                                                 show_ratings_filter: true,
                                                                                                                 creator_profile: ProfilePresenter.new(seller:, pundit_user: pundit_user_seller).creator_profile,
                                                                                                                 products: products.map { { id: ObfuscateIds.encrypt(_1.id), name: _1.name } },
                                                                                                                 posts: posts.map(&method(:post_data)),
                                                                                                                 wishlist_options: wishlists.map { { id: _1.external_id, name: _1.name } },
                                                                                                                 sections:,
                                                                                                               })
    end

    it "returns the correct props for another user" do
      sections = common_sections_props
      sections[1][:posts] = posts.map(&method(:post_data))
      sections[2][:props] = ProductPresenter.new(product: products.first, request:, pundit_user:).product_props(seller_custom_domain_url: nil)
      sections[2].delete(:featured_product_id)
      sections[5].merge!(wishlists: WishlistPresenter.cards_props(wishlists: Wishlist.where(id: wishlists.map(&:id)), pundit_user: pundit_user, layout: Product::Layout::PROFILE))
      expect(subject.props(request:, pundit_user:, seller_custom_domain_url: nil)).to match({
                                                                                              currency_code: pundit_user.user.currency_type,
                                                                                              show_ratings_filter: true,
                                                                                              creator_profile: ProfilePresenter.new(seller:, pundit_user:).creator_profile,
                                                                                              sections:
                                                                                            })
    end
  end

  describe "compute_description parameter" do
    it "passes compute_description: false to ProductPresenter.card_for_web for search results" do
      request.query_parameters[:sort] = "recent"

      expect(ProductPresenter).to receive(:card_for_web).with(
        product: products.first,
        request: request,
        recommended_by: nil,
        target: Product::Layout::PROFILE,
        show_seller: false,
        compute_description: false
      ).and_call_original

      expect(ProductPresenter).to receive(:card_for_web).with(
        product: products.second,
        request: request,
        recommended_by: nil,
        target: Product::Layout::PROFILE,
        show_seller: false,
        compute_description: false
      ).and_call_original

      subject.props(request:, pundit_user:, seller_custom_domain_url: nil)
    end
  end
end
