# frozen_string_literal: true

require "spec_helper"

# A route whose :controller default does not resolve raises ActionDispatch::MissingController
# on every request, so the endpoint answers 500 rather than 404.
describe "route controllers" do
  it "all resolve to a real controller" do
    unresolved = Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      next if controller.blank?

      begin
        "#{controller}_controller".camelize.constantize
        nil
      rescue NameError
        "#{controller} (#{route.verb} #{route.path.spec})"
      end
    end

    expect(unresolved).to be_empty
  end
end
