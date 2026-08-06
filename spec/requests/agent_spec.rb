# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

# End-to-end coverage of the conversational store Agent tab, exercised through the real dashboard:
# we log in, navigate to the Agent via the sidebar nav link (proving the tab is wired into the app
# shell), then walk the marketing use cases — sales insights, creating a discount, refunding a sale,
# emailing customers — driving the real React component, the proposed-change confirmation card, and
# the confirm round-trip.
#
# The model itself is non-deterministic and costs a network call, so we stub Ai::StoreAgentService
# (the OpenAI tool-calling loop, unit-tested separately) to return scripted replies / proposed
# actions. Everything below that — the controller, the confirmation UX, and the actual mutation via
# Ai::StoreAgentActionExecutor replaying the real v2 API — runs for real.
#
# Each use case also saves a screenshot to tmp/agent_screenshots for marketing collateral; the shots
# show the agent in the real app chrome (sidebar, nav, header), not an isolated component.
describe "Agent tab", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller, name: "Portrait Masterclass", price_cents: 4900) }

  let(:screenshot_dir) { Rails.root.join("tmp", "agent_screenshots") }

  before do
    FileUtils.mkdir_p(screenshot_dir)
    # The Agent tab is gated on User#eligible_for_store_agent? ($100 in sales + a completed
    # payout). These specs exercise the Agent UX, not the eligibility bar, which is covered
    # in spec/models/user_spec.rb and spec/policies/user_policy_spec.rb.
    allow_any_instance_of(User).to receive(:eligible_for_store_agent?).and_return(true)
    login_as seller
  end

  # Stub one turn of the agent: the next user message yields `reply` (+ optional proposed_action /
  # objects rendered inline as cards, and follow-up `suggestions`). The Agent tab streams its reply
  # over Server-Sent Events, so we stub the streaming entrypoint (respond_streaming): it emits the
  # reply as a single token, persists the completed turn, then emits objects / proposed action /
  # suggestions and returns the same hash shape the controller's `done` event uses.
  def stub_agent_turn(reply:, proposed_action: nil, objects: [], suggestions: [])
    allow_any_instance_of(Ai::StoreAgentService).to receive(:respond_streaming) do |_service, **kwargs, &emit|
      emit.call(:token, { text: reply })
      outcome = proposed_action ? Ai::StoreAgentService::TURN_OUTCOME_PROPOSAL_READY : Ai::StoreAgentService::TURN_OUTCOME_REPLY_ONLY
      turn = { outcome:, reply:, proposed_action:, objects:, suggestions: }
      # Production finish_stream persists before every trailing event. That ordering lets the
      # controller bind a proposal event to its stored assistant message and suppress it when
      # persistence fails.
      kwargs[:on_reply_complete]&.call(turn)
      emit.call(:objects, { objects: }) if objects.any?
      emit.call(:proposed_action, { proposed_action: }) if proposed_action
      emit.call(:suggestions, { suggestions: }) if suggestions.any?
      turn
    end
  end

  # Load the Agent tab directly. The Agent page renders inside the full dashboard shell (the same
  # left sidebar nav, logo, and header), so screenshots taken here show the feature in real app
  # chrome — not an isolated component. We additionally assert the Agent entry is present and active
  # in the sidebar nav, which is what makes the tab reachable from anywhere in the dashboard.
  def open_agent
    visit agent_path
    expect(page).to have_text(AgentPresenter::GREETING, wait: 10)
    # The sidebar nav link uses an absolute URL (Routes.agent_url), so match by its label rather than
    # an exact path; its presence here is what makes the tab reachable from anywhere in the dashboard.
    within "nav" do
      expect(page).to have_link("Agent")
    end
  end

  def send_message(text)
    fill_in "Message", with: text
    # The composer's Send control is an icon-only submit button (aria-label "Send",
    # no visible text), so match it by submit type + accessible name, not visible text.
    find("button[type=submit][aria-label='Send']").click
  end

  def screenshot(name)
    page.save_screenshot(screenshot_dir.join("#{name}.png").to_s)
  end

  it "renders inside the dashboard shell with the Agent entry active in the sidebar nav" do
    open_agent

    # The greeting + suggestion chips are visible, and the Agent nav link is present in the sidebar.
    expect(page).to have_text("How are my sales doing?")
    expect(page).to have_button("List my products")
    within "nav" do
      expect(page).to have_link("Agent")
    end
    screenshot("01_empty_state_in_app")
  end

  it "is reachable by clicking the Agent link from the dashboard home" do
    # The dashboard home reads follower stats from Elasticsearch; make sure that test index exists so
    # the page boots, then click through to the Agent tab the way a seller would.
    ConfirmedFollowerEvent.__elasticsearch__.create_index!(force: true)

    visit dashboard_path
    # Agent starts under "Everything else" until the seller uses it (DashboardNav).
    within("nav[aria-label='Main']") { click_on "Everything else" }
    find("nav a", text: "Agent").click

    expect(page).to have_current_path(agent_path)
    expect(page).to have_text(AgentPresenter::GREETING, wait: 10)
  end

  context "when the seller has not earned agent access yet" do
    before { allow_any_instance_of(User).to receive(:eligible_for_store_agent?).and_return(false) }

    it "keeps the tab, states the bar, and leaves the seller nothing to interact with" do
      visit agent_path

      # Still the Agent page, not a bounce to /dashboard with the generic authorization alert.
      expect(page).to have_current_path(agent_path)
      expect(page).to have_text(AgentPresenter::LOCKED_HEADING, wait: 10)
      expect(page).to have_text(AgentPresenter::LOCKED_EXPLANATION)
      expect(page).to_not have_text("You are not allowed to perform this action")

      # The nav entry stays, so the tab does not silently vanish from under them.
      within "nav" do
        expect(page).to have_link("Agent")
      end

      # The badge itself renders on the row (gumroad-private#1773). It's pinned here rather than
      # under "Everything else" because we're currently viewing /agent — the nav pins whatever page
      # is open regardless of promotion state.
      within "nav[aria-label='Main']" do
        expect(page).to have_text(AgentPresenter::LOCKED_NAV_BADGE)
      end
      screenshot("09_locked_nav_badge")

      # Composer and starter chips are inert: nothing here can reach an endpoint that would 401.
      expect(find_field("Message", disabled: true)).to be_present
      expect(find("button[type=submit][aria-label='Send']", visible: :all)).to be_disabled
      expect(page).to_not have_button("List my products")
    end
  end

  describe "use cases" do
    before { open_agent }

    it "answers a sales-insights question (read)" do
      stub_agent_turn(reply: "Here's your month so far: gross sales $18,420 across 642 orders. " \
                             "Your top seller is Portrait Masterclass at $7,240.",
                      suggestions: ["Show my best sellers this month", "Email my customers about it"])

      send_message("How did sales go this month, and what's my best seller?")

      expect(page).to have_text("gross sales $18,420", wait: 10)
      expect(page).to have_text("Portrait Masterclass at $7,240")
      # The turn ends with one-tap follow-up prompts to keep the conversation going.
      expect(page).to have_button("Show my best sellers this month")
      expect(page).to have_button("Email my customers about it")
      screenshot("02_sales_insights")
    end

    it "continues the conversation when a follow-up suggestion is clicked" do
      stub_agent_turn(reply: "Your three best sellers this month are Portrait Masterclass, " \
                             "Lightroom Pack, and Brush Set.",
                      suggestions: ["Show my best sellers this month"])
      send_message("How are sales?")
      expect(page).to have_button("Show my best sellers this month", wait: 10)

      # Clicking a follow-up sends it as the next message, so the chat keeps going hands-free.
      stub_agent_turn(reply: "Portrait Masterclass leads with 128 sales at $49 each.")
      click_on "Show my best sellers this month"
      expect(page).to have_text("Portrait Masterclass leads with 128 sales", wait: 10)
    end

    it "proposes a discount and applies it on confirmation (write round-trip)" do
      # The proposed action is the real catalog api_write the executor will replay against the API.
      stub_agent_turn(
        reply: Ai::StoreAgentService::PROPOSAL_READY_REPLY,
        proposed_action: {
          type: "api_write",
          params: {
            "endpoint" => "create_offer_code",
            "path_params" => { "link_id" => product.external_id },
            "params" => { "name" => "LAUNCH25", "amount_off" => 25, "offer_type" => "percent" },
          },
          summary: "Create discount code LAUNCH25 on \"Portrait Masterclass\" — 25% off.",
        },
      )

      send_message("Run a 25% launch discount on the Portrait Masterclass called LAUNCH25")

      expect(page).to have_text("Proposed change", wait: 10)
      expect(page).to have_text("Create discount code LAUNCH25")
      screenshot("03_discount_proposed")

      expect do
        click_on "Confirm"
        # The confirmation card collapses to an "Applied" status once the executor succeeds.
        expect(page).to have_text("Applied", wait: 10)
      end.to change { product.reload.offer_codes.alive.count }.by(1)

      offer_code = product.offer_codes.alive.last
      expect(offer_code.code).to eq("LAUNCH25")
      expect(offer_code.amount_percentage).to eq(25)

      # The created discount renders inline as an object card with a copy affordance.
      expect(page).to have_text("LAUNCH25", wait: 10)
      expect(page).to have_button("Copy LAUNCH25")
      screenshot("04_discount_applied")
    end

    it "renders looked-up products inline as object cards with copy and open links" do
      product.update!(name: "Portrait Masterclass")
      stub_agent_turn(
        reply: "Here are your products.",
        objects: [
          {
            type: "product",
            title: "Portrait Masterclass",
            subtitle: "$49",
            fields: [{ label: "Status", value: "Published" }, { label: "Sales", value: "128" }],
            url: "https://seller.gumroad.com/l/portrait",
            copy: "https://seller.gumroad.com/l/portrait",
          },
        ],
      )

      send_message("List my products")

      expect(page).to have_text("Portrait Masterclass", wait: 10)
      expect(page).to have_text("$49")
      expect(page).to have_text("Sales")
      # Copy + open-in-new-tab affordances beneath the object.
      expect(page).to have_button("Copy Portrait Masterclass")
      open_link = find("a[aria-label='Open Portrait Masterclass in a new tab']")
      expect(open_link[:href]).to eq("https://seller.gumroad.com/l/portrait")
      expect(open_link[:target]).to eq("_blank")
      screenshot("08_product_cards")
    end

    it "lets the seller dismiss a proposed change without applying it" do
      stub_agent_turn(
        reply: Ai::StoreAgentService::PROPOSAL_READY_REPLY,
        proposed_action: {
          type: "api_write",
          params: {
            "endpoint" => "update_product",
            "path_params" => { "id" => product.external_id },
            "params" => { "price" => 3900 },
          },
          summary: "Update \"Portrait Masterclass\" — set price to $39.00.",
        },
      )

      send_message("Drop the Portrait Masterclass to $39")

      expect(page).to have_text("Proposed change", wait: 10)
      expect do
        click_on "Dismiss"
        expect(page).to have_text("Dismissed", wait: 10)
      end.not_to change { product.reload.price_cents }
      screenshot("05_change_dismissed")
    end

    it "proposes refunding a sale (sensitive write gated by confirmation)" do
      stub_agent_turn(
        reply: Ai::StoreAgentService::PROPOSAL_READY_REPLY,
        proposed_action: {
          type: "api_write",
          params: {
            "endpoint" => "refund_sale",
            "path_params" => { "id" => "sale_abc123" },
            "params" => { "amount_cents" => 8900 },
          },
          summary: "Refund sale #GR-88142 — full refund of $89.00.",
        },
      )

      send_message("Refund order #GR-88142")

      expect(page).to have_text("Proposed change", wait: 10)
      expect(page).to have_text("Refund sale #GR-88142")
      expect(page).to have_button("Confirm")
      screenshot("06_refund_proposed")
    end

    it "proposes an email campaign to customers" do
      stub_agent_turn(
        reply: Ai::StoreAgentService::PROPOSAL_READY_REPLY,
        proposed_action: {
          type: "api_write",
          params: {
            "endpoint" => "create_email",
            "path_params" => {},
            "params" => { "subject" => "Your Lightroom Pack just got a free v3 update", "audience_type" => "product" },
          },
          summary: "Send email \"Your Lightroom Pack just got a free v3 update\" to customers of \"Portrait Masterclass\".",
        },
      )

      send_message("Email everyone who bought the masterclass about the v3 update")

      expect(page).to have_text("Proposed change", wait: 10)
      expect(page).to have_text("Send email")
      screenshot("07_email_campaign")
    end
  end

  it "surfaces a friendly error if a change can't be applied" do
    open_agent
    stub_agent_turn(
      reply: Ai::StoreAgentService::PROPOSAL_READY_REPLY,
      proposed_action: {
        type: "api_write",
        # A blank required path param makes the executor fail cleanly (no mutation, friendly message).
        params: { "endpoint" => "update_product", "path_params" => {}, "params" => { "price" => 1000 } },
        summary: "Update a product's price.",
      },
    )

    send_message("change a price")
    expect(page).to have_text("Proposed change", wait: 10)
    click_on "Confirm"
    # Alert surfaces the executor's failure message; the card does NOT flip to Applied.
    expect(page).to have_selector("[role=alert]", wait: 10)
    expect(page).not_to have_text("Applied")
  end
end
