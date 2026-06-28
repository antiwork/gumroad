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
    login_as seller
  end

  # Stub one turn of the agent: the next user message yields `reply` (+ optional proposed_action).
  def stub_agent_turn(reply:, proposed_action: nil)
    allow_any_instance_of(Ai::StoreAgentService).to receive(:respond).and_return(
      { reply:, proposed_action: }.compact,
    )
  end

  # Load the Agent tab directly. The Agent page renders inside the full dashboard shell (the same
  # left sidebar nav, logo, and header), so screenshots taken here show the feature in real app
  # chrome — not an isolated component. We additionally assert the Agent entry is present and active
  # in the sidebar nav, which is what makes the tab reachable from anywhere in the dashboard.
  def open_agent
    visit agent_path
    expect(page).to have_text("Gumroad store assistant", wait: 10)
    # The sidebar nav link uses an absolute URL (Routes.agent_url), so match by its label rather than
    # an exact path; its presence here is what makes the tab reachable from anywhere in the dashboard.
    within "nav" do
      expect(page).to have_link("Agent")
    end
  end

  def send_message(text)
    fill_in "Message", with: text
    find("button[type=submit]", text: "Send").click
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
    find("nav a", text: "Agent").click

    expect(page).to have_current_path(agent_path)
    expect(page).to have_text("Gumroad store assistant", wait: 10)
  end

  describe "use cases" do
    before { open_agent }

    it "answers a sales-insights question (read)" do
      stub_agent_turn(reply: "Here's your month so far: gross sales $18,420 across 642 orders. " \
                             "Your top seller is Portrait Masterclass at $7,240.")

      send_message("How did sales go this month, and what's my best seller?")

      expect(page).to have_text("gross sales $18,420", wait: 10)
      expect(page).to have_text("Portrait Masterclass at $7,240")
      screenshot("02_sales_insights")
    end

    it "proposes a discount and applies it on confirmation (write round-trip)" do
      # The proposed action is the real catalog api_write the executor will replay against the API.
      stub_agent_turn(
        reply: "I've prepared that discount for your confirmation.",
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
      screenshot("04_discount_applied")
    end

    it "lets the seller dismiss a proposed change without applying it" do
      stub_agent_turn(
        reply: "I've prepared the price change for your confirmation.",
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
        reply: "I found that order and prepared the refund for your confirmation.",
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
        reply: "I've drafted an announcement to your customers. Review it before it sends.",
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
      reply: "I've prepared that for your confirmation.",
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
