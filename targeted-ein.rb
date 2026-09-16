require_relative "spec/spec_helper"
Capybara.server_port = 33609
Capybara.app_host = "http://test.gumroad.com:33609"
exit RSpec::Core::Runner.run(["spec/requests/settings/payments_spec.rb", "-e", "US business with EIN already saved"])
