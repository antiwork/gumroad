# frozen_string_literal: true

require "spec_helper"

describe IconHelper do
  describe "#icon" do
    it "renders icon without options" do
      output = icon("solid-search")
      expect(output).to eq('<span class="icon icon-solid-search"></span>')
    end

    it "renders icon with options" do
      output = icon("solid-search", class: "warning", title: "Search")
      expect(output).to eq('<span class="icon icon-solid-search warning" title="Search"></span>')
    end
  end

  describe "#icon_yes" do
    it "renders the icon" do
      expect(icon_yes).to eq('<span aria-label="Yes" style="color: rgb(var(--success))" class="icon icon-solid-check-circle"></span>')
    end
  end

  describe "#icon_no" do
    it "renders the icon" do
      expect(icon_no).to eq('<span aria-label="No" style="color: rgb(var(--danger))" class="icon icon-x-circle-fill"></span>')
    end
  end
end
