# frozen_string_literal: true

class UpdateUserComplianceInfo
  attr_reader :compliance_params, :user, :remote_ip

  def initialize(compliance_params:, user:, remote_ip: nil)
    @compliance_params = compliance_params
    @user = user
    @remote_ip = remote_ip
  end

  def process
    if compliance_params.present?
      old_compliance_info = user.fetch_or_build_user_compliance_info
      saved, new_compliance_info = old_compliance_info.dup_and_save do |new_compliance_info|
        # if the following fields are submitted and are blank, we don't clear the field for the user
        new_compliance_info.first_name =              compliance_params[:first_name]              if compliance_params[:first_name].present?
        new_compliance_info.last_name =               compliance_params[:last_name]               if compliance_params[:last_name].present?
        new_compliance_info.first_name_kanji =        compliance_params[:first_name_kanji]        if compliance_params[:first_name_kanji].present?
        new_compliance_info.last_name_kanji =         compliance_params[:last_name_kanji]         if compliance_params[:last_name_kanji].present?
        new_compliance_info.first_name_kana =         compliance_params[:first_name_kana]         if compliance_params[:first_name_kana].present?
        new_compliance_info.last_name_kana =          compliance_params[:last_name_kana]          if compliance_params[:last_name_kana].present?
        new_compliance_info.street_address =          compliance_params[:street_address]          if compliance_params[:street_address].present?
        new_compliance_info.building_number =         compliance_params[:building_number]         if compliance_params[:building_number].present?
        new_compliance_info.street_address_kanji =    compliance_params[:street_address_kanji]    if compliance_params[:street_address_kanji].present?
        new_compliance_info.street_address_kana =     compliance_params[:street_address_kana]     if compliance_params[:street_address_kana].present?
        new_compliance_info.city =                    compliance_params[:city]                    if compliance_params[:city].present?
        new_compliance_info.state =                   compliance_params[:state]                   if compliance_params[:state].present?
        new_compliance_info.country =                 Compliance::Countries.mapping[compliance_params[:country]] if compliance_params[:country].present? && compliance_params[:is_business]
        new_compliance_info.zip_code =                compliance_params[:zip_code]                if compliance_params[:zip_code].present?
        new_compliance_info.business_name =           compliance_params[:business_name]           if compliance_params[:business_name].present?
        new_compliance_info.business_name_kanji =     compliance_params[:business_name_kanji]     if compliance_params[:business_name_kanji].present?
        new_compliance_info.business_name_kana =      compliance_params[:business_name_kana]      if compliance_params[:business_name_kana].present?
        new_compliance_info.business_street_address = compliance_params[:business_street_address] if compliance_params[:business_street_address].present?
        new_compliance_info.business_building_number =      compliance_params[:business_building_number]      if compliance_params[:business_building_number].present?
        new_compliance_info.business_street_address_kanji = compliance_params[:business_street_address_kanji] if compliance_params[:business_street_address_kanji].present?
        new_compliance_info.business_street_address_kana =  compliance_params[:business_street_address_kana]  if compliance_params[:business_street_address_kana].present?
        new_compliance_info.business_city =           compliance_params[:business_city]           if compliance_params[:business_city].present?
        new_compliance_info.business_state =          compliance_params[:business_state]          if compliance_params[:business_state].present?
        new_compliance_info.business_country =        Compliance::Countries.mapping[compliance_params[:business_country]] if compliance_params[:business_country].present? && compliance_params[:is_business]
        new_compliance_info.business_zip_code =       compliance_params[:business_zip_code]       if compliance_params[:business_zip_code].present?
        new_compliance_info.business_type =           compliance_params[:business_type]           if compliance_params[:business_type].present?
        new_compliance_info.is_business =             compliance_params[:is_business]             unless compliance_params[:is_business].nil?
        new_compliance_info.individual_tax_id =       compliance_params[:ssn_last_four]           if compliance_params[:ssn_last_four].present?
        new_compliance_info.individual_tax_id =       compliance_params[:individual_tax_id]       if compliance_params[:individual_tax_id].present?
        new_compliance_info.business_tax_id =         compliance_params[:business_tax_id]         if compliance_params[:business_tax_id].present?
        new_compliance_info.birthday = Date.new(compliance_params[:dob_year].to_i, compliance_params[:dob_month].to_i, compliance_params[:dob_day].to_i) if compliance_params[:dob_year].present? && compliance_params[:dob_year].to_i > 0
        new_compliance_info.skip_stripe_job_on_create = true
        new_compliance_info.phone =                   compliance_params[:phone]                   if compliance_params[:phone].present?
        new_compliance_info.business_phone =          compliance_params[:business_phone]          if compliance_params[:business_phone].present?
        new_compliance_info.job_title =               compliance_params[:job_title]               if compliance_params[:job_title].present?
        new_compliance_info.nationality =             compliance_params[:nationality]             if compliance_params[:nationality].present?
        new_compliance_info.business_vat_id_number =  compliance_params[:business_vat_id_number]  if compliance_params[:business_vat_id_number].present?
      end

      return { success: false, error_message: new_compliance_info.errors.full_messages.to_sentence } unless saved

      # Save guardian data to Guardian model if guardian params are present
      if has_guardian_params?
        guardian = user.guardian || user.build_guardian
        update_guardian(guardian)
        unless guardian.save
          return { success: false, error_message: guardian.errors.full_messages.to_sentence }
        end
      end

      begin
        StripeMerchantAccountManager.handle_new_user_compliance_info(new_compliance_info)

        # Handle all compliance info requests (including guardian fields)
        UserComplianceInfoRequest.handle_new_user_compliance_info(new_compliance_info)
      rescue Stripe::InvalidRequestError => e
        return { success: false, error_message: "Compliance info update failed with this error: #{e.message.split("Please contact us").first.strip}", error_code: "stripe_error" }
      end
    end

    { success: true }
  end

  private
    def has_guardian_params?
      guardian_fields = %i[
        guardian_first_name guardian_last_name guardian_email guardian_phone
        guardian_street_address guardian_city guardian_state guardian_zip_code
        guardian_country guardian_dob_year guardian_dob_month guardian_dob_day
        guardian_individual_tax_id guardian_ssn_last_four
      ]
      guardian_fields.any? { |field| compliance_params[field].present? }
    end

    def update_guardian(guardian)
      guardian.first_name = compliance_params[:guardian_first_name] if compliance_params[:guardian_first_name].present?
      guardian.last_name = compliance_params[:guardian_last_name] if compliance_params[:guardian_last_name].present?
      guardian.email = compliance_params[:guardian_email] if compliance_params[:guardian_email].present?
      guardian.phone = compliance_params[:guardian_phone] if compliance_params[:guardian_phone].present?
      guardian.street_address = compliance_params[:guardian_street_address] if compliance_params[:guardian_street_address].present?
      guardian.city = compliance_params[:guardian_city] if compliance_params[:guardian_city].present?
      guardian.state = compliance_params[:guardian_state] if compliance_params[:guardian_state].present?
      guardian.zip_code = compliance_params[:guardian_zip_code] if compliance_params[:guardian_zip_code].present?
      guardian.country = Compliance::Countries.mapping[compliance_params[:guardian_country]] if compliance_params[:guardian_country].present?

      if compliance_params[:guardian_dob_year].present? && compliance_params[:guardian_dob_month].present? && compliance_params[:guardian_dob_day].present?
        guardian.date_of_birth = Date.new(
          compliance_params[:guardian_dob_year].to_i,
          compliance_params[:guardian_dob_month].to_i,
          compliance_params[:guardian_dob_day].to_i
        )
      end

      guardian.individual_tax_id = compliance_params[:guardian_ssn_last_four] if compliance_params[:guardian_ssn_last_four].present?
      guardian.individual_tax_id = compliance_params[:guardian_individual_tax_id] if compliance_params[:guardian_individual_tax_id].present?

      if compliance_params[:guardian_stripe_tos_accepted].present?
        guardian.stripe_tos_accepted = ActiveModel::Type::Boolean.new.cast(compliance_params[:guardian_stripe_tos_accepted])
        guardian.stripe_tos_ip = remote_ip if remote_ip.present?
      end

      if compliance_params[:guardian_stripe_processing_tos_accepted].present?
        guardian.stripe_processing_tos_accepted = ActiveModel::Type::Boolean.new.cast(compliance_params[:guardian_stripe_processing_tos_accepted])
      end

      # Country-specific fields
      guardian.job_title = compliance_params[:guardian_job_title] if compliance_params[:guardian_job_title].present?
      guardian.nationality = compliance_params[:guardian_nationality] if compliance_params[:guardian_nationality].present?
      guardian.first_name_kanji = compliance_params[:guardian_first_name_kanji] if compliance_params[:guardian_first_name_kanji].present?
      guardian.last_name_kanji = compliance_params[:guardian_last_name_kanji] if compliance_params[:guardian_last_name_kanji].present?
      guardian.first_name_kana = compliance_params[:guardian_first_name_kana] if compliance_params[:guardian_first_name_kana].present?
      guardian.last_name_kana = compliance_params[:guardian_last_name_kana] if compliance_params[:guardian_last_name_kana].present?
      guardian.building_number = compliance_params[:guardian_building_number] if compliance_params[:guardian_building_number].present?
      guardian.street_address_kanji = compliance_params[:guardian_street_address_kanji] if compliance_params[:guardian_street_address_kanji].present?
      guardian.street_address_kana = compliance_params[:guardian_street_address_kana] if compliance_params[:guardian_street_address_kana].present?
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
