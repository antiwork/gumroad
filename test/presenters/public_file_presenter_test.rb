# frozen_string_literal: true

require "test_helper"

class PublicFilePresenterTest < ActiveSupport::TestCase
  self.described_class = PublicFilePresenter



  context_ PublicFilePresenter do
    include CdnUrlHelper

  context_ "#props" do
      let(:public_file) { create(:public_file, :with_audio) }
      let(:presenter) { described_class.new(public_file:) }

      before do
        public_file.file.analyze
      end

  test "returns necessary file props" do
        props = presenter.props

        expect(props).to include(
          id: public_file.public_id,
          name: public_file.display_name,
          extension: "MP3",
          status: { type: "saved" }
        )

        expect(props[:file_size]).to be > 30_000
        expect(props[:url]).to eq(cdn_url_for(public_file.file.blob.url))
      end

  context_ "when file is not attached" do
        let(:public_file) { create(:public_file) }

  test "returns nil file_size and url" do
          expect(presenter.props[:file_size]).to be_nil
          expect(presenter.props[:url]).to be_nil
        end
      end
    end
  end
end
