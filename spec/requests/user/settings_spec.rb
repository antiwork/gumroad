# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "User profile settings page", type: :system, js: true do
  before do
    @user = create(:named_user, :with_bio)
    time = Time.current
    # So that the products get created in a consistent order
    travel_to time
    @product1 = create(:product, user: @user, name: "Product 1", price_cents: 2000)
    travel_to time + 1
    @product2 = create(:product, user: @user, name: "Product 2", price_cents: 1000)
    travel_to time + 2
    @product3 = create(:product, user: @user, name: "Product 3", price_cents: 3000)
    login_as @user
    create(:seller_profile_products_section, seller: @user, shown_products: [@product1, @product2, @product3].map(&:id))
  end

  describe "profile preview" do
    it "renders the header" do
      visit settings_profile_path

      expect(page).to have_text "Preview"
      expect(page).to have_link "Preview", href: root_url(host: @user.subdomain)
    end

    it "renders the profile" do
      visit settings_profile_path

      within_section "Preview", section_element: :aside do
        expect(page).to have_text @user.name
        expect(page).to have_text @user.bio
      end
    end
  end

  describe "saving profile updates" do
    it "normalizes input and saves the username" do
      visit settings_profile_path
      raw_username = "Katsuya 123 !@#"
      normalized_username = "katsuya123"
      within_section "Profile", section_element: :section do
        expect(page).to have_link(@user.subdomain, href: @user.subdomain_with_protocol)
        fill_in("Username", with: raw_username)
        new_subdomain = Subdomain.from_username(normalized_username)
        expect(page).to have_link(new_subdomain, href: "#{PROTOCOL}://#{new_subdomain}")
      end
      click_on("Update settings")
      wait_for_ajax
      expect(page).to have_alert(text: "Changes saved!")
      expect(@user.reload.username).to eq normalized_username
    end

    it "saves the name and bio" do
      visit settings_profile_path
      fill_in "Name", with: "Creator name"
      fill_in "Bio", with: "Creator bio"
      within_section "Preview", section_element: :aside do
        expect(page).to have_text("Creator name")
        expect(page).to have_text("Creator bio")
      end
      click_on "Update settings"
      wait_for_ajax
      expect(@user.reload.name).to eq "Creator name"
      expect(@user.bio).to eq "Creator bio"
    end

    describe "logo" do
      def upload_logo(file)
        within_fieldset "Logo" do
          click_on "Remove"
          attach_file("Upload", file_fixture(file), visible: false)
        end
      end

      context "when the logo is valid" do
        it "saves the logo" do
          visit settings_profile_path
          upload_logo("test.png")
          within_section("Preview", section_element: :aside) do
            expect(page).to have_selector("img[alt='Profile Picture'][src*=cdn_url_for_blob]")
          end
          click_on "Update settings"
          wait_for_ajax
          expect(@user.reload.avatar_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{@user.avatar_variant.key}")
        end
      end

      it "purges the attached logo when the logo is removed" do
        # Purging an ActiveStorage::Blob in test environment returns Aws::S3::Errors::AccessDenied
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)

        visit settings_profile_path
        upload_logo("test.png")
        within_section("Preview", section_element: :aside) do
          expect(page).to have_selector("img[alt='Profile Picture'][src*=cdn_url_for_blob]")
        end
        click_on "Update settings"
        expect(page).to have_alert(text: "Changes saved!")
        expect(@user.reload.avatar_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{@user.avatar_variant.key}")

        within_fieldset "Logo" do
          click_on "Remove"
          expect(page).to have_field("Upload", visible: false)
        end
        click_on "Update settings"
        wait_for_ajax
        expect(page).to have_alert(text: "Changes saved!")
        expect(@user.reload.avatar_url).to eq(ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"))
        refresh
        expect(page).to have_selector("img[alt='Current logo'][src*='gumroad-default-avatar-5']")
        within_section("Preview", section_element: :aside) do
          expect(page).to have_selector("img[alt='Profile Picture'][src*='gumroad-default-avatar-5']")
        end
      end

      context "when the logo is invalid" do
        it "displays an error if either dimension is less than 200px" do
          visit settings_profile_path
          upload_logo("test-small.png")
          within_section("Preview", section_element: :aside) do
            expect(page).to have_selector("img[alt='Profile Picture'][src*=cdn_url_for_blob]")
          end
          click_on "Update settings"
          wait_for_ajax
          expect(page).to have_alert(text: "Please upload a profile picture that is at least 200x200px")
          expect(@user.reload.avatar.filename).to_not eq("smaller.png")
        end

        it "displays an error if format is unpermitted" do
          visit settings_profile_path
          upload_logo("test-svg.svg")
          expect(page).to have_alert(text: "Invalid file type")
        end
      end
    end

    it "rejects logo if file type is unsupported" do
      visit settings_profile_path
      within_fieldset "Logo" do
        click_on "Remove"
        attach_file("Upload", file_fixture("test-small.gif"), visible: false)
      end
      expect(page).to have_alert(text: "Invalid file type.")
    end

    it "saves the background color, highlight color, and font" do
      visit settings_profile_path
      fill_in_color(find_field("Background color"), "#facade")
      fill_in_color(find_field("Highlight color"), "#decade")
      choose "Roboto Mono"
      click_on "Update settings"
      wait_for_ajax
      expect(@user.reload.seller_profile.highlight_color).to eq("#decade")
      expect(@user.seller_profile.background_color).to eq("#facade")
      expect(@user.seller_profile.font).to eq("Roboto Mono")
    end

    it "saves connected or disconnected Twitter account" do
      visit settings_profile_path
      expect(page).to have_button("Connect to X")
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:twitter] = OmniAuth::AuthHash.new JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/twitter_omniauth.json").read)
      OmniAuth.config.before_callback_phase do |env|
        env["omniauth.params"] = { "state" => "link_twitter_account" }
      end
      click_on "Connect to X"
      expect(@user.reload.twitter_handle).not_to be_nil
      click_on "Disconnect #{@user.twitter_handle} from X"
      wait_for_ajax
      expect(@user.reload.twitter_handle).to be_nil
      expect(page).to have_button("Connect to X")
      # Reset the before_callback_phase to avoid making other X tests flaky.
      OmniAuth.config.before_callback_phase = nil
    end

    context "when logged user has role admin" do
      include_context "with switching account to user as admin for seller" do
        let(:seller) { @user }
      end

      it "does not show social links" do
        visit settings_profile_path

        expect(page).not_to have_text("Social links")
        expect(page).not_to have_link("Connect to X", href: user_twitter_omniauth_authorize_path(state: "link_twitter_account", x_auth_access_type: "read"))
      end
    end
  end
end
