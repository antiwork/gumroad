# frozen_string_literal: true

require "spec_helper"

describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller) }
  let!(:kept_file) { create(:product_file, link: product) }
  let!(:removed_file) { create(:product_file, link: product) }
  let(:flag_store) { { down: false } }

  before do
    sign_in seller
    Feature.activate_user(:product_editor_save_contract, seller)
    # The flag store's own Redis read fails, below the fail-open wrapper. Activating the flag above
    # cleared the wrapper's cached value for it, so the failure reaches the save contract.
    allow_any_instance_of(Flipper::Adapters::Redis).to receive(:get).and_wrap_original do |original, feature|
      raise Redis::CannotConnectError if flag_store[:down] && feature.key == Product::SaveContract::FEATURE_NAME.to_s
      original.call(feature)
    end
    allow(ErrorNotifier).to receive(:notify)
  end

  after { Feature.deactivate_user(:product_editor_save_contract, seller) }

  def save_removing(file, editor_revision:)
    put :update, params: {
      id: product.unique_permalink,
      files: [{ external_id: kept_file.external_id, url: kept_file.url }],
      editor_revision:,
      deletion_operations: { deleted_ids: { files: [file.external_id] } },
    }, as: :json
  end

  it "reports a file removal it skipped while the flag store was down, and applies it on the next save" do
    flag_store[:down] = true
    save_removing(removed_file, editor_revision: Product::EditorRevision.current(product))

    expect(response).to be_successful
    expect(ErrorNotifier).to have_received(:notify).with(an_instance_of(Redis::CannotConnectError), hash_including(context: "Product::SaveContract flag lookup"))
    expect(removed_file.reload).to be_alive
    expect(response.parsed_body["file_deletions_skipped"]).to eq(true)
    editor_revision = response.parsed_body["editor_revision"]
    expect(editor_revision).to be_present

    flag_store[:down] = false
    save_removing(removed_file, editor_revision:)

    expect(response).to be_successful
    expect(response.parsed_body).not_to have_key("file_deletions_skipped")
    expect(removed_file.reload).to be_deleted
    expect(kept_file.reload).to be_alive
  end

  it "gives a stale tab no fresh revision, so its skipped removal is still refused after the flag store recovers" do
    stale_revision = Product::EditorRevision.current(product)
    removed_file.update!(description: "Edited in another tab")

    flag_store[:down] = true
    save_removing(removed_file, editor_revision: stale_revision)

    expect(response).to be_successful
    expect(response.parsed_body["file_deletions_skipped"]).to eq(true)
    expect(response.parsed_body).not_to have_key("editor_revision")

    flag_store[:down] = false
    save_removing(removed_file, editor_revision: stale_revision)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error_code"]).to eq("stale_deletion_conflict")
    expect(removed_file.reload).to be_alive
  end
end
