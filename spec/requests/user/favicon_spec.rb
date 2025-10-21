# frozen_string_literal: true

require "spec_helper"

describe "User favicons", type: :system, js: true do
  before do
    @product = create(:product, name: "product name", user: create(:named_user))
    @purchase = create(:purchase, link: @product)
    @post = create(:installment, seller: @product.user, link: @product, installment_type: "product", published_at: Time.current)
    @user = @product.user
    login_as @user
    upload_profile_photo
  end

  describe "user profile photo as a favicon" do
    it "does display on the profile page" do
      visit("/#{@user.username}")
      expect(page).to have_xpath("/html/head/link[@href='#{@user.avatar_url}']", visible: false)
    end

    it "does display on a post's page" do
      visit(view_post_path(username: @user.username, slug: @post.slug, purchase_id: @purchase.external_id))
      expect(page).to have_xpath("/html/head/link[@href='#{@user.avatar_url}']", visible: false)
    end

    it "does display on a product page" do
      visit short_link_path(@product)
      expect(page).to have_xpath("/html/head/link[@href='#{@user.avatar_url}']", visible: false)
    end
  end

  private
    def upload_profile_photo
      visit settings_profile_path
      within_fieldset "Logo" do
        click_on "Remove"
        attach_file("Upload", file_fixture("test.png"), visible: false)
      end
      within_section("Preview", section_element: :aside) do
        expect(page).to have_selector("img[alt='Profile Picture'][src*=cdn_url_for_blob]")
      end
      click_on "Update settings"
      wait_for_ajax
      expect(@user.reload.avatar_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{@user.avatar_variant.key}")
    end
end
