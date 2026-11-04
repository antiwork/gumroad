# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe "Web build player", type: :request, inertia: true do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product) }
  let!(:url_redirect) { create(:url_redirect, link: product, purchase:) }
  let!(:build) { create(:product_build, :live, product:, number: 1, site_unpacked_at: Time.current) }
  let(:s3) { Aws::S3::Client.new }
  let(:index_html) { %(<!doctype html><html><head><title>Game</title><script src="game.js"></script></head><body></body></html>) }

  before do
    host! DOMAIN
    Feature.activate_user(:product_build_player, seller)
    s3.put_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/index.html", body: index_html, content_type: "text/html")
    s3.put_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/game.js", body: "console.log(1)", content_type: "text/javascript")
    s3.put_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/engine.wasm", body: "\0asm", content_type: "application/wasm")
    s3.put_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/art/logo.svg", body: "<svg xmlns='http://www.w3.org/2000/svg'/>", content_type: "image/svg+xml")
  end

  after do
    s3.list_objects_v2(bucket: S3_BUCKET, prefix: "#{build.site_prefix}/").contents.each do |object|
      s3.delete_object(bucket: S3_BUCKET, key: object.key)
    end
  end

  def frame_path
    get "/d/#{url_redirect.token}/play"
    expect(response).to have_http_status(:ok)
    inertia.props[:frame_url]
  end

  describe "GET /d/:token/play" do
    it "renders the player page with the product's name and a way back to the content" do
      get "/d/#{url_redirect.token}/play"

      expect_inertia.to render_component("UrlRedirects/Play")
      expect(inertia.props).to include(title: product.name, content_page_url: url_redirect.download_page_url)
    end

    it "frames the build under a grant, with a trailing slash so relative paths resolve under it" do
      path = frame_path

      expect(path).to match(%r{\A/d/#{url_redirect.token}/play/[^/]+/\z})
      grant = path.split("/")[4]
      expect(ProductBuild.verified_player_grant(grant, url_redirect_token: url_redirect.token)).to include(
        "purchase_id" => purchase.id, "seller_id" => seller.id, "site_prefix" => build.site_prefix,
      )
    end

    it "does not show the internal ids in the frame's URL" do
      grant = frame_path.split("/")[4]

      decoded = Base64.urlsafe_decode64(grant.split("--").first + "==") rescue ""
      expect(decoded).not_to include(build.site_prefix)
      expect(grant).not_to include(Base64.strict_encode64(build.site_prefix).delete("="))
    end

    it "marks the link as seen, so a later visitor from another IP has to confirm the email" do
      expect { frame_path }.to change { url_redirect.reload.has_been_seen }.from(false).to(true)
    end

    it "starts a rental's viewing window" do
      url_redirect.update!(is_rental: true)

      expect { frame_path }.to change { url_redirect.reload.rental_first_viewed_at }.from(nil)
    end

    it "returns 404 when the live build has not been unpacked" do
      build.update!(site_unpacked_at: nil)

      get "/d/#{url_redirect.token}/play"

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when the flag is off for the seller" do
      Feature.deactivate_user(:product_build_player, seller)

      get "/d/#{url_redirect.token}/play"

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a refunded purchase" do
      purchase.update!(stripe_refunded: true)

      get "/d/#{url_redirect.token}/play"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the frame document" do
    it "serves index.html sandboxed, with the buyer's save and the shim in front of the page's scripts" do
      ProductBuildSave.apply_changes!(purchase, set: { "best" => "</script><script>alert(1)</script>" })

      get frame_path

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
      csp = response.headers["Content-Security-Policy"]
      expect(csp).to start_with("sandbox allow-scripts allow-pointer-lock;")
      expect(csp).not_to include("allow-same-origin")
      expect(csp).to include("'wasm-unsafe-eval'")
      expect(csp).to include("frame-ancestors #{request.base_url}")
      expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
      expect(response.headers["Cache-Control"]).to include("no-store")

      body = response.body
      expect(body.index("gumroad:build-save")).to be < body.index(%(<script src="game.js">))
      expect(body).not_to include("</script><script>alert(1)")
      expect(body).to include("<title>Game</title>")
    end

    it "never writes the visitor's CSRF token into the seller's page" do
      placeholder = CsrfTokenInjector::TOKEN_PLACEHOLDER
      s3.put_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/index.html", content_type: "text/html",
                    body: %(<html><head><meta name="csrf-token" content="#{placeholder}"></head></html>))

      get frame_path

      expect(response.body).to include(%(content="#{placeholder}"))
    end

    it "serves the same document for an explicit index.html" do
      get "#{frame_path}index.html"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("gumroad:build-save")
    end

    it "serves an SVG from the app with the sandbox CSP, never as a CDN link" do
      get "#{frame_path}art/logo.svg"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/svg+xml")
      expect(response.headers["Content-Security-Policy"]).to start_with("sandbox allow-scripts allow-pointer-lock;")
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(response.body).not_to include("gumroad:build-save")
    end

    it "returns 404 for a page the build does not have" do
      get "#{frame_path}missing.html"

      expect(response).to have_http_status(:not_found)
    end

    it "stops new sessions when the flag is turned off" do
      path = frame_path
      Feature.deactivate_user(:product_build_player, seller)

      get path

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "saving from the frame" do
    def save_path
      get frame_path
      JSON.parse(JSON.parse(response.body[/(?:const|var) config = JSON\.parse\((".*")\);\n/, 1]))["saveUrl"]
    end

    def post_save(body, path: save_path)
      post path, params: body, headers: { "CONTENT_TYPE" => "text/plain;charset=UTF-8" }
    end

    it "applies a batch the frame sends under its grant, with no cookies, and lets the frame read the status" do
      ProductBuildSave.apply_changes!(purchase, set: { "level" => "3", "name" => "Ana" })
      path = save_path
      reset!
      host! DOMAIN

      post_save({ clear: false, remove: ["name"], set: { "level" => "4" } }.to_json, path:)

      expect(response).to have_http_status(:no_content)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(ProductBuildSave.find_by(purchase:).data).to eq("level" => "4")
    end

    it "gives the frame a save URL under a save grant of its own, which the file grant cannot use" do
      path = save_path
      save_grant = path.split("/")[4]
      file_grant = frame_path.split("/")[4]

      expect(path).to match(%r{\A/d/#{url_redirect.token}/play/[^/]+/save\z})
      expect(ProductBuild.verified_player_grant(save_grant, url_redirect_token: url_redirect.token, purpose: ProductBuild::PLAYER_SAVE_GRANT_PURPOSE)).to include("purchase_id" => purchase.id)

      post_save({ set: { "level" => "4" } }.to_json, path: "/d/#{url_redirect.token}/play/#{file_grant}/save")
      expect(response).to have_http_status(:not_found)
    end

    it "keeps saving after the file grant has expired" do
      path = save_path

      travel ProductBuild::PLAYER_GRANT_VALID_FOR + 1.day do
        post_save({ set: { "level" => "4" } }.to_json, path:)
      end

      expect(response).to have_http_status(:no_content)
      expect(ProductBuildSave.find_by(purchase:).data).to eq("level" => "4")
    end

    it "rejects a batch that is not valid JSON or has the wrong shape, and keeps the save" do
      ProductBuildSave.apply_changes!(purchase, set: { "level" => "3" })

      post_save("not json")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")

      post_save({ clear: true, set: ["level", "4"] }.to_json)
      expect(response).to have_http_status(:unprocessable_entity)

      expect(ProductBuildSave.find_by(purchase:).data).to eq("level" => "3")
    end

    it "rejects a body larger than any save" do
      stub_const("ProductBuildPlayerFilesController::MAX_SAVE_REQUEST_BYTES", 10)

      post_save({ set: { "level" => "4" } }.to_json)

      expect(response).to have_http_status(:payload_too_large)
      expect(ProductBuildSave.count).to eq(0)
    end

    it "returns 404 for a grant issued for another content-page token" do
      other_redirect = create(:url_redirect, link: product, purchase: create(:purchase, link: product))
      grant = save_path.split("/")[4]

      post_save({ set: { "level" => "4" } }.to_json, path: "/d/#{other_redirect.token}/play/#{grant}/save")

      expect(response).to have_http_status(:not_found)
      expect(ProductBuildSave.count).to eq(0)
    end
  end

  describe "the build's other files" do
    it "serves scripts from the app, so their relative imports resolve under the grant" do
      get "#{frame_path}game.js"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/javascript")
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(response.headers["Cache-Control"]).to include("private").and include("max-age=300")
      expect(response.body).to eq("console.log(1)")
    end

    it "streams a script far larger than any page, since only pages are read into memory" do
      script = "x" * (ProductBuild::MAX_PAGE_BYTE_SIZE * 3)
      s3.put_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/engine.js", body: script, content_type: "text/javascript")

      get "#{frame_path}engine.js"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Length"]).to eq(script.bytesize.to_s)
      expect(response.body.bytesize).to eq(script.bytesize)
    end

    it "redirects other files to a signed link that serves them inline, with CORS for the opaque origin" do
      get "#{frame_path}engine.wasm"

      expect(response).to have_http_status(:redirect)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(response.headers["Cache-Control"]).to include("private").and include("max-age=300")
      expect(response.location).to include("#{build.site_prefix}/engine.wasm")
      expect(response.location).not_to include("content-disposition")
      expect(Net::HTTP.get(URI.parse(response.location))).to eq("\0asm")
    end

    it "returns 404 for a grant that was issued for another content-page token" do
      other_redirect = create(:url_redirect, link: product, purchase: create(:purchase, link: product))
      grant = frame_path.split("/")[4]

      get "/d/#{other_redirect.token}/play/#{grant}/game.js"

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a tampered grant" do
      get "/d/#{url_redirect.token}/play/not-a-grant/game.js"

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for an expired grant" do
      path = frame_path

      travel ProductBuild::PLAYER_GRANT_VALID_FOR + 1.minute do
        get "#{path}game.js"
      end

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a path that leaves the build" do
      get "#{frame_path}art/%2E%2E/%2E%2E/build.zip"

      expect(response).to have_http_status(:not_found)
    end
  end
end
