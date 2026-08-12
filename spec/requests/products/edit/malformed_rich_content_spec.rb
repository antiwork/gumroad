# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

# End-to-end leg of gumroad-private#2023's display hardening: a stored page
# whose doc the editor schema refuses must degrade to a blocked page with an
# explicit error, never crash the tab or let edits land on the wrong doc. The
# sub-microtask guard windows themselves are pinned by component tests
# (ContentTab/index.test.tsx); this covers the presenter-to-editor seam those
# tests stub.
describe("Product Edit content tab with a malformed stored page", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }

  include_context "with switching account to user as admin for seller"

  it "renders the tab, blocks the malformed page, and keeps the valid page editable" do
    product = create(:product, user: seller)
    create(
      :rich_content,
      entity: product,
      title: "Good page",
      description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Readable content" }] }]
    )
    create(
      :rich_content,
      entity: product,
      title: "Broken page",
      # A text node without text: ProseMirror's nodeFromJSON refuses it.
      description: [{ "type" => "paragraph", "content" => [{ "type" => "text" }] }]
    )

    visit "#{edit_link_path(product.unique_permalink)}/content"

    # The tab renders both entries; the malformed page does not take it down.
    expect(page).to have_selector("[role='tab']", text: "Good page")
    expect(page).to have_selector("[role='tab']", text: "Broken page")
    expect(page).to have_text("Readable content")

    find("[role='tab']", text: "Broken page").click
    expect(page).to have_alert(text: "This page's content could not be displayed. Reload the page before editing it.")

    find("[role='tab']", text: "Good page").click
    expect(page).to have_text("Readable content")
  end
end
