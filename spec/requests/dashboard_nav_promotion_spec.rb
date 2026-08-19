# frozen_string_literal: true

require "spec_helper"

describe PromotesDashboardNavItems, type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user) }

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    sign_in seller
  end

  it "promotes the destination a dashboard page belongs to" do
    get workflows_path

    expect(response).to be_successful
    expect(seller.reload.promoted_nav_item_keys).to include "workflows"
  end

  it "records nothing for a core destination" do
    get dashboard_path

    expect(seller.reload.promoted_nav_item_keys).to eq []
  end

  it "records the promoted key but leaves the row's own policy gate to hide it" do
    seller.promote_nav_item!("community")

    get dashboard_path

    # Promotion is a record of a visit, not a grant. Nav/index.test.tsx covers the render side:
    # a promoted-but-forbidden row appears in neither the top level nor the overflow.
    expect(seller.reload.promoted_nav_item_keys).to include "community"
    expect(Pundit.policy!(SellerContext.new(user: seller, seller:), Community).index?).to be false
  end

  it "seeds what the seller's store already contains on any dashboard page" do
    create(:workflow, seller:)

    get dashboard_path

    expect(seller.reload.promoted_nav_item_keys).to include "workflows"
  end

  it "does not credit a page the request did not successfully render" do
    # A refused page redirects rather than rendering the nav, so it must not count as a visit.
    allow_any_instance_of(WorkflowPolicy).to receive(:index?).and_return(false)

    get workflows_path

    expect(response).not_to be_successful
    expect(seller.reload.promoted_nav_item_keys).not_to include "workflows"
  end

  it "credits the destination a redirect lands on, not the one it left" do
    # /emails bounces to the published tab, which is itself under the emails prefix — the promotion
    # comes from the request that actually rendered, not the one that redirected.
    get emails_path

    expect(response).to be_redirect
    # The redirect seeds (it is still a dashboard request) but promotes nothing, because no page
    # rendered yet.
    expect(seller.reload.promoted_nav_item_keys).to eq []

    # Not follow_redirect!: the host stub rewrites Location to an absolute URL on a host the
    # integration session has no cookies for, so following it lands on /login instead of the page.
    get URI.parse(response.location).path

    expect(response).to be_successful
    expect(seller.reload.promoted_nav_item_keys).to include "emails"
  end

  it "promotes on an Inertia visit, which is how in-app navigation arrives" do
    # Inertia always sets X-Requested-With, so treating every XHR as "not a page render" would make
    # the feature inert exactly when the seller clicks the row that should earn it.
    get workflows_path, headers: { "X-Requested-With" => "XMLHttpRequest", "X-Inertia" => "true" }

    expect(seller.reload.promoted_nav_item_keys).to include "workflows"
  end

  it "ignores an Inertia partial reload, which re-fetches props for a page already on screen" do
    get workflows_path, headers: {
      "X-Requested-With" => "XMLHttpRequest",
      "X-Inertia" => "true",
      "X-Inertia-Partial-Data" => "props",
    }

    expect(seller.reload.dashboard_nav_promotions).to be_empty
  end

  it "ignores an Inertia prefetch, so hovering a row does not promote it" do
    # The sidebar links prefetch on hover, and a prefetch is a real GET carrying X-Inertia.
    get workflows_path, headers: {
      "X-Requested-With" => "XMLHttpRequest",
      "X-Inertia" => "true",
      "Purpose" => "prefetch",
    }

    expect(seller.reload.dashboard_nav_promotions).to be_empty
  end

  it "does not seed a team member from the seller they are switched into" do
    other_seller = create(:user)
    create(:workflow, seller: other_seller)
    create(:team_membership, user: seller, seller: other_seller, role: TeamMembership::ROLE_ADMIN)
    # current_seller comes from an encrypted cookie a request spec cannot set, and POSTing
    # /sellers/switch drops the session, so stub the switched-into state directly. Without it
    # current_seller == logged_in_user and this example never reaches the guard it pins.
    allow_any_instance_of(ApplicationController).to receive(:current_seller).and_return(other_seller)

    get dashboard_path

    # Whatever the switched-into store contains is not something THIS user has used, and the seed
    # must not latch at all — a latch here would freeze the empty result for their own account too.
    expect(seller.reload.dashboard_nav_promotions).to be_empty
  end

  it "ignores requests to paths that do not render the dashboard nav" do
    product = create(:product, user: seller)

    get short_link_path(product.unique_permalink)

    expect(seller.reload.dashboard_nav_promotions).to be_empty
  end

  it "does not seed from the dashboard's JSON stat endpoints" do
    # These live under /dashboard but render no sidebar, and an HTML-format GET to one (a browser
    # hitting the URL directly) passes every header gate — only the path check keeps it out.
    create(:workflow, seller:)

    get dashboard_customers_count_path

    expect(seller.reload.dashboard_nav_promotions).to be_empty
  end

  it "does not promote on a non-GET request" do
    post dashboard_dismiss_getting_started_checklist_path

    expect(seller.reload.dashboard_nav_promotions).to be_empty
  end

  it "keeps serving the page when the promotion write fails" do
    allow_any_instance_of(User).to receive(:promote_nav_item!).and_raise(ActiveRecord::LockWaitTimeout)
    expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::LockWaitTimeout))

    get workflows_path

    expect(response).to be_successful
  end

  it "keeps serving the page when the seed fails" do
    # The seed runs before_action, so an unrescued failure here 500s the page instead of degrading
    # to a nav that has not grown yet.
    allow_any_instance_of(User).to receive(:seed_promoted_nav_items!).and_raise(ActiveRecord::LockWaitTimeout)
    expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::LockWaitTimeout))

    get dashboard_path

    expect(response).to be_successful
  end

  it "records nothing on a request that is not on a Gumroad host" do
    # Seller subdomains and custom domains serve storefronts, where a slugged page can collide with a
    # dashboard path and would otherwise credit the row to a passing buyer.
    #
    # The stub also disables the routing constraint /workflows lives inside, so this lands on the
    # catch-all 404 — which is still an ApplicationController action running the same callbacks.
    # Assert that status: if the 404 ever stops running them, this example would go on passing for
    # the wrong reason rather than pinning the guard.
    allow(GumroadDomainConstraint).to receive(:matches?).and_return(false)

    get workflows_path

    expect(response).to have_http_status(:not_found)
    expect(seller.reload.dashboard_nav_promotions).to be_empty
  end

  it "records nothing for a non-HTML request to a promotable path" do
    get workflows_path, headers: { "Accept" => "application/json" }

    expect(seller.reload.dashboard_nav_promotions).to be_empty
  end
end
