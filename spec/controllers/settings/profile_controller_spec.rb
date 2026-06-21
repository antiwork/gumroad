# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Settings::ProfileController, :vcr, type: :controller, inertia: true do
  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: user_with_role_for_seller, seller:) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", Settings::ProfilePolicy do
    let(:record) { :profile }
  end

  describe "GET show" do
    it "returns successful response with Inertia page data" do
      get :show

      expect(response).to be_successful
      expect(inertia.component).to eq("Settings/Profile/Show")
      profile_presenter = ProfilePresenter.new(pundit_user: controller.pundit_user, seller:)
      expected_props = profile_presenter.profile_settings_props(request:)
      # Compare only the expected props from inertia.props (ignore shared props)
      actual_props = inertia.props.slice(*expected_props.keys)
      expect(actual_props).to eq(expected_props)
    end

    it "includes read-only preview props and owner-only editable profile props" do
      product = create(:product, user: seller)
      section = create(:seller_profile_products_section, seller:, shown_products: [product.id])
      seller.seller_profile.update!(json_data: { tabs: [{ name: "", sections: [section.id] }] })

      get :show

      expect(inertia.props[:creator_profile][:can_edit]).to eq(false)
      expect(inertia.props).not_to have_key(:products)
      expect(inertia.props[:sections].sole).not_to have_key(:shown_products)

      expect(inertia.props[:editable_profile][:creator_profile][:can_edit]).to eq(true)
      expect(inertia.props[:editable_profile][:products]).to include({ id: product.external_id, name: product.name })
      expect(inertia.props[:editable_profile][:sections].sole).to include(
        header: section.header || "",
        hide_header: section.hide_header?,
        shown_products: [product.external_id],
      )
    end
  end

  describe "PUT update" do
    before do
      sign_in seller
      request.headers["X-Inertia"] = "true"
    end

    it "submits the form successfully" do
      put :update, params: { user: { name: "New name" } }
      expect(response).to redirect_to(profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
      expect(seller.reload.name).to eq("New name")
    end

    it "does not allow profile design fields to be updated from profile settings" do
      seller.seller_profile.update!(background_color: "#ffffff", highlight_color: "#ff90e8", font: "ABC Favorit")

      put :update, params: { seller_profile: { background_color: "#000000", highlight_color: "#009a49", font: "Roboto Mono" } }

      expect(response).to redirect_to(profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
      expect(seller.reload.seller_profile).to have_attributes(
        background_color: "#ffffff",
        highlight_color: "#ff90e8",
        font: "ABC Favorit",
      )
    end

    describe "when the user has not confirmed their email address" do
      before do
        seller.update!(confirmed_at: nil)
      end

      it "returns an error" do
        put :update, params: { user: { name: "New name" } }
        expect(response).to redirect_to(profile_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("You have to confirm your email address before you can do that.")
      end
    end

    it "saves tabs and cleans up orphan sections" do
      section1 = create(:seller_profile_products_section, seller:)
      section2 = create(:seller_profile_posts_section, seller:)
      create(:seller_profile_posts_section, seller:)
      create(:seller_profile_posts_section, seller:, product: create(:product))
      seller.avatar.attach(file_fixture("test.png"))

      put :update, params: { tabs: [{ name: "Tab 1", sections: [section1.external_id] }, { name: "Tab 2", sections: [section2.external_id] }, { name: "Tab 3", sections: [] }] }
      expect(response).to redirect_to(profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
      expect(seller.seller_profile_sections.count).to eq 3
      expect(seller.seller_profile_sections.on_profile.count).to eq 2
      expect(seller.reload.seller_profile.json_data["tabs"]).to eq [{ name: "Tab 1", sections: [section1.id] }, { name: "Tab 2", sections: [section2.id] }, { name: "Tab 3", sections: [] }].as_json
      expect(seller.avatar.attached?).to be(true) # Ensure the avatar remains attached
    end

    describe "batch-saving sections" do
      let(:temp_id) { "0b8f3782-3a85-4f93-8e3c-2b1f5d3e8a90" }

      it "creates sections carrying temporary ids and maps tab references to the new records" do
        expect do
          put :update, params: {
            sections: [{ id: temp_id, type: "SellerProfileSubscribeSection", header: "Subscribe", hide_header: false, button_label: "Follow" }],
            tabs: [{ name: "Tab 1", sections: [temp_id] }],
          }, as: :json
        end.to change { seller.seller_profile_sections.count }.from(0).to(1)

        expect(response).to redirect_to(profile_path)
        expect(response).to have_http_status :see_other
        expect(flash[:notice]).to eq("Changes saved!")
        section = seller.seller_profile_subscribe_sections.sole
        expect(section).to have_attributes(header: "Subscribe", hide_header: false, button_label: "Follow")
        expect(seller.reload.seller_profile.json_data["tabs"]).to eq [{ name: "Tab 1", sections: [section.id] }].as_json
      end

      it "updates existing sections and creates new ones in the same save" do
        products = create_list(:product, 2, user: seller)
        existing = create(:seller_profile_products_section, seller:, header: "Old")
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [existing.id] }] })

        put :update, params: {
          sections: [
            { id: existing.external_id, header: "Updated", shown_products: products.map(&:external_id) },
            { id: temp_id, type: "SellerProfileProductsSection", header: "New", shown_products: [], default_product_sort: "page_layout", show_filters: false, add_new_products: true },
          ],
          tabs: [{ name: "Tab 1", sections: [existing.external_id, temp_id] }],
          profile_version: seller.seller_profile.layout_version.iso8601(6),
        }, as: :json

        expect(response).to have_http_status :see_other
        expect(seller.seller_profile_sections.count).to eq 2
        expect(existing.reload).to have_attributes(header: "Updated", hide_header: false, shown_products: products.map(&:id))
        new_section = seller.seller_profile_sections.where.not(id: existing.id).sole
        expect(new_section.header).to eq("New")
        expect(seller.reload.seller_profile.json_data["tabs"]).to eq [{ name: "Tab 1", sections: [existing.id, new_section.id] }].as_json
      end

      it "updates shown_posts on an existing posts section" do
        post1 = create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, seller:, shown_on_profile: true)
        post2 = create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, seller:, shown_on_profile: true)
        existing = create(:seller_profile_posts_section, seller:, header: "Old", shown_posts: [post1.id])
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [existing.id] }] })

        put :update, params: {
          sections: [{ id: existing.external_id, header: "Updated", shown_posts: [post1.external_id, post2.external_id] }],
          tabs: [{ name: "Tab 1", sections: [existing.external_id] }],
          profile_version: seller.seller_profile.layout_version.iso8601(6),
        }, as: :json

        expect(response).to have_http_status :see_other
        expect(existing.reload).to have_attributes(header: "Updated", shown_posts: [post1.id, post2.id])
      end

      it "destroys sections that no tab references anymore" do
        removed = create(:seller_profile_products_section, seller:)
        kept = create(:seller_profile_products_section, seller:, header: "Old")
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [removed.id, kept.id] }] })

        put :update, params: {
          sections: [{ id: kept.external_id, header: "Kept" }],
          tabs: [{ name: "Tab 1", sections: [kept.external_id] }],
          profile_version: seller.seller_profile.layout_version.iso8601(6),
        }, as: :json

        expect(response).to have_http_status :see_other
        expect(seller.seller_profile_sections.sole).to eq kept
        expect(kept.reload.header).to eq("Kept")
        expect(seller.reload.seller_profile.json_data["tabs"]).to eq [{ name: "Tab 1", sections: [kept.id] }].as_json
      end

      it "rejects the save and keeps the current layout when the profile changed since it was loaded" do
        section = create(:seller_profile_products_section, seller:, header: "Section 1")
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [section.id] }] })
        stale_version = seller.seller_profile.layout_version.iso8601(6)

        # Another session adds a section and saves, advancing the profile's version.
        concurrent = create(:seller_profile_products_section, seller:, header: "Added elsewhere")
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [section.id, concurrent.id] }] })

        put :update, params: {
          sections: [{ id: section.external_id, header: "Renamed" }],
          tabs: [{ name: "Tab 1", sections: [section.external_id] }],
          profile_version: stale_version,
        }, as: :json

        expect(response).to redirect_to(profile_path)
        expect(flash[:alert]).to include("changed somewhere else")
        # The stale write is rejected wholesale: the other session's section and the layout survive.
        expect(SellerProfileSection.exists?(concurrent.id)).to be true
        expect(section.reload.header).to eq "Section 1"
        expect(seller.reload.seller_profile.json_data["tabs"]).to eq [{ name: "Tab 1", sections: [section.id, concurrent.id] }].as_json
      end

      it "leaves the avatar unchanged when a stale layout save is rejected" do
        seller.avatar.attach(file_fixture("test.png"))
        original_blob_id = seller.avatar.blob.id
        section = create(:seller_profile_products_section, seller:, header: "Section 1")
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [section.id] }] })
        stale_version = seller.seller_profile.layout_version.iso8601(6)

        # Another session edits the section, advancing the profile's version.
        section.update!(header: "Changed elsewhere")

        new_blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")

        put :update, params: {
          profile_picture_blob_id: new_blob.signed_id,
          sections: [{ id: section.external_id, header: "Renamed" }],
          tabs: [{ name: "Tab 1", sections: [section.external_id] }],
          profile_version: stale_version,
        }, as: :json

        expect(flash[:alert]).to include("changed somewhere else")
        expect(seller.reload.avatar.blob.id).to eq(original_blob_id)
      end

      it "rejects the save when a section's content was edited in another session" do
        section = create(:seller_profile_products_section, seller:, header: "Section 1")
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [section.id] }] })
        stale_version = seller.seller_profile.layout_version.iso8601(6)

        # Another session edits the section's content. That bumps the section row's updated_at, not
        # the profile's, so the version must fold in section timestamps to notice the change.
        section.update!(header: "Edited elsewhere")

        put :update, params: {
          sections: [{ id: section.external_id, header: "My rename" }],
          tabs: [{ name: "Tab 1", sections: [section.external_id] }],
          profile_version: stale_version,
        }, as: :json

        expect(response).to redirect_to(profile_path)
        expect(flash[:alert]).to include("changed somewhere else")
        expect(section.reload.header).to eq "Edited elsewhere"
      end

      it "drops tab section references that no longer resolve to a saved section" do
        kept = create(:seller_profile_products_section, seller:)

        put :update, params: {
          sections: [{ id: kept.external_id, header: "Kept" }],
          tabs: [{ name: "Tab 1", sections: [kept.external_id, temp_id] }],
        }, as: :json

        expect(response).to have_http_status :see_other
        expect(seller.reload.seller_profile.json_data["tabs"]).to eq [{ name: "Tab 1", sections: [kept.id] }].as_json
      end

      it "does not prune sections when a tab reference can't be resolved" do
        kept = create(:seller_profile_products_section, seller:)
        also_present = create(:seller_profile_products_section, seller:)
        seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [kept.id, also_present.id] }] })

        put :update, params: {
          tabs: [{ name: "Tab 1", sections: [kept.external_id, temp_id] }],
          profile_version: seller.seller_profile.layout_version.iso8601(6),
        }, as: :json

        expect(response).to have_http_status :see_other
        expect(seller.seller_profile_sections.pluck(:id)).to match_array([kept.id, also_present.id])
      end

      it "does not keep a row for a new section that no tab references" do
        put :update, params: {
          sections: [{ id: temp_id, type: "SellerProfileSubscribeSection", button_label: "Subscribe" }],
          tabs: [{ name: "Tab 1", sections: [] }],
        }, as: :json

        expect(response).to have_http_status :see_other
        expect(seller.seller_profile_sections.count).to eq 0
      end

      it "processes rich text upsell content for sections created in the batch save" do
        product = create(:product, user: seller)
        text = {
          type: "doc",
          content: [
            { type: "paragraph", content: [{ text: "hi", type: "text" }] },
            { type: "upsellCard", attrs: { discount: nil, productId: product.external_id } },
          ],
        }

        put :update, params: {
          sections: [{ id: temp_id, type: "SellerProfileRichTextSection", text: }],
          tabs: [{ name: "Tab 1", sections: [temp_id] }],
        }, as: :json

        expect(response).to have_http_status :see_other
        upsell = Upsell.last
        expect(upsell).to be_alive
        expect(upsell.product_id).to eq(product.id)
        section = seller.seller_profile_rich_text_sections.sole
        expect(section.text["content"][1]["attrs"]["id"]).to eq(upsell.external_id)
      end

      it "rolls back the whole save when a section is invalid" do
        put :update, params: {
          user: { name: "Updated name" },
          sections: [{ id: temp_id, type: "SellerProfileProductsSection", show_filters: "i hack u :)" }],
          tabs: [{ name: "Tab 1", sections: [temp_id] }],
        }, as: :json

        expect(response).to redirect_to(profile_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to include("show_filters")
        expect(seller.reload.name).to_not eq("Updated name")
        expect(seller.seller_profile_sections.count).to eq 0
      end

      it "returns an error for an invalid section type" do
        put :update, params: {
          sections: [{ id: temp_id, type: "SellerProfileFakeSection" }],
        }, as: :json

        expect(response).to redirect_to(profile_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("Invalid section type")
        expect(seller.seller_profile_sections.count).to eq 0
      end
    end

    it "returns an error if the corresponding blob for the provided 'profile_picture_blob_id' is already removed" do
      seller.avatar.attach(file_fixture("test.png"))
      signed_id = seller.avatar.signed_id

      # Purging an ActiveStorage::Blob in test environment returns Aws::S3::Errors::AccessDenied
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
      allow(ActiveStorage::Blob).to receive(:find_signed).with(signed_id).and_return(nil)

      seller.avatar.purge

      put :update, params: { user: { name: "New name" }, profile_picture_blob_id: signed_id }
      expect(response).to redirect_to(profile_path)
      expect(response).to have_http_status :found
      expect(flash[:alert]).to eq("The logo is already removed. Please refresh the page and try again.")
    end

    it "handles duplicate attachment gracefully when avatar is already attached with the same blob" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: fixture_file_upload("smilie.png"),
        filename: "smilie.png",
      )
      seller.avatar.attach(blob)

      put :update, params: { profile_picture_blob_id: blob.signed_id }

      expect(response).to redirect_to(profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
      expect(seller.avatar.attached?).to be(true)
    end

    it "handles concurrent avatar attachment race condition" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: fixture_file_upload("smilie.png"),
        filename: "smilie.png",
      )

      allow_any_instance_of(ActiveStorage::Attached::One).to receive(:attach).and_raise(ActiveRecord::RecordNotUnique)

      put :update, params: { profile_picture_blob_id: blob.signed_id }

      expect(response).to redirect_to(profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
    end

    it "regenerates the subscribe preview when the avatar changes" do
      allow_any_instance_of(User).to receive(:generate_subscribe_preview).and_call_original

      blob = ActiveStorage::Blob.create_and_upload!(
        io: fixture_file_upload("smilie.png"),
        filename: "smilie.png",
      )

      expect do
        put :update, params: {
          profile_picture_blob_id: blob.signed_id
        }
      end.to change { GenerateSubscribePreviewJob.jobs.size }.by(1)

      expect(response).to redirect_to(profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(seller.id)
    end
  end
end
