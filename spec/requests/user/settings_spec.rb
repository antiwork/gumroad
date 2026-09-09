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
    it "renders the browser-style chrome" do
      visit profile_path

      within find("aside[aria-label='Preview']") do
        expect(page).to have_text @user.name
        expect(page).to have_text root_url(host: @user.subdomain).sub(%r{\Ahttps?://}, "").chomp("/")
        expect(page).to have_link "Open in new tab", href: root_url(host: @user.subdomain)
      end
    end

    it "renders the profile" do
      visit profile_path

      within find("aside[aria-label='Preview']") do
        expect(page).to have_text @user.name
        expect(page).to have_text @user.bio
      end
    end
  end

  describe "saving profile updates" do
    it "saves the name and bio" do
      visit profile_path
      fill_in "Name", with: "Creator name", fill_options: { clear: :backspace }
      fill_in "Bio", with: "Creator bio", fill_options: { clear: :backspace }
      within find("aside[aria-label='Preview']") do
        expect(page).to have_text("Creator name")
        expect(page).to have_text("Creator bio")
      end
      click_on "Update profile"
      expect(page).to have_alert(text: "Changes saved!")
      expect(@user.reload.name).to eq "Creator name"
      expect(@user.bio).to eq "Creator bio"
    end

    describe "avatar" do
      def upload_logo(file)
        within_fieldset "Avatar" do
          click_on "Remove"
          attach_file("Upload", file_fixture(file), visible: false)
        end
      end

      context "when the avatar is valid" do
        it "saves the avatar" do
          visit profile_path
          upload_logo("test.png")
          within find("aside[aria-label='Preview']") do
            expect(page).to have_selector("img[alt='Profile Picture'][src*=cdn_url_for_blob]")
          end
          click_on "Update profile"
          expect(page).to have_alert(text: "Changes saved!")
          expect(@user.reload.avatar_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{@user.avatar_variant.key}")
        end
      end

      it "purges the attached avatar when the avatar is removed" do
        # Purging an ActiveStorage::Blob in test environment returns Aws::S3::Errors::AccessDenied
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)

        visit profile_path
        upload_logo("test.png")
        within find("aside[aria-label='Preview']") do
          expect(page).to have_selector("img[alt='Profile Picture'][src*=cdn_url_for_blob]")
        end
        click_on "Update profile"
        expect(page).to have_alert(text: "Changes saved!")
        wait_for_ajax
        expect(@user.reload.avatar_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{@user.avatar_variant.key}")

        within_fieldset "Avatar" do
          click_on "Remove"
          expect(page).to have_field("Upload", visible: false)
        end
        click_on "Update profile"
        expect(page).to have_alert(text: "Changes saved!")
        wait_for_ajax
        expect(@user.reload.avatar_url).to eq(ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png"))
        refresh
        expect(page).to have_selector("img[alt='Current avatar'][src*='gumroad-default-avatar-5']")
        within find("aside[aria-label='Preview']") do
          expect(page).to have_selector("img[alt='Profile Picture'][src*='gumroad-default-avatar-5']")
        end
      end

      context "when the avatar is invalid" do
        it "displays an error if either dimension is less than 200px" do
          visit profile_path
          upload_logo("test-small.png")
          within find("aside[aria-label='Preview']") do
            expect(page).to have_selector("img[alt='Profile Picture'][src*=cdn_url_for_blob]")
          end
          click_on "Update profile"
          expect(page).to have_alert(text: "Please upload a profile picture that is at least 200x200px")
          expect(@user.reload.avatar.filename).to_not eq("smaller.png")
        end

        it "displays an error if format is unpermitted" do
          visit profile_path
          upload_logo("test-svg.svg")
          expect(page).to have_alert(text: "Invalid file type")
        end
      end
    end

    it "rejects avatar if file type is unsupported" do
      visit profile_path
      within_fieldset "Avatar" do
        click_on "Remove"
        attach_file("Upload", file_fixture("test-small.gif"), visible: false)
      end
      expect(page).to have_alert(text: "Invalid file type.")
    end
  end
end
