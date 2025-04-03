# frozen_string_literal: true

require "spec_helper"

describe InfosHelper do
  describe "#pagelength_displayable" do
    let(:pagelength) { 100 }

    context "when filetype is 'epub'" do
      it "returns a string indicating the number of sections" do
        allow(helper).to receive(:pagelength).and_return(pagelength)
        allow(helper).to receive(:epub?).and_return(true)
        expect(helper.pagelength_displayable).to eq("100 sections")
      end
    end

    context "when filetype is not 'epub'" do
      it "returns a string indicating the number of pages" do
        allow(helper).to receive(:pagelength).and_return(pagelength)
        allow(helper).to receive(:epub?).and_return(false)
        expect(helper.pagelength_displayable).to eq("100 pages")
      end
    end
  end
end
