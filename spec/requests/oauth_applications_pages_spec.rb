# frozen_string_literal: true

require("spec_helper")

describe "OauthApplicationsPages", type: :feature, js: true do
  context "On /settings/advanced page" do
    let(:user) { create(:named_user) }

    before do
      login_as user
      visit settings_advanced_path
    end

    it "creates an OAuth application with correct parameters" do
      expect do
        within_section "Applications", section_element: :section do
          fill_in("Application name", with: "test")
          fill_in("Redirect URI", with: "http://l.h:9292/callback")
          page.attach_file(file_fixture("test.jpg")) do
            click_on "Upload icon"
          end
          expect(page).to have_button("Upload icon")
          expect(page).to have_selector("img[src*='s3_utility/cdn_url_for_blob?key=#{ActiveStorage::Blob.last.key}']")
          click_button("Create application")
        end
        wait_for_ajax
      end.to change { OauthApplication.count }.by(1)

      OauthApplication.last.tap do |app|
        expect(app.name).to eq "test"
        expect(app.redirect_uri).to eq "http://l.h:9292/callback"
        expect(app.affiliate_basis_points).to eq nil
        expect(app.file.filename.to_s).to eq "test.jpg"
        expect(app.owner).to eq user
      end
    end

    it "does not allow adding an icon of invalid type" do
      within_section "Applications", section_element: :section do
        page.attach_file(file_fixture("disguised_html_script.png")) do
          click_on "Upload icon"
        end
      end
      expect(page).to have_alert(text: "Invalid file type.")
    end

    it "allows adding valid icon after trying an invalid one" do
      within_section "Applications", section_element: :section do
        page.attach_file(file_fixture("disguised_html_script.png")) do
          click_on "Upload icon"
        end
      end
      expect(page).to have_alert(text: "Invalid file type.")

      expect do
        within_section "Applications", section_element: :section do
          fill_in("Application name", with: "test")
          fill_in("Redirect URI", with: "http://l.h:9292/callback")
          page.attach_file(file_fixture("test.jpg")) do
            click_on "Upload icon"
          end
          expect(page).to have_button("Upload icon")
          expect(page).to have_selector("img[src*='s3_utility/cdn_url_for_blob?key=#{ActiveStorage::Blob.last.key}']")
          click_button("Create application")
        end
        wait_for_ajax
      end.to change { OauthApplication.count }.by(1)
    end
  end

  it "allows seller to generate an access token for their application without breaking '/settings/authorized_applications'" do
    logout
    application = create(:oauth_application_valid)
    login_as(application.owner)
    visit("/oauth/applications/#{application.external_id}/edit")
    click_on "Generate access token"
    wait_for_ajax
    visit settings_authorized_applications_path
    expect(page).to have_content("You've authorized the following applications to use your Gumroad account.")
  end

  it "generates tokens that do not have the mobile_api scope" do
    logout
    application = create(:oauth_application_valid)
    login_as(application.owner)
    visit("/oauth/applications/#{application.external_id}/edit")
    click_on "Generate access token"
    wait_for_ajax
    expect(page).to have_field("Access Token", with: application.access_tokens.last.token)
    expect(application.access_grants.count).to eq 1
    expect(application.access_tokens.count).to eq 1
    expect(application.access_tokens.last.scopes.to_a).to eq %w[edit_products view_sales mark_sales_as_shipped refund_sales revenue_share ifttt view_profile view_payouts]
  end

  it "doesn't list the application if there are no grants for it" do
    logout
    application = create(:oauth_application_valid)
    login_as(application.owner)
    allow(Doorkeeper::AccessGrant).to receive(:order).and_return(Doorkeeper::AccessGrant.where(id: 0))
    visit settings_authorized_applications_path
    expect(page).to_not have_content(application.name)
  end

  it "correctly displays access grants and allows user to revoke access of authorized applications" do
    logout
    user = create(:user)
    login_as(user)
    app_names = []
    5.times do
      application = create(:oauth_application_valid)
      app_names << application.name
      Doorkeeper::AccessGrant.create!(application_id: application.id, resource_owner_id: user.id,
                                      redirect_uri: application.redirect_uri, expires_in: 1.day.from_now,
                                      scopes: Doorkeeper.configuration.public_scopes.join(" "))
      Doorkeeper::AccessToken.create!(application_id: application.id, resource_owner_id: user.id)
    end
    visit settings_authorized_applications_path
    expect(page).to have_content("You've authorized the following applications to use your Gumroad account.")
    app_names.each { |app_name| expect(page).to(have_content(app_name)) }

    within_row app_names.first do
      click_on "Revoke access"
    end

    within_modal "Revoke access" do
      expect(page).to have_text("Are you sure you want to revoke access to #{app_names.first}?")
      click_on "Yes, revoke access"
    end
    expect(page).to(have_alert(text: "Authorized application revoked"))
    expect(page).not_to(have_content(app_names.first))
    app_names.drop(1).each { |app_name| expect(page).to(have_content(app_name)) }
  end
end
