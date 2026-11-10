# frozen_string_literal: true

require "spec_helper"

describe "layouts/shared/_flash" do
  before { allow(view).to receive(:inertia_rendering?).and_return(false) }

  { notice: "success", alert: "danger", warning: "warning", info: "info" }.each do |key, status|
    it "renders a #{key} flash with the #{status} markup generated from ui/Alert" do
      flash[key] = "Saved <b>it</b>"
      generated = Rails.root.join("app/views/layouts/shared/flash/_#{status}.html.erb").read.lines.last.strip

      render partial: "layouts/shared/flash"

      expect(generated).to include("<%= message %>")
      expect(rendered).to include(generated.sub("<%= message %>", "Saved &lt;b&gt;it&lt;/b&gt;"))
    end
  end
end
