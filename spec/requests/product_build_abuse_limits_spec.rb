# frozen_string_literal: true

require "spec_helper"

# Limits on web builds from sellers who are not proven yet (ContentModeration::GumroadImpersonation.unproven_seller?):
# probe accounts used free builds and public demos to put their own pages under gumroad.com.
describe "Web build limits for unproven sellers" do
  let(:s3) { Aws::S3::Client.new }
  let(:new_seller) { create(:user, email: "new-#{SecureRandom.hex(4)}@example.com", created_at: 1.day.ago) }
  let(:proven_seller) { create(:user, email: "proven-#{SecureRandom.hex(4)}@example.com", created_at: 1.year.ago) }

  def upload_zip(owner, entries = { "index.html" => "<h1>hi</h1>" })
    buffer = Zip::OutputStream.write_buffer do |zip|
      entries.each do |path, content|
        zip.put_next_entry(path)
        zip.write(content)
      end
    end
    key = "attachments/#{owner.external_id}/#{SecureRandom.hex}/original/game.zip"
    s3.put_object(bucket: S3_BUCKET, key:, body: buffer.string)
    "#{S3_BASE_URL}#{key}"
  end

  def deploy(product)
    ProductBuilds::DeployService.perform(product:, seller: product.user, url: upload_zip(product.user))
  end

  describe ProductBuilds::DeployService do
    it "refuses a build on a free product from a new seller" do
      product = create(:product, user: new_seller, price_cents: 0)
      expect { deploy(product) }.to raise_error(ProductBuilds::DeployService::DeployError, /free products are available once your account is 30 days old/)
    end

    it "accepts a build on a paid product from a new seller" do
      product = create(:product, user: new_seller, price_cents: 500)
      expect(deploy(product)).to be_persisted
    end

    it "accepts a build on a free product from a proven seller" do
      product = create(:product, user: proven_seller, price_cents: 0)
      expect(deploy(product)).to be_persisted
    end

    it "caps a new seller's builds per day across their products" do
      stub_const("ProductBuild::MAX_DAILY_BUILDS_FOR_UNPROVEN_SELLER", 2)
      products = create_list(:product, 3, user: new_seller, price_cents: 500)
      deploy(products[0])
      deploy(products[1])
      expect { deploy(products[2]) }.to raise_error(ProductBuilds::DeployService::DeployError, /2 builds a day/)
    end

    it "keeps the build list showing why a held build is not live" do
      build = create(:product_build, product: create(:product, user: new_seller), site_unpack_error: "held")
      expect(build.as_json[:unpack_error]).to eq("held")
    end

    it "does not cap a proven seller" do
      stub_const("ProductBuild::MAX_DAILY_BUILDS_FOR_UNPROVEN_SELLER", 1)
      products = create_list(:product, 2, user: proven_seller, price_cents: 500)
      deploy(products[0])
      expect(deploy(products[1])).to be_persisted
    end
  end

  describe "#playable? and #demo?" do
    before do
      Feature.activate_user(:product_build_player, seller)
      Feature.activate_user(:product_build_demo, seller)
    end

    let(:product) { create(:product, user: seller, price_cents: 0) }
    let(:build) { create(:product_build, product:, number: 1, status: "live", site_unpacked_at: Time.current) }

    context "with a new seller who already has a free build" do
      let(:seller) { new_seller }

      it "neither plays nor demos the free build" do
        expect(build.playable?).to be(false)
        expect(build.demo?).to be(false)
      end

      it "plays a paid product's build but never makes it a public demo" do
        product.update!(price_cents: 500)
        build.update!(demo_selected_at: Time.current, status: "uploaded")
        expect(build.reload.demo?).to be(false)
      end
    end

    context "with a new seller and a paid product" do
      let(:seller) { new_seller }

      it "refuses play to a fully discounted purchase" do
        product.update!(price_cents: 500)
        free = create(:purchase, link: product, price_cents: 0)
        paid = build_stubbed(:purchase, link: product, price_cents: 500)
        expect(build.free_play_allowed?(free)).to be(false)
        expect(build.free_play_allowed?(paid)).to be(true)
      end

      it "plays a bundle buyer's build, reading the charge from the bundle purchase" do
        # A bundle component is written with a price of 0, so the price resolution is what decides here:
        # without this stub the seller would already count as proven (see the example below).
        allow(ContentModeration::GumroadImpersonation).to receive(:unproven_seller?).and_return(true)
        product.update!(price_cents: 500)
        bundle = create(:purchase, link: create(:product, user: new_seller, price_cents: 500), price_cents: 500, merchant_account: create(:merchant_account))
        component = create(:purchase, link: product, price_cents: 0, is_bundle_product_purchase: true)
        BundleProductPurchase.create!(bundle_purchase: bundle, product_purchase: component)

        expect(build.free_play_allowed?(component.reload)).to be(true)
      end

      it "still refuses a bundle whose bundle purchase was fully discounted" do
        allow(ContentModeration::GumroadImpersonation).to receive(:unproven_seller?).and_return(true)
        product.update!(price_cents: 500)
        bundle = create(:purchase, link: create(:product, user: new_seller, price_cents: 500), price_cents: 0)
        component = create(:purchase, link: product, price_cents: 0, is_bundle_product_purchase: true)
        BundleProductPurchase.create!(bundle_purchase: bundle, product_purchase: component)

        expect(build.free_play_allowed?(component.reload)).to be(false)
      end

      it "plays a gift receiver's build, reading the charge from the gifter's purchase" do
        allow(ContentModeration::GumroadImpersonation).to receive(:unproven_seller?).and_return(true)
        product.update!(price_cents: 500)
        gifter = create(:purchase, link: product, price_cents: 500, merchant_account: create(:merchant_account))
        giftee = create(:purchase, link: product, price_cents: 0, is_gift_receiver_purchase: true)
        create(:gift, link: product, gifter_purchase: gifter, giftee_purchase: giftee)

        expect(build.free_play_allowed?(giftee.reload)).to be(true)
      end

      # The charged row belongs to the same seller (BundleProductPurchase checks that), so a paid bundle
      # or gift also makes the seller proven. This pins that coupling: if "proven" ever stops counting
      # those purchases, the examples above keep the play decision on what was actually paid.
      it "plays a paid bundle buyer in practice, because the bundle purchase makes the seller proven" do
        product.update!(price_cents: 500)
        bundle = create(:purchase, link: create(:product, user: new_seller, price_cents: 500), price_cents: 500, merchant_account: create(:merchant_account))
        component = create(:purchase, link: product, price_cents: 0, is_bundle_product_purchase: true)
        BundleProductPurchase.create!(bundle_purchase: bundle, product_purchase: component)

        expect(new_seller.sales.paid.exists?).to be(true)
        expect(build.free_play_allowed?(component.reload)).to be(true)
      end
    end

    context "with a proven seller" do
      let(:seller) { proven_seller }

      it "plays and demos the free build" do
        expect(build.playable?).to be(true)
        expect(build.demo?).to be(true)
      end
    end
  end

  describe ProductBuilds::UnpackSiteService do
    let(:phishing_page) { %(<form><input type="email" name="e"><input type="password" name="p"><button>Sign in</button></form>) }

    def unpack(seller, entries)
      product = create(:product, user: seller, price_cents: 500)
      build = create(:product_build, product:, number: 1)
      s3.list_objects_v2(bucket: S3_BUCKET, prefix: "builds/#{product.id}/1/").contents.each { s3.delete_object(bucket: S3_BUCKET, key: _1.key) }
      buffer = Zip::OutputStream.write_buffer do |zip|
        entries.each do |path, content|
          zip.put_next_entry(path)
          zip.write(content)
        end
      end
      s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: buffer.string)
      [build, -> { described_class.perform(build) }]
    end

    it "holds a new seller's build with a password field, and writes nothing" do
      build, run = unpack(new_seller, { "index.html" => "<h1>ok</h1>", "login.html" => phishing_page })
      expect { run.call }.to raise_error(described_class::UnpackError, /needs a quick review/)
      expect(build.reload.site_ready?).to be(false)
      expect(build.site_unpack_error).to include("needs a quick review")
      expect(s3.list_objects_v2(bucket: S3_BUCKET, prefix: build.site_prefix).contents).to be_empty
    end

    it "holds a new seller's email field next to payout wording" do
      _, run = unpack(new_seller, { "index.html" => %(<p>Verify your payout</p><input type="email">) })
      expect { run.call }.to raise_error(described_class::UnpackError, /needs a quick review/)
    end

    it "holds a password field whose type is written with character references" do
      _, run = unpack(new_seller, { "index.html" => %(<input type="pass&#119;ord">) })
      expect { run.call }.to raise_error(described_class::UnpackError, /needs a quick review/)
    end

    it "lets a new seller's email signup through when nothing asks for sign-in details" do
      build, run = unpack(new_seller, { "index.html" => %(<p>Join the newsletter</p><input type="email">) })
      run.call
      expect(build.reload.site_ready?).to be(true)
    end

    it "does not check a proven seller's pages" do
      build, run = unpack(proven_seller, { "index.html" => phishing_page })
      run.call
      expect(build.reload.site_ready?).to be(true)
    end
  end

  describe "indexing" do
    before { host! DOMAIN }

    it "keeps the public demo page out of search results" do
      seller = proven_seller
      Feature.activate_user(:product_build_player, seller)
      Feature.activate_user(:product_build_demo, seller)
      product = create(:product, user: seller, price_cents: 0)
      create(:product_build, product:, number: 1, status: "live", site_unpacked_at: Time.current)
      get "/demo/#{product.external_id}"
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end
  end
end
