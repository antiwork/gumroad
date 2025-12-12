# frozen_string_literal: true

class UpdateUserComplianceInfo
  attr_reader :compliance_params, :user, :remote_ip

  def initialize(compliance_params:, user:, remote_ip: nil)
    @compliance_params = compliance_params
    @user = user
    @remote_ip = remote_ip
  end

  def process
    return { success: true } if compliance_params.blank?

    new_compliance_info = nil

    ActiveRecord::Base.transaction do
      old_compliance_info = user.fetch_or_build_user_compliance_info
      saved, new_compliance_info = old_compliance_info.dup_and_save do |info|
        assign_compliance_fields(info)
      end

      if !saved
        raise ActiveRecord::Rollback
      end

      if has_guardian_params?
        guardian = new_compliance_info.guardian || Guardian.new
        update_guardian(guardian)
        if !guardian.save(context: :submission)
          @guardian_errors = guardian.errors.full_messages.to_sentence
          raise ActiveRecord::Rollback
        end
        new_compliance_info.update!(guardian: guardian)
      end
    end

    return { success: false, error_message: new_compliance_info&.errors&.full_messages&.to_sentence } if new_compliance_info&.errors&.any?
    return { success: false, error_message: @guardian_errors } if @guardian_errors.present?

    begin
      StripeMerchantAccountManager.handle_new_user_compliance_info(new_compliance_info)
      UserComplianceInfoRequest.handle_new_user_compliance_info(new_compliance_info)
    rescue Stripe::InvalidRequestError => e
      return { success: false, error_message: "Compliance info update failed with this error: #{e.message.split("Please contact us").first.strip}", error_code: "stripe_error" }
    end

    { success: true }
  end

  private
    def assign_compliance_fields(info)
      assign_basic_fields(info)
      assign_business_fields(info)
      assign_tax_and_date_fields(info)
      assign_country_specific_fields(info)
    end

    def assign_basic_fields(info)
      info.first_name = compliance_params[:first_name] if compliance_params[:first_name].present?
      info.last_name = compliance_params[:last_name] if compliance_params[:last_name].present?
      info.street_address = compliance_params[:street_address] if compliance_params[:street_address].present?
      info.building_number = compliance_params[:building_number] if compliance_params[:building_number].present?
      info.city = compliance_params[:city] if compliance_params[:city].present?
      info.state = compliance_params[:state] if compliance_params[:state].present?
      info.zip_code = compliance_params[:zip_code] if compliance_params[:zip_code].present?
      info.phone = compliance_params[:phone] if compliance_params[:phone].present?
      info.country = Compliance::Countries.mapping[compliance_params[:country]] if compliance_params[:country].present? && compliance_params[:is_business]
      info.skip_stripe_job_on_create = true
    end

    def assign_business_fields(info)
      info.is_business = compliance_params[:is_business] if !compliance_params[:is_business].nil?
      info.business_name = compliance_params[:business_name] if compliance_params[:business_name].present?
      info.business_street_address = compliance_params[:business_street_address] if compliance_params[:business_street_address].present?
      info.business_building_number = compliance_params[:business_building_number] if compliance_params[:business_building_number].present?
      info.business_city = compliance_params[:business_city] if compliance_params[:business_city].present?
      info.business_state = compliance_params[:business_state] if compliance_params[:business_state].present?
      info.business_zip_code = compliance_params[:business_zip_code] if compliance_params[:business_zip_code].present?
      info.business_phone = compliance_params[:business_phone] if compliance_params[:business_phone].present?
      info.business_type = compliance_params[:business_type] if compliance_params[:business_type].present?
      info.business_country = Compliance::Countries.mapping[compliance_params[:business_country]] if compliance_params[:business_country].present? && compliance_params[:is_business]
    end

    def assign_tax_and_date_fields(info)
      info.individual_tax_id = compliance_params[:ssn_last_four] if compliance_params[:ssn_last_four].present?
      info.individual_tax_id = compliance_params[:individual_tax_id] if compliance_params[:individual_tax_id].present?
      info.business_tax_id = compliance_params[:business_tax_id] if compliance_params[:business_tax_id].present?
      info.business_vat_id_number = compliance_params[:business_vat_id_number] if compliance_params[:business_vat_id_number].present?

      if compliance_params[:dob_year].present? && compliance_params[:dob_year].to_i > 0
        info.birthday = Date.new(
          compliance_params[:dob_year].to_i,
          compliance_params[:dob_month].to_i,
          compliance_params[:dob_day].to_i
        )
      end
    end

    def assign_country_specific_fields(info)
      info.first_name_kanji = compliance_params[:first_name_kanji] if compliance_params[:first_name_kanji].present?
      info.last_name_kanji = compliance_params[:last_name_kanji] if compliance_params[:last_name_kanji].present?
      info.first_name_kana = compliance_params[:first_name_kana] if compliance_params[:first_name_kana].present?
      info.last_name_kana = compliance_params[:last_name_kana] if compliance_params[:last_name_kana].present?
      info.street_address_kanji = compliance_params[:street_address_kanji] if compliance_params[:street_address_kanji].present?
      info.street_address_kana = compliance_params[:street_address_kana] if compliance_params[:street_address_kana].present?
      info.business_name_kanji = compliance_params[:business_name_kanji] if compliance_params[:business_name_kanji].present?
      info.business_name_kana = compliance_params[:business_name_kana] if compliance_params[:business_name_kana].present?
      info.business_street_address_kanji = compliance_params[:business_street_address_kanji] if compliance_params[:business_street_address_kanji].present?
      info.business_street_address_kana = compliance_params[:business_street_address_kana] if compliance_params[:business_street_address_kana].present?
      info.job_title = compliance_params[:job_title] if compliance_params[:job_title].present?
      info.nationality = compliance_params[:nationality] if compliance_params[:nationality].present?
    end

    def has_guardian_params?
      Guardian::PARAM_FIELDS.any? { |field| compliance_params[field].present? }
    end

    def update_guardian(guardian)
      assign_mapped_guardian_fields(guardian)
      assign_guardian_country(guardian)
      assign_guardian_date_of_birth(guardian)
      assign_guardian_tax_id(guardian)
      assign_guardian_tos_fields(guardian)
    end

    def assign_mapped_guardian_fields(guardian)
      Guardian::PARAM_TO_ATTRIBUTE_MAPPING.each do |param_key, attribute|
        value = compliance_params[param_key]
        guardian.public_send("#{attribute}=", value) if value.present?
      end
    end

    def assign_guardian_country(guardian)
      return if compliance_params[:guardian_country].blank?

      guardian.country = Compliance::Countries.mapping[compliance_params[:guardian_country]]
    end

    def assign_guardian_date_of_birth(guardian)
      return if compliance_params[:guardian_dob_year].blank?
      return if compliance_params[:guardian_dob_month].blank?
      return if compliance_params[:guardian_dob_day].blank?

      guardian.date_of_birth = Date.new(
        compliance_params[:guardian_dob_year].to_i,
        compliance_params[:guardian_dob_month].to_i,
        compliance_params[:guardian_dob_day].to_i
      )
    end

    def assign_guardian_tax_id(guardian)
      guardian.individual_tax_id = compliance_params[:guardian_ssn_last_four] if compliance_params[:guardian_ssn_last_four].present?
      guardian.individual_tax_id = compliance_params[:guardian_individual_tax_id] if compliance_params[:guardian_individual_tax_id].present?
    end

    def assign_guardian_tos_fields(guardian)
      if compliance_params[:guardian_stripe_tos_accepted].present?
        guardian.stripe_tos_accepted = ActiveModel::Type::Boolean.new.cast(compliance_params[:guardian_stripe_tos_accepted])
        guardian.stripe_tos_ip = remote_ip if remote_ip.present?
      end

      if compliance_params[:guardian_stripe_processing_tos_accepted].present?
        guardian.stripe_processing_tos_accepted = ActiveModel::Type::Boolean.new.cast(compliance_params[:guardian_stripe_processing_tos_accepted])
      end
    end

    def filter_sensitive_params(params)
      filtered = params.dup
      sensitive_keys = [:individual_tax_id, :business_tax_id, :guardian_individual_tax_id, :ssn_last_four, :guardian_ssn_last_four]

      sensitive_keys.each do |key|
        filtered[key] = "[FILTERED]" if filtered[key].present?
      end

      filtered
    end
end
