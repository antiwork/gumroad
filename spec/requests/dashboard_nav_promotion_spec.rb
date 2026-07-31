# frozen_string_literal: true

require "spec_helper"

describe DashboardNavPromotion, type: :request do
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
    seller.update!(promoted_nav_items: %w[community])

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

    follow_redirect!

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

    expect(seller.reload.promoted_nav_items).to be_nil
  end

  it "ignores an Inertia prefetch, so hovering a row does not promote it" do
    # The sidebar links prefetch on hover, and a prefetch is a real GET carrying X-Inertia.
    get workflows_path, headers: {
      "X-Requested-With" => "XMLHttpRequest",
      "X-Inertia" => "true",
      "Purpose" => "prefetch",
    }

    expect(seller.reload.promoted_nav_items).to be_nil
  end

  it "does not seed a team member from the seller they are switched into" do
    other_seller = create(:user)
    create(:workflow, seller: other_seller)
    create(:team_membership, user: seller, seller: other_seller, role: TeamMembership::ROLE_ADMIN)

    get dashboard_path

    # Whatever the switched-into store contains is not something THIS user has used.
    expect(seller.reload.promoted_nav_item_keys).not_to include "workflows"
  end

  it "ignores requests to paths that do not render the dashboard nav" do
    product = create(:product, user: seller)

    get short_link_path(product.unique_permalink)

    expect(seller.reload.promoted_nav_items).to be_nil
  end

  it "does not promote on a non-GET request" do
    post dashboard_dismiss_getting_started_checklist_path

    expect(seller.reload.promoted_nav_items).to be_nil
  end

  it "keeps serving the page when the promotion write fails" do
    allow_any_instance_of(User).to receive(:promote_nav_item!).and_raise(ActiveRecord::LockWaitTimeout)
    expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::LockWaitTimeout))

    get workflows_path

    expect(response).to be_successful
  end
end
