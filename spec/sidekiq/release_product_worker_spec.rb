# frozen_string_literal: true

describe ReleaseProductWorker do
  let(:product) { create(:product_with_pdf_file, is_in_preorder_state: true) }
  let!(:rich_content) { create(:rich_content, entity: product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => product.product_files.first.external_id, "uid" => SecureRandom.uuid } }]) }

  let(:release_at) { 2.days.from_now }
  let!(:preorder_link) { create(:preorder_link, link: product, release_at:) }

  it "releases the product" do
    travel_to release_at do
      expect do
        ReleaseProductWorker.new.perform(product.id)
      end.to change { preorder_link.reload.released? }.from(false).to(true)
    end
  end
end
