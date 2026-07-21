# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe UrlRedirectsController, inertia: true do
  it "allows local EPUB assets and blocks seller-controlled remote subresources" do
    buyer = create(:user)
    product = create(:product)
    epub = create(:epub_product_file, link: product)
    purchase = create(:free_purchase, link: product, purchaser: buyer, email: buyer.email)
    url_redirect = create(:url_redirect, link: product, purchase:)
    sign_in buyer
    allow(Rails.application.config).to receive(:asset_host).and_return("https://assets.gumroad.test")
    csp_without_test_blob = SecureHeaders::Configuration.dup
    csp_without_test_blob.csp[:style_src] = csp_without_test_blob.csp[:style_src] - ["blob:"]
    request.env[SecureHeaders::SECURE_HEADERS_CONFIG] = csp_without_test_blob

    get :read, params: { id: url_redirect.token, product_file_id: epub.external_id }

    expect(response).to be_successful
    csp = request.env.fetch(SecureHeaders::SECURE_HEADERS_CONFIG).csp.to_h
    expect(csp[:style_src]).to eq(["'self'", "'unsafe-inline'", "blob:", "https://assets.gumroad.test"])
    expect(csp[:font_src]).to eq(["'self'", "data:", "blob:", "https://assets.gumroad.test"])
    %i[child_src frame_src img_src media_src object_src].each do |directive|
      expect(csp[directive]).to eq(["'self'", "data:", "blob:"])
    end
  end

  it "redirects a known oversized EPUB to the library instead of mounting the reader" do
    buyer = create(:user)
    product = create(:product)
    epub = create(:epub_product_file, link: product, size: ProductFile::MAX_EPUB_READER_ARCHIVE_SIZE + 1)
    purchase = create(:free_purchase, link: product, purchaser: buyer, email: buyer.email)
    url_redirect = create(:url_redirect, link: product, purchase:)
    sign_in buyer

    get :read, params: { id: url_redirect.token, product_file_id: epub.external_id }

    expect(response).to redirect_to(library_path)
  end
end
