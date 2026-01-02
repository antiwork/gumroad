# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe UtmLinksController, inertia: true do
  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  include_context "with user signed in as admin for seller"

  before do
    Feature.activate_user(:utm_links, seller)
  end

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { UtmLink }
    end

    it "returns unauthorized response if the :utm_links feature flag is disabled" do
      Feature.deactivate_user(:utm_links, seller)

      get :index

      expect(response).to redirect_to dashboard_path
      expect(flash[:alert]).to eq("Your current role as Admin cannot perform this action.")
    end

    it "returns seller's paginated alive UTM links" do
      utm_link1 = create(:utm_link, seller:, created_at: 1.day.ago)
      _utm_link2 = create(:utm_link, seller:, deleted_at: DateTime.current)
      utm_link3 = create(:utm_link, seller:, disabled_at: DateTime.current, created_at: 2.days.ago)

      stub_const("PaginatedUtmLinksPresenter::PER_PAGE", 1)

      get :index

      expect(response).to be_successful
      expect(inertia).to render_component("UtmLinks/Index")
      props = inertia.props[:utm_links_props]
      expect(props).to match(PaginatedUtmLinksPresenter.new(seller:).props)
      expect(props[:utm_links]).to match_array([UtmLinkPresenter.new(seller:, utm_link: utm_link1).utm_link_props])
      expect(props[:pagination]).to eq(pages: 2, page: 1)

      get :index, params: { page: 2 }

      expect(response).to be_successful
      props = inertia.props[:utm_links_props]
      expect(props).to match(PaginatedUtmLinksPresenter.new(seller:, page: 2).props)
      expect(props[:utm_links]).to match_array([UtmLinkPresenter.new(seller:, utm_link: utm_link3).utm_link_props])
      expect(props[:pagination]).to eq(pages: 2, page: 2)

      expect do
        get :index, params: { page: 3 }

        expect(response).to be_successful
        props = inertia.props[:utm_links_props]
        expect(props[:utm_links]).to match_array([UtmLinkPresenter.new(seller:, utm_link: utm_link3).utm_link_props])
        expect(props[:pagination]).to eq(pages: 2, page: 2)
      end.not_to raise_error
    end

    it "sorts by date in descending order by default" do
      utm_link1 = create(:utm_link, seller:, created_at: 1.day.ago)
      utm_link2 = create(:utm_link, seller:, created_at: 3.days.ago)
      utm_link3 = create(:utm_link, seller:, created_at: 2.days.ago)

      get :index

      expect(response).to be_successful
      props = inertia.props[:utm_links_props]
      expect(props[:utm_links].map { |l| l[:id] }).to eq([
                                                           utm_link1.external_id,
                                                           utm_link3.external_id,
                                                           utm_link2.external_id
                                                         ])
    end

    it "sorts UTM links by the specified column" do
      create(:utm_link, seller:, title: "C Link", created_at: 1.day.ago)
      create(:utm_link, seller:, title: "A Link", created_at: 3.days.ago)
      create(:utm_link, seller:, title: "B Link", created_at: 2.days.ago)

      get :index, params: { key: "link", direction: "asc" }

      expect(response).to be_successful
      props = inertia.props[:utm_links_props]
      expect(props[:utm_links].map { _1[:title] }).to eq([
                                                           "A Link",
                                                           "B Link",
                                                           "C Link"
                                                         ])

      get :index, params: { key: "link", direction: "desc" }

      expect(response).to be_successful
      props = inertia.props[:utm_links_props]
      expect(props[:utm_links].map { _1[:title] }).to eq([
                                                           "C Link",
                                                           "B Link",
                                                           "A Link"
                                                         ])
    end

    it "filters UTM links by search query" do
      utm_link1 = create(:utm_link, seller:, title: "Facebook Campaign", utm_source: "facebook")
      utm_link2 = create(:utm_link, seller:, title: "Twitter Campaign", utm_source: "twitter")

      get :index, params: { query: "Facebook" }
      expect(response).to be_successful
      props = inertia.props[:utm_links_props]
      expect(props[:utm_links].map { _1[:id] }).to eq([utm_link1.external_id])

      get :index, params: { query: "twitter" }
      expect(response).to be_successful
      props = inertia.props[:utm_links_props]
      expect(props[:utm_links].map { _1[:id] }).to eq([utm_link2.external_id])

      get :index, params: { query: "Campaign" }
      expect(response).to be_successful
      props = inertia.props[:utm_links_props]
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link1.external_id, utm_link2.external_id])

      get :index, params: { query: "nonexistent" }
      expect(response).to be_successful
      props = inertia.props[:utm_links_props]
      expect(props[:utm_links]).to be_empty

      get :index, params: { query: "     " }
      expect(response).to be_successful
      props = inertia.props[:utm_links_props]
      expect(props[:utm_links].map { _1[:id] }).to match_array([utm_link1.external_id, utm_link2.external_id])
    end

    context "with only=[\"utm_links_stats\"] partial request" do
      before do
        request.headers["X-Inertia"] = "true"
        request.headers["X-Inertia-Partial-Component"] = "UtmLinks/Index"
        request.headers["X-Inertia-Partial-Data"] = "utm_links_stats"
      end

      it "returns empty stats when ids param is not provided" do
        get :index

        expect(response).to be_successful
        expect(inertia.props["utm_links_stats"]).to eq({})
      end

      it "returns stats for the requested UTM link IDs when ids param is provided" do
        utm_link1 = create(:utm_link, seller:, unique_clicks: 3)
        utm_link2 = create(:utm_link, seller:, unique_clicks: 1)
        utm_link3 = create(:utm_link, seller:, unique_clicks: 2)
        another_seller_utm_link = create(:utm_link, unique_clicks: 1)
        product = create(:product, user: seller)
        purchase1 = create(:purchase, price_cents: 1000, seller:, link: product)
        purchase2 = create(:purchase, price_cents: 2000, seller:, link: product)
        purchase3 = create(:purchase, price_cents: 0, seller:, link: product)
        test_purchase = create(:test_purchase, price_cents: 3000, seller:, link: product)
        failed_purchase = create(:failed_purchase, price_cents: 1000, seller:, link: product)
        create(:utm_link_driven_sale, utm_link: utm_link1, purchase: purchase1)
        create(:utm_link_driven_sale, utm_link: utm_link1, purchase: purchase2)
        create(:utm_link_driven_sale, utm_link: utm_link2, purchase: purchase3)
        create(:utm_link_driven_sale, utm_link: utm_link2, purchase: test_purchase)
        create(:utm_link_driven_sale, utm_link: utm_link2, purchase: failed_purchase)

        get :index, params: { ids: [utm_link1.external_id, utm_link2.external_id, utm_link3.external_id, another_seller_utm_link.external_id] }

        expect(response).to be_successful
        stats = inertia.props["utm_links_stats"]
        expect(stats).to eq({
                              utm_link1.external_id => { "sales_count" => 2, "revenue_cents" => 3000, "conversion_rate" => 0.6667 },
                              utm_link2.external_id => { "sales_count" => 1, "revenue_cents" => 0, "conversion_rate" => 1.0 },
                              utm_link3.external_id => { "sales_count" => 0, "revenue_cents" => 0, "conversion_rate" => 0.0 },
                            })
        expect(stats).to_not have_key(another_seller_utm_link.external_id)
      end
    end
  end

  describe "GET new" do
    it_behaves_like "authorize called for action", :get, :new do
      let(:record) { UtmLink }
    end

    it "renders Inertia component with correct props" do
      allow(SecureRandom).to receive(:alphanumeric).and_return("unique01")
      get :new

      expect(response).to be_successful
      expect(inertia).to render_component("UtmLinks/New")
      expect(inertia.props[:context]).to be_present
      expect(inertia.props[:context][:destination_options]).to be_an(Array)
      expect(inertia.props[:context][:utm_fields_values]).to be_present
      expect(inertia.props[:context][:short_url_prefix]).to eq(UtmLink.short_url_prefix)
      expect(inertia.props[:context][:short_url_protocol]).to eq(PROTOCOL)
      expect(inertia.props.deep_symbolize_keys[:utm_link][:permalink]).to eq("unique01")
    end

    context "with partial request" do
      before do
        request.headers["X-Inertia"] = "true"
        request.headers["X-Inertia-Partial-Component"] = "UtmLinks/New"
        request.headers["X-Inertia-Partial-Data"] = "utm_link"
      end

      it "returns a new unique permalink" do
        expect_any_instance_of(UtmLinkPresenter).not_to receive(:utm_link_form_context_props)

        get :new

        expect(response).to be_successful
        expect(inertia.props.deep_symbolize_keys[:utm_link][:permalink]).to be_present
      end
    end

    context "when copying from an existing link" do
      let!(:source_link) { create(:utm_link, seller:) }

      it "renders with utm_link data from source" do
        get :new, params: { copy_from: source_link.external_id }

        expect(response).to be_successful
        expect(inertia).to render_component("UtmLinks/New")
        expect(inertia.props[:utm_link]).to be_present
        expect(inertia.props[:utm_link][:title]).to eq("#{source_link.title} (copy)")
        expect(inertia.props[:utm_link][:id]).to be_nil
        expect(inertia.props.deep_symbolize_keys[:utm_link][:permalink]).not_to eq(source_link.permalink)
      end
    end
  end

  describe "GET edit" do
    let!(:utm_link) { create(:utm_link, seller:) }

    before do
      controller.instance_variable_set(:@utm_link, utm_link)
    end

    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { utm_link }
      let(:request_params) { { id: utm_link.external_id } }
    end

    it "renders Inertia component with correct props" do
      get :edit, params: { id: utm_link.external_id }

      expect(response).to be_successful
      expect(inertia).to render_component("UtmLinks/Edit")
      expect(inertia.props[:context]).to be_present
      expect(inertia.props[:context][:destination_options]).to be_an(Array)
      expect(inertia.props[:utm_link]).to be_present
      expect(inertia.props[:context][:short_url_prefix]).to eq(UtmLink.short_url_prefix)
      expect(inertia.props[:context][:short_url_protocol]).to eq(PROTOCOL)
      expect(inertia.props[:utm_link][:id]).to eq(utm_link.external_id)
      expect(inertia.props[:utm_link][:permalink]).to eq(utm_link.permalink)
    end
  end

  describe "POST create" do
    let!(:product) { create(:product, user: seller) }
    let!(:audience_post) { create(:audience_post, :published, shown_on_profile: true, seller:) }
    let(:params) do
      {
        utm_link: {
          title: "Test Link",
          target_resource_id: product.external_id,
          target_resource_type: "product_page",
          permalink: "abc12345",
          utm_source: "facebook",
          utm_medium: "social",
          utm_campaign: "summer",
        }
      }
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { UtmLink }
    end

    it "creates a UTM link" do
      request.remote_ip = "192.168.1.1"
      cookies[:_gumroad_guid] = "1234567890"

      expect do
        post :create, params: params
      end.to change { seller.utm_links.count }.by(1)

      expect(response).to redirect_to(dashboard_utm_links_path)
      expect(flash[:notice]).to eq("Link created!")

      utm_link = seller.utm_links.last
      expect(utm_link.title).to eq("Test Link")
      expect(utm_link.target_resource_type).to eq("product_page")
      expect(utm_link.target_resource_id).to eq(product.id)
      expect(utm_link.permalink).to eq("abc12345")
      expect(utm_link.utm_source).to eq("facebook")
      expect(utm_link.utm_medium).to eq("social")
      expect(utm_link.utm_campaign).to eq("summer")
      expect(utm_link.ip_address).to eq("192.168.1.1")
      expect(utm_link.browser_guid).to eq("1234567890")
    end

    it "returns an error if the target resource id is missing" do
      params[:utm_link][:target_resource_id] = nil

      expect do
        post :create, params: params
      end.not_to change { UtmLink.count }

      expect(response).to redirect_to(new_dashboard_utm_link_path)
    end

    it "returns an error if the permalink is invalid" do
      params[:utm_link][:permalink] = "abc"

      expect do
        post :create, params: params
      end.not_to change { UtmLink.count }

      expect(response).to redirect_to(new_dashboard_utm_link_path)
    end

    it "returns an error if the UTM source is missing" do
      params[:utm_link][:utm_source] = nil

      expect do
        post :create, params: params
      end.not_to change { UtmLink.count }

      expect(response).to redirect_to(new_dashboard_utm_link_path)
    end

    it "returns error for missing required param" do
      expect do
        post :create, params: {}
      end.to raise_error(ActionController::ParameterMissing, /param is missing or the value is empty: utm_link/)
    end

    it "allows creating a link with same UTM params but different target resource" do
      existing_utm_link = create(:utm_link, seller:, utm_source: "facebook", utm_medium: "social", utm_campaign: "summer", target_resource_type: "profile_page")

      post :create, params: params

      expect(response).to redirect_to(dashboard_utm_links_path)
      expect(UtmLink.count).to eq(2)
      created_utm_link = UtmLink.last
      expect(created_utm_link.utm_source).to eq(existing_utm_link.utm_source)
      expect(created_utm_link.utm_medium).to eq(existing_utm_link.utm_medium)
      expect(created_utm_link.utm_campaign).to eq(existing_utm_link.utm_campaign)
      expect(created_utm_link.utm_content).to eq(existing_utm_link.utm_content)
      expect(created_utm_link.utm_term).to eq(existing_utm_link.utm_term)
      expect([created_utm_link.target_resource_type, created_utm_link.target_resource_id]).to_not eq([existing_utm_link.target_resource_type, existing_utm_link.target_resource_id])
    end

    it "does not allow creating a link with same UTM params and same target resource" do
      create(:utm_link, seller:, utm_source: "facebook", utm_medium: "social", utm_campaign: "summer", target_resource_type: "product_page", target_resource_id: product.id)

      expect do
        post :create, params: params
      end.not_to change { UtmLink.count }

      expect(response).to redirect_to(new_dashboard_utm_link_path)
    end
  end

  describe "PATCH update" do
    let!(:utm_link) { create(:utm_link, seller:, ip_address: "192.168.1.1", browser_guid: "1234567890") }
    let!(:product) { create(:product, user: seller) }
    let(:params) do
      {
        id: utm_link.external_id,
        utm_link: {
          title: "Updated Title",
          target_resource_id: product.external_id,
          target_resource_type: "product_page",
          permalink: "abc12345",
          utm_source: "facebook",
          utm_medium: "social",
          utm_campaign: "summer",
        }
      }
    end

    before do
      controller.instance_variable_set(:@utm_link, utm_link)
    end

    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { utm_link }
      let(:request_params) { { id: utm_link.external_id, utm_link: { title: "Updated Title" } } }
    end

    it "updates only the permitted params of the UTM link" do
      request.remote_ip = "172.0.0.1"
      cookies[:_gumroad_guid] = "9876543210"

      old_permalink = utm_link.permalink

      patch :update, params: params

      expect(response).to redirect_to(dashboard_utm_links_path)
      expect(flash[:notice]).to eq("Link updated!")
      expect(utm_link.reload.title).to eq("Updated Title")
      expect(utm_link.target_resource_id).to be_nil
      expect(utm_link.target_resource_type).to eq("profile_page")
      expect(utm_link.permalink).to eq(old_permalink)
      expect(utm_link.utm_source).to eq("facebook")
      expect(utm_link.utm_medium).to eq("social")
      expect(utm_link.utm_campaign).to eq("summer")
      expect(utm_link.ip_address).to eq("192.168.1.1")
      expect(utm_link.browser_guid).to eq("1234567890")
    end

    it "returns an error if the UTM source is missing" do
      params[:utm_link][:utm_source] = nil

      patch :update, params: params

      expect(response).to redirect_to(edit_dashboard_utm_link_path(utm_link.external_id))
    end

    it "returns an error if the UTM link does not exist" do
      params[:id] = "does-not-exist"
      original_attributes = utm_link.attributes

      expect do
        patch :update, params: params
      end.to raise_error(ActionController::RoutingError)

      expect(utm_link.reload.attributes).to eq(original_attributes)
    end

    it "returns an error if the UTM link does not belong to the seller" do
      utm_link.update!(seller: create(:user))
      original_attributes = utm_link.attributes

      expect do
        patch :update, params: params
      end.to raise_error(ActionController::RoutingError)

      expect(utm_link.reload.attributes).to eq(original_attributes)
    end

    it "redirects to index page" do
      utm_link.mark_deleted!

      expect do
        patch :update, params: params

        expect(response).to be_redirect
        expect(response).to redirect_to(dashboard_utm_links_path)
        expect(flash[:alert]).to eq("Link not found!")
      end.not_to change { utm_link.reload }
    end

    it "returns an error for missing required param" do
      expect do
        patch :update, params: { id: utm_link.external_id, utm_link: {} }
      end.to raise_error(ActionController::ParameterMissing, /param is missing or the value is empty: utm_link/)
    end
  end

  describe "DELETE destroy" do
    let!(:utm_link) { create(:utm_link, seller:) }

    before do
      controller.instance_variable_set(:@utm_link, utm_link)
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { utm_link }
      let(:request_params) { { id: utm_link.external_id } }
    end

    it "soft deletes the UTM link and redirects" do
      expect do
        delete :destroy, params: { id: utm_link.external_id }
      end.to change { utm_link.reload.deleted_at }.from(nil).to(be_within(5.seconds).of(DateTime.current))

      expect(response).to redirect_to(dashboard_utm_links_path)
      expect(flash[:notice]).to eq("Link deleted!")
      expect(utm_link.reload).to be_deleted
    end

    it "preserves query, page, and sort params in redirect when provided" do
      delete :destroy, params: {
        id: utm_link.external_id,
        query: "facebook",
        page: 3,
        key: "date",
        direction: "desc"
      }

      expect(response).to redirect_to(
        dashboard_utm_links_path(
          query: "facebook",
          page: 3,
          key: "date",
          direction: "desc"
        )
      )
    end

    it "returns not found if the UTM link does not exist" do
      original_count = UtmLink.alive.count

      expect do
        delete :destroy, params: { id: "does-not-exist" }
      end.to raise_error(ActionController::RoutingError)

      expect(UtmLink.alive.count).to eq(original_count)
    end

    it "returns not found if the UTM link does not belong to the seller" do
      other_seller = create(:user)
      other_utm_link = create(:utm_link, seller: other_seller)
      original_deleted_at = other_utm_link.deleted_at

      expect do
        delete :destroy, params: { id: other_utm_link.external_id }
      end.to raise_error(ActionController::RoutingError)

      expect(other_utm_link.reload.deleted_at).to eq(original_deleted_at)
    end
  end
end
