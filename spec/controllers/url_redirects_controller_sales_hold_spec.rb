# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe UrlRedirectsController, "for a listing on a sales hold", inertia: true do
  render_views

  let(:seller) { create(:user) }
  let(:product) { create(:product_with_pdf_file, user: seller) }
  let(:url_redirect) { create(:url_redirect, purchase: create(:purchase, email: "buyer@example.com", link: product)) }

  it "keeps serving an earlier buyer's download page" do
    url_redirect
    product.hold_sales!(seller:, held_by: create(:admin_user))

    get :download_page, params: { id: url_redirect.token }

    expect(response).to be_successful
    expect_inertia.to render_component("UrlRedirects/DownloadPage")
    expect(inertia.props[:content_unavailability_reason_code]).to be_nil
    expect(url_redirect.reload.is_file_downloadable?(product.product_files.alive.first)).to be(true)
  end
end
