# frozen_string_literal: true

require "spec_helper"

describe Onetime::ScrubGdprErasedUserComplianceInfoPii do
  def simulate_pre_fix_erasure(user)
    # Reproduce the state GdprDataErasureService left behind before it learned to null
    # compliance PII: placeholder email on the user, compliance rows soft-deleted but
    # with all their PII columns intact.
    user.user_compliance_infos.alive.each(&:mark_deleted!)
    user.update_columns(
      email: "deleted-#{user.id}@#{GdprDataErasureService::ANONYMIZED_EMAIL_DOMAIN}",
      deleted_at: Time.current,
    )
  end

  it "nulls PII columns on compliance rows of erased users and leaves other users untouched" do
    erased_user = create(:user)
    replaced_info = create(:user_compliance_info, user: erased_user, full_name: "Jane Roe", telephone_number: "+1 555 555 0100")
    replaced_info.mark_deleted!
    current_info = create(:user_compliance_info, user: erased_user, full_name: "Jane Roe", telephone_number: "+1 555 555 0100")
    simulate_pre_fix_erasure(erased_user)

    active_user = create(:user)
    active_info = create(:user_compliance_info, user: active_user)

    scrubbed_rows = described_class.process

    expect(scrubbed_rows).to eq(2)
    [replaced_info, current_info].each do |compliance_info|
      compliance_info.reload
      expect(compliance_info.full_name).to be_nil
      expect(compliance_info.first_name).to be_nil
      expect(compliance_info.last_name).to be_nil
      expect(compliance_info.birthday).to be_nil
      expect(compliance_info.street_address).to be_nil
      expect(compliance_info.city).to be_nil
      expect(compliance_info.state).to be_nil
      expect(compliance_info.zip_code).to be_nil
      expect(compliance_info.telephone_number).to be_nil
      # The JsonData concern deserializes a NULL column as an empty hash.
      expect(compliance_info.json_data).to be_blank
      expect(compliance_info.country).to eq("United States")
    end

    active_info.reload
    expect(active_info.first_name).to eq("Chuck")
    expect(active_info.street_address).to be_present
    expect(active_info.json_data).to be_present
  end

  it "processes erased users across multiple batches" do
    erased_users = create_list(:user, 2)
    infos = erased_users.map do |user|
      info = create(:user_compliance_info, user:)
      simulate_pre_fix_erasure(user)
      info
    end

    scrubbed_rows = described_class.process(batch_size: 1)

    expect(scrubbed_rows).to eq(2)
    infos.each do |info|
      expect(info.reload.first_name).to be_nil
    end
  end
end
