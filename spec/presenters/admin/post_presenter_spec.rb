# frozen_string_literal: true

require "spec_helper"

describe Admin::PostPresenter do
  describe "#props" do
    let(:post) { create(:post) }
    let(:presenter) { described_class.new(post:) }

    subject(:props) { presenter.props }

    describe "basic structure" do
      it "returns a hash with all expected keys" do
        expect(props).to include(
          :external_id,
          :name,
          :created_at
        )
      end
    end

    describe "fields" do
      it "returns the correct field values" do
        expect(props[:external_id]).to eq(post.external_id)
        expect(props[:name]).to eq(post.name)
        expect(props[:created_at]).to eq(post.created_at)
      end
    end
  end
end
