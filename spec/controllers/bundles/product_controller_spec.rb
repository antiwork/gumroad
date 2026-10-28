# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Bundles::ProductController, inertia: true do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000, price_currency_type: "usd") }

  include_context "with user signed in as admin for seller"

  describe "GET edit" do
    it "renders the bundle's display currency so the editor's selector opens on it" do
      bundle.price_currency_type = "eur"
      bundle.price_cents = 2000
      bundle.save!

      get :edit, params: { bundle_id: bundle.external_id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Bundles/Product/Edit")
      expect(inertia.props[:currency_type]).to eq("eur")
    end

    it "lists the bundle's retained files inside the bundle props, where the editor reads them" do
      file = create(:product_file, link: bundle)

      get :edit, params: { bundle_id: bundle.external_id }

      expect(inertia.props[:bundle][:retained_files]).to match([hash_including(id: file.external_id)])
      expect(inertia.props).not_to have_key(:retained_files)
    end
  end

  describe "PUT update" do
    it "changes the bundle's display currency" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000 }

      expect(bundle.reload.price_currency_type).to eq("eur")
    end

    # The seller's actual path: they touch only the currency dropdown, so the
    # form re-sends the unchanged amount. The Price row is filed under whatever
    # currency is set when `price_cents=` runs, so if the amount landed first
    # there would be no row in the new currency and the save would fail on a
    # blank default price.
    it "carries the existing amount into the new currency when the amount is unchanged" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000 }

      bundle.reload
      expect(bundle.price_currency_type).to eq("eur")
      expect(bundle.price_cents).to eq(2000)
      expect(bundle.alive_prices.is_buy.where(currency: "eur").last&.price_cents).to eq(2000)
    end

    it "carries the existing amount across when the request omits the price entirely" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur" }

      bundle.reload
      expect(bundle.price_currency_type).to eq("eur")
      expect(bundle.price_cents).to eq(2000)
    end

    # The regression this endpoint's ordering exists for: `price_cents=` files a
    # Price row scoped to price_currency_type as it stands at that moment, so
    # assigning the amount first leaves the new price under the old currency and
    # the bundle reads back the stale one. Reverting the ordering reddens here.
    it "files the submitted amount under the new currency, not the old one" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 3500 }

      bundle.reload
      expect(bundle.price_currency_type).to eq("eur")
      expect(bundle.alive_prices.is_buy.where(currency: "eur").last&.price_cents).to eq(3500)
      expect(bundle.price_cents).to eq(3500)
    end

    # Non-default currency on purpose: with a usd fixture this is green whether
    # the omit branch preserves the value or resets it to the seller default.
    it "leaves the currency alone when the request omits it" do
      bundle.update!(price_currency_type: "gbp", price_cents: 2000)

      put :update, params: { bundle_id: bundle.external_id, price_cents: 2500 }

      expect(bundle.reload.price_currency_type).to eq("gbp")
      expect(bundle.price_cents).to eq(2500)
    end

    # The form re-sends the current default_offer_code_id on every save, so
    # without the unchanged-id short circuit in update_default_offer_code a
    # universal currency-scoped code fails the whole save with the unrelated
    # "Offer code must apply to this product".
    it "still changes the currency when the resent default offer code is universal and currency-scoped" do
      offer_code = create(:universal_offer_code, user: seller, amount_cents: 100, currency_type: "usd", code: "univ")
      bundle.update!(default_offer_code: offer_code)

      put :update, params: {
        bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000,
        default_offer_code_id: offer_code.external_id
      }

      bundle.reload
      expect(bundle.price_currency_type).to eq("eur")
      expect(bundle.default_offer_code).to be_nil
    end

    # A product-specific fixed-amount code is not detached or currency-checked
    # anywhere on this path, so without the warning the seller's discount stops
    # quoting with nothing said. Mirrors LinksController#update.
    context "when a fixed-amount offer code no longer matches the new currency" do
      let!(:offer_code) { create(:offer_code, user: seller, products: [bundle], code: "tenoff", amount_cents: 500, currency_type: "usd") }

      it "warns the seller and names the code" do
        put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000 }

        expect(bundle.reload.price_currency_type).to eq("eur")
        expect(flash[:warning]).to include("tenoff")
        expect(flash[:warning]).to include("will not apply at checkout")
        expect(flash[:notice]).to be_blank
      end

      # Universal codes are scoped to the bundle's *current* currency, so once
      # the new currency is saved the old-currency ones vanish from
      # product_and_universal_offer_codes — the controller has to capture the
      # list before the change or these codes go stale with nothing said.
      it "also warns about a universal fixed-amount code left behind in the old currency" do
        create(:universal_offer_code, user: seller, amount_cents: 500, currency_type: "usd", code: "unistale")

        put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000 }

        expect(bundle.reload.price_currency_type).to eq("eur")
        expect(flash[:warning]).to include("unistale")
        expect(flash[:warning]).to include("tenoff")
        expect(flash[:notice]).to be_blank
      end

      it "stays quiet when the currency did not move" do
        put :update, params: { bundle_id: bundle.external_id, price_cents: 2500 }

        expect(flash[:warning]).to be_blank
        expect(flash[:notice]).to eq("Changes saved!")
      end
    end

    it "stays quiet on a currency change when no offer code is attached" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "eur", price_cents: 2000 }

      expect(bundle.reload.price_currency_type).to eq("eur")
      expect(flash[:warning]).to be_blank
      expect(flash[:notice]).to eq("Changes saved!")
    end

    it "keeps a supplied redirect on the Gumroad host" do
      put :update, params: { bundle_id: bundle.external_id, redirect_to: "https://evil.example/phish", price_cents: 2000 }

      expect(response).to redirect_to("/phish")
    end

    # An unsupported currency is caught by the model's own
    # `price_must_be_within_range`, not by anything added here — these pin that
    # it surfaces to the seller as a flash alert and rolls the whole update back.
    it "rejects a currency Gumroad does not price in" do
      put :update, params: { bundle_id: bundle.external_id, price_currency_type: "xyz", price_cents: 2000 }

      expect(flash[:alert]).to eq("'xyz' is not a supported currency.")
      expect(bundle.reload.price_currency_type).to eq("usd")
    end

    it "does not persist any other submitted change when the currency is rejected" do
      put :update, params: { bundle_id: bundle.external_id, name: "Renamed", price_currency_type: "xyz" }

      expect(bundle.reload.name).not_to eq("Renamed")
    end
  end

  describe "POST remove_file" do
    let!(:file) { create(:product_file, link: bundle, url: "#{S3_BASE_URL}specs/vol-1.zip") }

    it_behaves_like "authorize called for action", :post, :remove_file do
      let(:policy_klass) { LinkPolicy }
      let(:record) { bundle }
      let(:request_params) { { bundle_id: bundle.external_id, file_id: file.external_id } }
    end

    it "soft-deletes the file and re-indexes the product's filetypes" do
      expect_any_instance_of(Link).to receive(:enqueue_index_update_for).with(["filetypes"]).and_call_original

      post :remove_file, params: { bundle_id: bundle.external_id, file_id: file.external_id }

      expect(response).to be_successful
      expect(file.reload).to be_deleted
      expect(bundle.reload.alive_product_files).to be_empty
    end

    it "leaves the files of the products in the bundle alone" do
      member = create(:product, user: seller)
      create(:product_file, link: member)
      create(:bundle_product, bundle:, product: member, quantity: 1, position: 0)

      post :remove_file, params: { bundle_id: bundle.external_id, file_id: file.external_id }

      expect(member.reload.alive_product_files.count).to eq(1)
    end

    it "refuses a file that belongs to another product" do
      other = create(:product_file, link: create(:product, user: seller))

      post :remove_file, params: { bundle_id: bundle.external_id, file_id: other.external_id }

      expect(response).to have_http_status(:not_found)
      expect(other.reload).to be_alive
    end

    it "removes a legacy file that no longer passes its own validations" do
      file.update_column(:isbn, "978-3-16-148410-0")

      post :remove_file, params: { bundle_id: bundle.external_id, file_id: file.external_id }

      expect(response).to be_successful
      expect(file.reload).to be_deleted
    end

    # The download endpoints serve the newest ready archive without checking its contents, so an
    # archive built from the file would keep shipping it to buyers who purchased before the conversion.
    it "kills the archives built while the file was attached" do
      stale = ready_archive([file])

      post :remove_file, params: { bundle_id: bundle.external_id, file_id: file.external_id }

      expect(response).to be_successful
      expect(stale.reload).to be_deleted
    end

    it "rebuilds the product-level archive from the files that are left" do
      kept = create(:product_file, link: bundle, url: "#{S3_BASE_URL}specs/vol-2.zip")
      stale = ready_archive([file, kept])

      post :remove_file, params: { bundle_id: bundle.external_id, file_id: file.external_id }

      expect(stale.reload).to be_deleted
      expect(bundle.product_files_archives.alive.entity_archives.last.product_files).to eq([kept])
    end

    it "builds the replacement product-level archive only after the removal commits" do
      kept = create(:product_file, link: bundle, url: "#{S3_BASE_URL}specs/vol-2.zip")
      ready_archive([file, kept])
      allow_any_instance_of(Link).to receive(:enqueue_index_update_for).and_raise(ActiveRecord::RecordNotSaved, "boom")

      expect do
        post :remove_file, params: { bundle_id: bundle.external_id, file_id: file.external_id }
      end.not_to change { UpdateProductFilesArchiveWorker.jobs.size }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(file.reload).to be_alive
      expect(bundle.product_files_archives.alive.entity_archives.sole.product_files).to contain_exactly(file, kept)
    end

    context "when the file is in a folder archive" do
      let(:other_file) { create(:product_file, link: bundle, url: "#{S3_BASE_URL}specs/vol-2.zip") }
      let(:loose_file) { create(:product_file, link: bundle, url: "#{S3_BASE_URL}specs/extras.zip") }
      let(:folder_uid) { SecureRandom.uuid }
      let!(:folder_archive) do
        create(:rich_content, entity: bundle, description: [
                 {
                   "type" => "fileEmbedGroup",
                   "attrs" => { "name" => "Volumes", "uid" => folder_uid },
                   "content" => [file, other_file].map { { "type" => "fileEmbed", "attrs" => { "id" => _1.external_id, "uid" => SecureRandom.uuid } } },
                 },
                 { "type" => "fileEmbed", "attrs" => { "id" => loose_file.external_id, "uid" => SecureRandom.uuid } },
               ])
        Link.find(bundle.id).product_files_archives.create!(folder_id: folder_uid, product_files: [file, other_file]).tap do |archive|
          archive.mark_in_progress!
          archive.mark_ready!
        end
      end

      it "invalidates the archive in the same commit and queues its rebuild" do
        expect do
          post :remove_file, params: { bundle_id: bundle.external_id, file_id: file.external_id }
        end.to change { GenerateProductFilesArchivesJob.jobs.size }.by(1)

        expect(response).to be_successful
        expect(folder_archive.reload).to be_deleted
        expect(GenerateProductFilesArchivesJob.jobs.last["args"]).to eq([bundle.id])
      end

      it "keeps the archive when the removed file was never in it" do
        post :remove_file, params: { bundle_id: bundle.external_id, file_id: loose_file.external_id }

        expect(response).to be_successful
        expect(loose_file.reload).to be_deleted
        expect(folder_archive.reload).to be_alive
      end

      it "rolls the removal back and says so when the archive invalidation fails" do
        allow_any_instance_of(ProductFilesArchive).to receive(:mark_deleted!).and_raise(ActiveRecord::RecordInvalid.new(folder_archive))

        expect do
          post :remove_file, params: { bundle_id: bundle.external_id, file_id: file.external_id }
        end.not_to change { GenerateProductFilesArchivesJob.jobs.size }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to eq(false)
        expect(file.reload).to be_alive
        expect(folder_archive.reload).to be_alive
      end

      # The file is already deleted when the enqueue runs, so the response must say so.
      it "reports a failed rebuild enqueue without answering the removal as failed" do
        allow(GenerateProductFilesArchivesJob).to receive(:perform_async).and_raise(Redis::CannotConnectError, "redis is down")
        expect(ErrorNotifier).to receive(:notify).with(
          instance_of(Redis::CannotConnectError),
          hash_including(product_id: bundle.id, archive_generation_enqueue_failed: true)
        )

        post :remove_file, params: { bundle_id: bundle.external_id, file_id: file.external_id }

        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true)
        expect(file.reload).to be_deleted
        expect(folder_archive.reload).to be_deleted
      end
    end

    def ready_archive(files)
      archive = bundle.product_files_archives.create!(product_files: files)
      archive.mark_in_progress!
      archive.mark_ready!
      archive
    end
  end
end
