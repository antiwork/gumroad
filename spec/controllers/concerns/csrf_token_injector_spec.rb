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
end
