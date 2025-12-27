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
      settings_presenter = SettingsPresenter.new(pundit_user: controller.pundit_user)
      profile_presenter = ProfilePresenter.new(pundit_user: controller.pundit_user, seller:)
      expected_props = settings_presenter.profile_props.merge(
        profile_presenter.profile_settings_props(request:)
      )
      # Compare only the expected props from inertia.props (ignore shared props)
      actual_props = inertia.props.slice(*expected_props.keys)
      expect(actual_props).to eq(expected_props)
    end
  end

  describe "PUT update" do
    before do
      sign_in seller
      request.headers["X-Inertia"] = "true"
    end

    it "submits the form successfully" do
      put :update, params: { user: { name: "New name", username: "gum" } }
      expect(response).to redirect_to(settings_profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
      expect(seller.reload.name).to eq("New name")
      expect(seller.username).to eq("gum")
    end

    it "converts a blank username to nil" do
      seller.username = "oldusername"
      seller.save

      expect { put :update, params: { user: { username: "" } } }.to change {
        seller.reload.read_attribute(:username)
      }.from("oldusername").to(nil)
      expect(response).to redirect_to(settings_profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
    end

    it "performs model validations" do
      put :update, params: { user: { username: "ab" } }
      expect(response).to redirect_to(settings_profile_path)
      expect(response).to have_http_status :found
      expect(flash[:alert]).to eq("Username is too short (minimum is 3 characters)")
    end

    describe "when the user has not confirmed their email address" do
      before do
        seller.update!(confirmed_at: nil)
      end

      it "returns an error" do
        put :update, params: { user: { name: "New name" } }
        expect(response).to redirect_to(settings_profile_path)
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
      expect(response).to redirect_to(settings_profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
      expect(seller.seller_profile_sections.count).to eq 3
      expect(seller.seller_profile_sections.on_profile.count).to eq 2
      expect(seller.reload.seller_profile.json_data["tabs"]).to eq [{ name: "Tab 1", sections: [section1.id] }, { name: "Tab 2", sections: [section2.id] }, { name: "Tab 3", sections: [] }].as_json
      expect(seller.avatar.attached?).to be(true) # Ensure the avatar remains attached
    end

    it "returns an error if the corresponding blob for the provided 'profile_picture_blob_id' is already removed" do
      seller.avatar.attach(file_fixture("test.png"))
      signed_id = seller.avatar.signed_id

      # Purging an ActiveStorage::Blob in test environment returns Aws::S3::Errors::AccessDenied
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
      allow(ActiveStorage::Blob).to receive(:find_signed).with(signed_id).and_return(nil)

      seller.avatar.purge

      put :update, params: { user: { name: "New name" }, profile_picture_blob_id: signed_id }
      expect(response).to redirect_to(settings_profile_path)
      expect(response).to have_http_status :found
      expect(flash[:alert]).to eq("The logo is already removed. Please refresh the page and try again.")
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

      expect(response).to redirect_to(settings_profile_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("Changes saved!")
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(seller.id)
    end
  end
end
