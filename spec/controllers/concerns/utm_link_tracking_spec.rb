# frozen_string_literal: true

require "spec_helper"

describe UtmLinkTracking, type: :controller do
  controller(ApplicationController) do
    include UtmLinkTracking

    def action
      head :ok
    end
  end

  let(:seller) { create(:user) }

  before do
    routes.draw { get :action, to: "anonymous#action" }

    cookies[:_gumroad_guid] = "abc123"
    request.remote_ip = "192.168.0.1"

    Feature.activate_user(:utm_links, seller)
  end

  context "when a matching UTM link is found" do
    let!(:utm_link) { create(:utm_link, seller:) }

    before do
      request.host = "#{seller.subdomain}"
      request.path = "/"
    end

    it "records UTM link visit", :sidekiq_inline do
      expect do
        expect do
          get :action, params: { utm_source: utm_link.utm_source, utm_medium: utm_link.utm_medium, utm_campaign: utm_link.utm_campaign, utm_content: utm_link.utm_content, utm_term: utm_link.utm_term }
        end.to change(UtmLinkVisit, :count).by(1)
      end.not_to change(UtmLink, :count)
      expect(utm_link.reload.total_clicks).to eq(1)
      expect(utm_link.unique_clicks).to eq(1)
      visit = utm_link.utm_link_visits.last
      expect(visit.browser_guid).to eq("abc123")
      expect(visit.ip_address).to eq("192.168.0.1")
      expect(visit.country_code).to be_nil
      expect(visit.referrer).to be_nil
      expect(visit.user_agent).to eq("Rails Testing")

      # Visit from the same browser is recorded but not counted as a unique one
      expect do
        get :action, params: { utm_source: utm_link.utm_source, utm_medium: utm_link.utm_medium, utm_campaign: utm_link.utm_campaign, utm_content: utm_link.utm_content, utm_term: utm_link.utm_term }
      end.to change(UtmLinkVisit, :count).from(1).to(2)
      expect(utm_link.reload.total_clicks).to eq(2)
      expect(utm_link.unique_clicks).to eq(1)

      # When the UTM params don't match, no visit is recorded
      expect do
        get :action, params: { utm_source: utm_link.utm_source, utm_medium: utm_link.utm_medium }
      end.not_to change(UtmLinkVisit, :count)
      expect(utm_link.reload.total_clicks).to eq(2)
      expect(utm_link.unique_clicks).to eq(1)
    end

    it "enqueues a job to update the UTM link stats" do
      get :action, params: { utm_source: utm_link.utm_source, utm_medium: utm_link.utm_medium, utm_campaign: utm_link.utm_campaign, utm_content: utm_link.utm_content, utm_term: utm_link.utm_term }

      expect(UpdateUtmLinkStatsJob).to have_enqueued_sidekiq_job(utm_link.id)
    end

    it "does nothing for non-GET requests" do
      expect do
        post :action, params: { utm_source: utm_link.utm_source, utm_medium: utm_link.utm_medium, utm_campaign: utm_link.utm_campaign, utm_content: utm_link.utm_content, utm_term: utm_link.utm_term }
      end.not_to change(UtmLinkVisit, :count)

      expect(UpdateUtmLinkStatsJob).not_to have_enqueued_sidekiq_job(utm_link.id)
    end

    it "does not track UTM link visits when cookies are disabled" do
      cookies[:_gumroad_guid] = nil

      expect do
        get :action, params: { utm_source: utm_link.utm_source, utm_medium: utm_link.utm_medium, utm_campaign: utm_link.utm_campaign, utm_content: utm_link.utm_content, utm_term: utm_link.utm_term }
      end.not_to change(UtmLinkVisit, :count)

      expect(response).to be_successful
      expect(UpdateUtmLinkStatsJob).not_to have_enqueued_sidekiq_job(utm_link.id)
    end
  end

  context "when a matching UTM link exists but the seller has disabled it" do
    let(:product) { create(:product, user: seller) }
    let!(:utm_link) do
      create(:utm_link, seller:, target_resource_type: "product_page", target_resource_id: product.id, disabled_at: 1.day.ago)
    end
    let(:utm_params) do
      {
        utm_source: utm_link.utm_source,
        utm_medium: utm_link.utm_medium,
        utm_campaign: utm_link.utm_campaign,
        utm_content: utm_link.utm_content,
        utm_term: utm_link.utm_term
      }
    end

    before do
      allow(controller).to receive(:short_link_path).and_return("/l/#{product.unique_permalink}")
      request.host = "#{seller.subdomain}"
      request.path = "/l/#{product.unique_permalink}"
    end

    it "renders the page successfully without creating a duplicate link or tracking a visit" do
      expect do
        expect do
          get :action, params: utm_params.merge(id: product.unique_permalink)
        end.not_to change(UtmLink, :count)
      end.not_to change(UtmLinkVisit, :count)

      expect(response).to be_successful
      expect(UpdateUtmLinkStatsJob).not_to have_enqueued_sidekiq_job(utm_link.id)
    end
  end

  context "when a matching UTM link exists but is soft-deleted" do
    let(:product) { create(:product, user: seller) }
    let!(:utm_link) do
      create(:utm_link, seller:, target_resource_type: "product_page", target_resource_id: product.id, deleted_at: 1.day.ago)
    end
    let(:utm_params) do
      {
        utm_source: utm_link.utm_source,
        utm_medium: utm_link.utm_medium,
        utm_campaign: utm_link.utm_campaign,
        utm_content: utm_link.utm_content,
        utm_term: utm_link.utm_term
      }
    end

    before do
      allow(controller).to receive(:short_link_path).and_return("/l/#{product.unique_permalink}")
      request.host = "#{seller.subdomain}"
      request.path = "/l/#{product.unique_permalink}"
    end

    it "auto-creates a fresh UTM link and records the visit" do
      expect do
        expect do
          get :action, params: utm_params.merge(id: product.unique_permalink)
        end.to change(UtmLink.alive, :count).by(1)
      end.to change(UtmLinkVisit, :count).by(1)

      expect(response).to be_successful
      expect(UtmLink.alive.last.id).not_to eq(utm_link.id)
    end
  end

  context "when tracking raises unexpectedly" do
    let!(:utm_link) { create(:utm_link, seller:) }
    let(:utm_params) do
      {
        utm_source: utm_link.utm_source,
        utm_medium: utm_link.utm_medium,
        utm_campaign: utm_link.utm_campaign,
        utm_content: utm_link.utm_content,
        utm_term: utm_link.utm_term
      }
    end

    before do
      request.host = "#{seller.subdomain}"
      request.path = "/"
    end

    it "reports the error and still renders the page when a record is invalid" do
      allow_any_instance_of(UtmLink).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::RecordInvalid), anything)

      get :action, params: utm_params

      expect(response).to be_successful
    end

    it "reports the error and still renders the page when the database uniqueness index is hit repeatedly" do
      allow_any_instance_of(UtmLink).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::RecordNotUnique), anything)

      get :action, params: utm_params

      expect(response).to be_successful
    end
  end

  context "when two simultaneous first visits race to auto-create the same UTM link" do
    let(:utm_params) do
      {
        utm_source: "facebook",
        utm_medium: "social",
        utm_campaign: "summer_sale"
      }
    end

    before do
      allow(controller).to receive(:root_path).and_return("/")
      request.host = "#{seller.subdomain}"
      request.path = "/"
    end

    it "retries once, recovers, and records the visit without reporting an error", :sidekiq_inline do
      # Simulate losing the race: the first attempt to insert the auto-created link raises
      # RecordNotUnique (in production this happens when a concurrent request inserted the
      # same link between our find_or_initialize_by and our insert). The retry re-runs the
      # lookup and must succeed without surfacing an error.
      original_save = UtmLink.instance_method(:save!)
      raised_once = false
      allow_any_instance_of(UtmLink).to receive(:save!) do |instance, *args|
        if instance.new_record? && !raised_once
          raised_once = true
          raise ActiveRecord::RecordNotUnique
        end
        original_save.bind_call(instance, *args)
      end

      expect(ErrorNotifier).not_to receive(:notify)

      expect do
        get :action, params: utm_params
      end.to change(UtmLinkVisit, :count).by(1)

      expect(response).to be_successful
      utm_link = UtmLink.alive.find_by!(utm_source: "facebook", utm_medium: "social", utm_campaign: "summer_sale")
      expect(utm_link.total_clicks).to eq(1)
      expect(utm_link.utm_link_visits.count).to eq(1)
    end

    it "retries once and recovers when the loser fails on the uniqueness validation instead of the database index", :sidekiq_inline do
      # The other timing of the same race: the winning request commits BEFORE the losing
      # request's uniqueness validation query runs, so the loser fails model validation
      # (RecordInvalid) rather than the database's unique index (RecordNotUnique). This is
      # the "A link with similar UTM parameters already exists" error seen in production.
      # The retry re-runs the lookup, finds the winner's link, and must record the visit
      # without surfacing an error.
      original_save = UtmLink.instance_method(:save!)
      raised_once = false
      allow_any_instance_of(UtmLink).to receive(:save!) do |instance, *args|
        if instance.new_record? && !raised_once
          raised_once = true
          # Simulate the concurrent request having committed the same link already, which is
          # what makes the uniqueness validation fail for this (losing) request.
          create(:utm_link, seller:, utm_source: "facebook", utm_medium: "social", utm_campaign: "summer_sale",
                            utm_term: nil, utm_content: nil,
                            target_resource_type: UtmLink.target_resource_types[:profile_page], target_resource_id: nil)
          instance.errors.add(:target_resource_id, "A link with similar UTM parameters already exists for this destination!")
          raise ActiveRecord::RecordInvalid.new(instance)
        end
        original_save.bind_call(instance, *args)
      end

      expect(ErrorNotifier).not_to receive(:notify)

      expect do
        get :action, params: utm_params
      end.to change(UtmLinkVisit, :count).by(1)

      expect(response).to be_successful
      utm_link = UtmLink.alive.find_by!(utm_source: "facebook", utm_medium: "social", utm_campaign: "summer_sale")
      expect(utm_link.total_clicks).to eq(1)
      expect(utm_link.utm_link_visits.count).to eq(1)
    end

    it "reports the error after a single retry when the auto-created link stays invalid" do
      # If the validation failure isn't a transient race (it repeats on the retry), we must
      # not loop — report once and let the page render. Counting save attempts is what makes
      # this spec fail if the retry is removed (old code: 1 attempt) or unbounded (hang): the
      # fixed code makes exactly 2 attempts — the original save plus one retry.
      save_attempts = 0
      allow_any_instance_of(UtmLink).to receive(:save!) do |instance, *args|
        save_attempts += 1
        instance.errors.add(:target_resource_id, "A link with similar UTM parameters already exists for this destination!")
        raise ActiveRecord::RecordInvalid.new(instance)
      end
      expect(ErrorNotifier).to receive(:notify).once.with(instance_of(ActiveRecord::RecordInvalid), anything)

      expect do
        get :action, params: utm_params
      end.not_to change(UtmLinkVisit, :count)

      expect(save_attempts).to eq(2)
      expect(response).to be_successful
    end
  end

  context "when a matching UTM link is not found" do
    let(:product) { create(:product, user: seller) }
    let(:post) { create(:published_installment, seller:, shown_on_profile: true) }
    let(:utm_params) do
      {
        utm_source: "facebook",
        utm_medium: "social",
        utm_campaign: "summer_sale",
        utm_content: "Banner 1",
        utm_term: "discount"
      }
    end

    before do
      Feature.activate_user(:utm_links, seller)
      request.host = "#{seller.subdomain}"
    end

    context "on a product page" do
      before do
        allow(controller).to receive(:short_link_path).and_return("/l/#{product.unique_permalink}")
        request.path = "/l/#{product.unique_permalink}"
      end

      it "creates a new UTM link and records the visit", :sidekiq_inline do
        expect do
          get :action, params: utm_params.merge(id: product.unique_permalink)
        end.to change(UtmLink, :count).by(1)
          .and change(UtmLinkVisit, :count).by(1)

        utm_link = UtmLink.last
        expect(utm_link.seller).to eq(seller)
        expect(utm_link.title).to eq("Product — #{product.name} (auto-generated)")
        expect(utm_link.target_resource_type).to eq("product_page")
        expect(utm_link.target_resource_id).to eq(product.id)
        expect(utm_link.utm_source).to eq("facebook")
        expect(utm_link.utm_medium).to eq("social")
        expect(utm_link.utm_campaign).to eq("summer_sale")
        expect(utm_link.utm_content).to eq("banner-1")
        expect(utm_link.utm_term).to eq("discount")
        expect(utm_link.ip_address).to eq("192.168.0.1")
        expect(utm_link.browser_guid).to eq("abc123")
        expect(utm_link.first_click_at).to be_present
        expect(utm_link.last_click_at).to be_present
        expect(utm_link.total_clicks).to eq(1)
        expect(utm_link.unique_clicks).to eq(1)

        visit = utm_link.utm_link_visits.last
        expect(visit.browser_guid).to eq("abc123")
        expect(visit.ip_address).to eq("192.168.0.1")
        expect(visit.country_code).to be_nil
        expect(visit.referrer).to be_nil
        expect(visit.user_agent).to eq("Rails Testing")

        # Another visit from the same browser does not create a new UTM link, but does record a visit
        expect do
          get :action, params: utm_params.merge(id: product.unique_permalink)
        end.to change(UtmLink, :count).by(0)
          .and change(UtmLinkVisit, :count).by(1)

        expect(utm_link.reload.total_clicks).to eq(2)
        expect(utm_link.unique_clicks).to eq(1)
      end
    end

    context "on a post page" do
      before do
        allow(controller).to receive(:custom_domain_view_post_path).and_return("/posts/#{post.slug}")
        request.host = "#{seller.subdomain}"
        request.path = "/posts/#{post.slug}"
      end

      it "creates a new UTM link and records the visit", :sidekiq_inline do
        expect do
          get :action, params: utm_params.merge(slug: post.slug)
        end.to change(UtmLink, :count).by(1)
          .and change(UtmLinkVisit, :count).by(1)

        utm_link = UtmLink.last
        expect(utm_link.seller).to eq(seller)
        expect(utm_link.title).to eq("Post — #{post.name} (auto-generated)")
        expect(utm_link.target_resource_type).to eq("post_page")
        expect(utm_link.target_resource_id).to eq(post.id)
        expect(utm_link.utm_source).to eq("facebook")
        expect(utm_link.utm_medium).to eq("social")
        expect(utm_link.utm_campaign).to eq("summer_sale")
        expect(utm_link.utm_content).to eq("banner-1")
        expect(utm_link.utm_term).to eq("discount")
        expect(utm_link.ip_address).to eq("192.168.0.1")
        expect(utm_link.browser_guid).to eq("abc123")
        expect(utm_link.first_click_at).to be_present
        expect(utm_link.last_click_at).to be_present
        expect(utm_link.total_clicks).to eq(1)
        expect(utm_link.unique_clicks).to eq(1)

        visit = utm_link.utm_link_visits.last
        expect(visit.browser_guid).to eq("abc123")
        expect(visit.ip_address).to eq("192.168.0.1")
        expect(visit.country_code).to be_nil
        expect(visit.referrer).to be_nil
        expect(visit.user_agent).to eq("Rails Testing")

        # Another visit from the same browser does not create a new UTM link, but does record a visit
        expect do
          get :action, params: utm_params.merge(slug: post.slug)
        end.to change(UtmLink, :count).by(0)
          .and change(UtmLinkVisit, :count).by(1)

        expect(utm_link.reload.total_clicks).to eq(2)
        expect(utm_link.unique_clicks).to eq(1)
      end
    end

    context "on the profile page" do
      before do
        allow(controller).to receive(:root_path).and_return("/")
        request.host = "#{seller.subdomain}"
        request.path = "/"
      end

      it "creates a new UTM link and records the visit", :sidekiq_inline do
        expect do
          get :action, params: utm_params
        end.to change(UtmLink, :count).by(1)
          .and change(UtmLinkVisit, :count).by(1)

        utm_link = UtmLink.last
        expect(utm_link.seller).to eq(seller)
        expect(utm_link.target_resource_type).to eq("profile_page")
        expect(utm_link.target_resource_id).to be_nil
        expect(utm_link.title).to eq("Profile page (auto-generated)")
        expect(utm_link.utm_source).to eq("facebook")
        expect(utm_link.utm_medium).to eq("social")
        expect(utm_link.utm_campaign).to eq("summer_sale")
        expect(utm_link.utm_content).to eq("banner-1")
        expect(utm_link.utm_term).to eq("discount")
        expect(utm_link.ip_address).to eq("192.168.0.1")
        expect(utm_link.browser_guid).to eq("abc123")
        expect(utm_link.first_click_at).to be_present
        expect(utm_link.last_click_at).to be_present
        expect(utm_link.total_clicks).to eq(1)
        expect(utm_link.unique_clicks).to eq(1)

        visit = utm_link.utm_link_visits.last
        expect(visit.browser_guid).to eq("abc123")
        expect(visit.ip_address).to eq("192.168.0.1")
        expect(visit.country_code).to be_nil
        expect(visit.referrer).to be_nil
        expect(visit.user_agent).to eq("Rails Testing")

        # Another visit from the same browser does not create a new UTM link, but does record a visit
        expect do
          get :action, params: utm_params
        end.to change(UtmLink, :count).by(0)
          .and change(UtmLinkVisit, :count).by(1)
      end
    end

    context "on the subscribe page" do
      before do
        allow(controller).to receive(:custom_domain_subscribe_path).and_return("/subscribe")
        request.host = "#{seller.subdomain}"
        request.path = "/subscribe"
      end

      it "creates a new UTM link and records the visit", :sidekiq_inline do
        expect do
          get :action, params: utm_params
        end.to change(UtmLink, :count).by(1)
          .and change(UtmLinkVisit, :count).by(1)

        utm_link = UtmLink.last
        expect(utm_link.seller).to eq(seller)
        expect(utm_link.target_resource_type).to eq("subscribe_page")
        expect(utm_link.target_resource_id).to be_nil
        expect(utm_link.title).to eq("Subscribe page (auto-generated)")
        expect(utm_link.utm_source).to eq("facebook")
        expect(utm_link.utm_medium).to eq("social")
        expect(utm_link.utm_campaign).to eq("summer_sale")
        expect(utm_link.utm_content).to eq("banner-1")
        expect(utm_link.utm_term).to eq("discount")
        expect(utm_link.ip_address).to eq("192.168.0.1")
        expect(utm_link.browser_guid).to eq("abc123")
        expect(utm_link.first_click_at).to be_present
        expect(utm_link.last_click_at).to be_present
        expect(utm_link.total_clicks).to eq(1)
        expect(utm_link.unique_clicks).to eq(1)

        visit = utm_link.utm_link_visits.last
        expect(visit.browser_guid).to eq("abc123")
        expect(visit.ip_address).to eq("192.168.0.1")
        expect(visit.country_code).to be_nil
        expect(visit.referrer).to be_nil
        expect(visit.user_agent).to eq("Rails Testing")

        # Another visit from the same browser does not create a new UTM link, but does record a visit
        expect do
          get :action, params: utm_params
        end.to change(UtmLink, :count).by(0)
          .and change(UtmLinkVisit, :count).by(1)
      end
    end

    it "truncates UTM params that exceed the maximum length", :sidekiq_inline do
      long_source = "a" * 300
      request.host = "#{seller.subdomain}"
      request.path = "/"
      allow(controller).to receive(:root_path).and_return("/")

      expect do
        get :action, params: utm_params.merge(utm_source: long_source)
      end.to change(UtmLink, :count).by(1)

      utm_link = UtmLink.last
      expect(utm_link.utm_source.length).to eq(UtmLink::MAX_UTM_PARAM_LENGTH)
    end

    it "does not auto-create UTM link when feature is disabled" do
      Feature.deactivate_user(:utm_links, seller)
      request.host = "#{seller.subdomain}"
      request.path = "/"

      expect do
        expect do
          get :action, params: utm_params
        end.not_to change(UtmLink, :count)
      end.not_to change(UtmLinkVisit, :count)
    end

    it "does not auto-create UTM link when cookies are disabled" do
      cookies[:_gumroad_guid] = nil
      request.host = "#{seller.subdomain}"
      request.path = "/"

      expect do
        expect do
          get :action, params: utm_params
        end.not_to change(UtmLink, :count)
      end.not_to change(UtmLinkVisit, :count)
    end
  end
end
