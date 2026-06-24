# frozen_string_literal: true

require "spec_helper"

describe User, "custom_html" do
  let(:seller) { create(:user) }

  it "builds a polymorphic page on first assignment" do
    expect do
      seller.custom_html = "<section>Hello</section>"
      seller.save!
    end.to change { Page.where(pageable: seller).count }.from(0).to(1)

    expect(seller.reload.custom_html).to eq("<section>Hello</section>")
  end

  it "sanitizes the HTML through the page before-save safety net" do
    seller.custom_html = %(<section><script src="https://evil.com/x.js"></script><h1>Hi</h1></section>)
    seller.save!

    expect(seller.reload.custom_html).not_to include("evil.com")
    expect(seller.custom_html).to include("<h1>Hi</h1>")
  end

  it "clears the stored HTML when assigned a blank value" do
    seller.update!(custom_html: "<section>Hello</section>")

    seller.custom_html = ""
    seller.save!

    expect(seller.reload.custom_html).to be_nil
  end

  it "is a no-op when assigned blank with no existing page (no empty row created)" do
    expect do
      seller.custom_html = nil
      seller.save!
    end.not_to change { Page.where(pageable: seller).count }
  end

  it "reflects in has_custom_landing_page?" do
    expect(seller.has_custom_landing_page?).to eq(false)

    seller.update!(custom_html: "<section>Hello</section>")

    expect(seller.has_custom_landing_page?).to eq(true)
  end

  it "destroys the associated page when the user is destroyed" do
    seller.update!(custom_html: "<section>Hello</section>")
    page_id = seller.page.id

    seller.destroy!

    expect(Page.where(id: page_id)).not_to exist
  end
end
