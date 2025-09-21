# frozen_string_literal: true

module StripeMerchantAccountManager
  REQUESTED_CAPABILITIES = %w(card_payments transfers)
  CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES = %w(transfers)
  COUNTRIES_SUPPORTED_BY_STRIPE_CONNECT = ["Australia", "Austria", "Belgium", "Brazil", "Bulgaria", "Canada", "Croatia",
                                           "Cyprus", "Czechia", "Denmark", "Estonia", "Finland", "France",
                                           "Germany", "Gibraltar", "Greece", "Hong Kong", "Hungary", "Ireland", "Italy",
                                           "Japan", "Latvia", "Liechtenstein", "Lithuania", "Luxembourg",
                                           "Malta", "Netherlands", "New Zealand", "Norway", "Poland", "Portugal",
                                           "Romania", "Singapore", "Slovakia", "Slovenia", "Spain", "Sweden", "Switzerland",
                                           "United Arab Emirates", "United Kingdom", "United States"].map { |country_name| Compliance::Countries.find_by_name(country_name).alpha2 }

  # Use "CEO" as the default title for all Stripe custom connect account owners for now.
  DEFAULT_RELATIONSHIP_TITLE = "CEO"

  def self.create_account(user, passphrase:, from_admin: false)
    tos_agreement = nil
    user_compliance_info = nil
    bank_account = nil
    account_params = {}
    merchant_account = nil

    ActiveRecord::Base.connection.stick_to_primary!
    user.with_lock do
      raise MerchantRegistrationUserNotReadyError.new(user.id, "is not supported yet") unless user.native_payouts_supported?

      user_has_a_merchant_account = if from_admin
        user_has_stripe_connect_merchant_account?(user)
      else
        user.merchant_accounts.alive.stripe.find { |ma| !ma.is_a_stripe_connect_account? }.present?
      end
      raise MerchantRegistrationUserAlreadyHasAccountError.new(user.id, StripeChargeProcessor.charge_processor_id) if user_has_a_merchant_account
      raise MerchantRegistrationUserNotReadyError.new(user.id, "has not agreed to TOS") if user.tos_agreements.empty?

      tos_agreement = user.tos_agreements.last
      user_compliance_info = user.alive_user_compliance_info
      bank_account = user.active_bank_account

      country_code = user_compliance_info.legal_entity_country_code
      raise MerchantRegistrationUserNotReadyError.new(user.id, "does not have a legal entity country") if country_code.blank?
      country = Country.new(country_code)

      currency = country.payout_currency
      raise MerchantRegistrationUserNotReadyError.new(user.id, "has no default currency defined for it's legal entity's country") if currency.blank?

      # Stripe doesn't let us use non-USD bank accounts in the test environment, so we allow a USD bank account to be associated with a non-USD account
      # outside of production to facilitate testing and debugging.
      raise MerchantRegistrationUserNotReadyError.new(user.id, "has #{bank_account.type} #{bank_account.currency} that != #{country_code} #{currency}.") if Rails.env.production? && bank_account && bank_account.currency != currency

      capabilities = country.stripe_capabilities

      account_params = {
        type: "custom",
        requested_capabilities: capabilities,
        country: country_code,
        default_currency: currency
      }
      account_params.deep_merge!(account_hash(user, tos_agreement, user_compliance_info, passphrase:))
      account_params.deep_merge!(bank_account_hash(bank_account, passphrase:)) if bank_account && !bank_account.is_a?(CardBankAccount)

      merchant_account = MerchantAccount.create!(
        user:,
        country: country_code,
        currency:,
        charge_processor_id: StripeChargeProcessor.charge_processor_id
      )
    end

    stripe_account = Stripe::Account.create(account_params)

    merchant_account.charge_processor_merchant_id = stripe_account.id
    merchant_account.save!

    if user_compliance_info.is_business?
      person_params = person_hash(user_compliance_info, passphrase)
      person_params.deep_merge!(relationship: { representative: true, owner: true, title: user_compliance_info.job_title.presence || DEFAULT_RELATIONSHIP_TITLE, percent_ownership: 100 })
      Stripe::Account.create_person(stripe_account.id, person_params)
    end

    # We need to update with empty full_name_aliases here as setting full_name_aliases is mandatory for Singapore accounts.
    # It is a property on the `person` entity associated with the Stripe::Account.
    # Ref: https://stripe.com/docs/api/persons/object#person_object-full_name_aliases
    if user_compliance_info.country_code == Compliance::Countries::SGP.alpha2
      stripe_person = Stripe::Account.list_persons(stripe_account.id)["data"].last
      Stripe::Account.update_person(stripe_account.id, stripe_person.id, { full_name_aliases: [""] }) if stripe_person.present?
    end

    merchant_account.charge_processor_alive_at = Time.current
    merchant_account.save!

    # Non-Card bank accounts are saved at account creation time.
    #
    # Card bank accounts are saved when we are notified via account.updated event that charges are enabled on the account
    # because token generation fails unless charges are enabled.
    if bank_account && !bank_account.is_a?(CardBankAccount)
      save_stripe_bank_account_info(bank_account, stripe_account)
    end

    begin
      DefaultAbandonedCartWorkflowGeneratorService.new(seller: user).generate if merchant_account.is_a_stripe_connect_account?
    rescue => e
      Rails.logger.error("Failed to generate default abandoned cart workflow for user #{user.id}: #{e.message}")
      Bugsnag.notify(e)
    end

    merchant_account
  rescue Stripe::StripeError => e
    merchant_account.mark_deleted! if merchant_account.present? && merchant_account.charge_processor_merchant_id.blank?
    Bugsnag.notify(e)
    raise
  end

  def self.delete_account(merchant_account)
    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    result = stripe_account.delete
    if result.deleted
      merchant_account.charge_processor_deleted_at = Time.current
      merchant_account.save!
    end
    result.deleted
  end

  def self.update_account(user, passphrase:)
    validate_for_update(user)

    stripe_account = Stripe::Account.retrieve(user.stripe_account.charge_processor_merchant_id)
    last_user_compliance_info = UserComplianceInfo.find_by_external_id(stripe_account["metadata"]["user_compliance_info_id"])

    tos_agreement = user.tos_agreements.last
    user_compliance_info = user.alive_user_compliance_info

    last_attributes = account_hash(user, nil, last_user_compliance_info, passphrase:)
    current_attributes = account_hash(user, tos_agreement, user_compliance_info, passphrase:)
    last_attributes[:metadata] = {}
    last_attributes[:business_profile] = {}
    if user_compliance_info.is_business?
      last_attributes.delete(:individual)
      if last_attributes[:company].present? && user_compliance_info.country_code == Compliance::Countries::USA.alpha2
        last_attributes[:company][:structure] = nil
      end
      last_attributes.delete(:business_type) if user_compliance_info.country_code == Compliance::Countries::CAN.alpha2
    else
      last_attributes.delete(:company)
    end
    if last_attributes[:individual].present?
      last_attributes[:individual][:email] = nil
      last_attributes[:individual][:phone] = nil
      last_attributes[:individual][:relationship] = nil if user_compliance_info.country_code == Compliance::Countries::CAN.alpha2
    end
    if last_attributes[:company].present?
      last_attributes[:company][:directors_provided] = nil
      last_attributes[:company][:executives_provided] = nil
    end

    diff_attributes = get_diff_attributes(current_attributes, last_attributes)

    # If we have a full SSN, don't send the last 4 digits at the same time. If the last 4 digits are from a previous
    # compliance info and don't match the new full SSN, this will result in an invalid request.
    diff_attributes[:individual].delete(:ssn_last_4) if diff_attributes[:individual] && diff_attributes[:individual][:id_number].present?

    if user_compliance_info.is_individual? && diff_attributes[:individual][:dob].present?
      # Re-add the full DOB field if any part of it is being kept. Stripe handles this field inconsistently and the full DOB
      # must be submitted if any part of it is changing.
      diff_attributes[:individual][:dob] = current_attributes[:individual][:dob]
    end

    if last_user_compliance_info&.is_business? && user_compliance_info.is_individual?
      # Set the company's name to the individual's first and last name so that this is used as the Stripe account name and during payouts
      # Ref: https://github.com/gumroad/web/issues/19882
      diff_attributes[:company] = { name: user_compliance_info.first_and_last_name }
    end

    # Only set structure for US accounts
    if user_compliance_info.is_business? &&
      user_compliance_info.country_code == Compliance::Countries::USA.alpha2 &&
      user_compliance_info.business_type == UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP
      diff_attributes[:company] ||= {}
      diff_attributes[:company][:structure] = user_compliance_info.business_type
    end

    capabilities = Country.new(user_compliance_info.legal_entity_country_code).stripe_capabilities

    # Always request the capabilities assigned at account creation, plus any additional capabilities that the account already has (such as tax reporting
    # capability that we request "manually" for some accounts during tax season).
    capabilities = capabilities.map(&:to_sym) | stripe_account.capabilities.keys
    diff_attributes[:capabilities] = capabilities.index_with { |capability| { requested: true } }

    Stripe::Account.update(stripe_account.id, diff_attributes)

    if user_compliance_info.is_business?
      update_person(user, stripe_account, last_user_compliance_info&.external_id, passphrase)
    end
  end

  def self.update_person(user, stripe_account, last_user_compliance_info_id, passphrase)
    stripe_person = Stripe::Account.list_persons(stripe_account.id)["data"].last
    last_user_compliance_info = UserComplianceInfo.find_by_external_id(last_user_compliance_info_id)
    user_compliance_info = user.alive_user_compliance_info

    current_attributes = person_hash(user_compliance_info, passphrase)
    current_attributes.deep_merge!(relationship: { representative: true, owner: true, title: user_compliance_info.job_title.presence || DEFAULT_RELATIONSHIP_TITLE, percent_ownership: 100 })
    diff_attributes = current_attributes
    last_attributes = person_hash(last_user_compliance_info, passphrase)

    if last_attributes
      last_attributes[:email] = nil
      last_attributes[:phone] = nil
      diff_attributes = get_diff_attributes(current_attributes, last_attributes)
    end

    if diff_attributes[:dob].present?
      # Re-add the full DOB field if any part of it is being kept. Stripe handles this field inconsistently and the full DOB
      # must be submitted if any part of it is changing.
      diff_attributes[:dob] = current_attributes[:dob]
    end

    Stripe::Account.update_person(stripe_account.id, stripe_person.id, diff_attributes)
  end

  def self.get_diff_attributes(current_attributes, last_attributes)
    # Stripe will error if we send unchanged data for locked fields of a verified user.
    # To work around this, we send only attributes that are not in last_attributes or are different in current_attributes.
    # Attributes that are the same will be marked with the object, then removed after merging.
    reject_marker = Object.new
    diff_attributes = current_attributes.deep_merge(last_attributes) do |_key, current_value, last_value|
      if current_value == last_value
        reject_marker
      else
        current_value
      end
    end
    # Remove attributes that were marked for rejection, or are an empty hash.
    diff_attributes.deep_reject! do |_key, value|
      if value.is_a?(Hash)
        value.empty?
      else
        value == reject_marker
      end
    end
  end

  def self.update_bank_account(user, passphrase:)
    validate_for_update(user)

    bank_account = user.active_bank_account
    raise MerchantRegistrationUserNotReadyError.new(user.id, "does not have a bank account") if bank_account.nil?

    stripe_account = Stripe::Account.retrieve(user.stripe_account.charge_processor_merchant_id)
    return if stripe_account["metadata"]["bank_account_id"] == bank_account.external_id

    attributes = bank_account_hash(bank_account, stripe_account:, passphrase:)
    Stripe::Account.update(stripe_account.id, attributes)

    save_stripe_bank_account_info(bank_account, stripe_account.refresh)
  rescue Stripe::InvalidRequestError => e
    return ContactingCreatorMailer.invalid_bank_account(user.id).deliver_later(queue: "critical") if e.message["Invalid account number"] ||
                                                                            e.message["couldn't find that transit"] || e.message["previous attempts to deliver payouts"]

    Bugsnag.notify(e)
  rescue Stripe::CardError => e
    Rails.logger.error "Stripe::CardError request ID #{e.request_id} when updating bank account #{bank_account.id} for stripe account #{stripe_account.inspect}"

    raise e
  end

  def self.disconnect(user:)
    return false unless user.stripe_disconnect_allowed?

    user.stripe_connect_account.delete_charge_processor_account!
    user.check_merchant_account_is_linked = false
    user.save!

    # We deleted creator's gumroad-controlled Stripe account when they connected their own Stripe account.
    # Ref: User::OmniauthCallbacksController#stripe_connect.
    # Now when they are disconnecting their own Stripe account, we try and reactivate their old gumroad-controlled Stripe account.
    # Their old Stripe account is the one associated with any unpaid balance, or with their active bank account
    # as we didn't delete the active bank account when they connected their own Stripe account.
    stripe_account = user.merchant_accounts.stripe.where(id: user.unpaid_balances.pluck(:merchant_account_id).uniq).last
    stripe_account ||= user.merchant_accounts.stripe.where(charge_processor_merchant_id: user.active_bank_account&.stripe_connect_account_id).last
    return true if stripe_account.blank? || stripe_account.charge_processor_merchant_id.blank?
    stripe_account.deleted_at = stripe_account.charge_processor_deleted_at = nil
    stripe_account.charge_processor_alive_at = Time.current
    stripe_account.save!
  end

  private_class_method
  def self.save_stripe_bank_account_info(bank_account, stripe_account)
    # We replace the bank account whenever adding a new one, so there will only be one in the list.
    stripe_external_account = stripe_account.external_accounts.first
    bank_account.stripe_connect_account_id = stripe_account.id
    bank_account.stripe_external_account_id = stripe_external_account.id
    bank_account.stripe_fingerprint = stripe_external_account.fingerprint
    bank_account.save!
  end

  private_class_method
  def self.validate_for_update(user)
    unless user.stripe_account
      raise MerchantRegistrationUserNotReadyError
        .new(user.id, "does not have a Stripe merchant account")
    end
  end

  private_class_method
  def self.user_has_stripe_connect_merchant_account?(user)
    # It's really important we don't have two merchant accounts per user, so we do this check on the master database
    # to ensure we're looking at the latest data.
    ActiveRecord::Base.connection.stick_to_primary!
    user.stripe_account.present?
  end

  private_class_method
  def self.account_hash(user, tos_agreement, user_compliance_info, passphrase:)
    hash = {
      metadata: {
        user_id: user.external_id
      }
    }

    if tos_agreement
      tos_acceptance = {
        date: tos_agreement.created_at.to_time.to_i,
        ip: tos_agreement.ip
      }
      cross_border_payouts_only = Country.new(user_compliance_info.legal_entity_country_code).supports_stripe_cross_border_payouts?
      tos_acceptance[:service_agreement] = "recipient" if cross_border_payouts_only
      hash.deep_merge!(
        tos_acceptance:,
        metadata: {
          tos_agreement_id: tos_agreement.external_id
        }
      )
    end

    if user_compliance_info
      hash.deep_merge!(
        metadata: {
          user_compliance_info_id: user_compliance_info.external_id
        },
        business_type: if user_compliance_info.is_business?
                         if user_compliance_info.legal_entity_country_code == Compliance::Countries::CAN.alpha2 &&
                         %w(non_profit registered_charity).include?(user_compliance_info.business_type)
                           "non_profit"
                         else
                           "company"
                         end
                       else
                         "individual"
                       end,
        business_profile: {
          name: user_compliance_info.legal_entity_name,
          url: user.business_profile_url,
          product_description: user_compliance_info.legal_entity_name
        }
      )

      if [Compliance::Countries::ARE.alpha2, Compliance::Countries::CAN.alpha2].include?(user_compliance_info.country_code)
        hash[:business_profile][:support_phone] = user_compliance_info.business_phone
      end

      if user_compliance_info.is_business?
        hash.deep_merge!(company_hash(user_compliance_info, passphrase))
      else
        hash.deep_merge!(
          individual: person_hash(user_compliance_info, passphrase)
        )
      end
    end

    hash.deep_values_strip!
  end

  private_class_method
  def self.bank_account_hash(bank_account, stripe_account: {}, passphrase:)
    country_code = bank_account.user.alive_user_compliance_info.legal_entity_country_code
    cross_border_payouts_only = Country.new(country_code).supports_stripe_cross_border_payouts?

    bank_account_field =
      if bank_account.is_a?(CardBankAccount)
        Stripe::Token.create({ customer: bank_account.credit_card.stripe_customer_id }, { stripe_account: stripe_account["id"] }).id
      else
        bank_account_hash = {
          country: bank_account.country,
          currency: bank_account.currency,
          account_number: bank_account.account_number.decrypt(passphrase).gsub(/[ -]/, "")
        }
        bank_account_hash[:routing_number] = bank_account.routing_number if bank_account.routing_number.present?
        bank_account_hash[:account_type] = bank_account.account_type if [Compliance::Countries::CHL.alpha2, Compliance::Countries::COL.alpha2].include?(country_code) && bank_account.account_type.present?
        bank_account_hash[:account_holder_name] = bank_account.account_holder_full_name if [Compliance::Countries::JPN.alpha2, Compliance::Countries::VNM.alpha2, Compliance::Countries::IDN.alpha2].include?(country_code)
        bank_account_hash
      end

    settings = {
      payouts: {
        schedule: {
          interval: "manual"
        },
        debit_negative_balances: !cross_border_payouts_only
      }
    }

    metadata = stripe_account["metadata"].to_h || {}
    metadata[:bank_account_id] = bank_account.external_id

    attributes = {
      metadata:,
      # TODO replace `bank_account` with `external_account` (https://stripe.com/docs/upgrades#2015-10-01)
      # The `bank_account` is a deprecated field that continues to be supported, but the docs say it should
      # be renamed to `external_account`. Renaming the field causes a problem when calling `update_bank_account`
      # ("Cannot save property `external_account` containing an API resource. It doesn't appear to be persisted and is not marked as `save_with_parent`.")
      # Everything works well during account creation. Seems to be an issue with stripe ruby gem.
      bank_account: bank_account_field,
      settings:
    }
    attributes.deep_values_strip!
  end

  private_class_method
  def self.person_hash(user_compliance_info, passphrase)
    if user_compliance_info
      personal_tax_id = user_compliance_info.individual_tax_id.decrypt(passphrase)

      hash = {
        first_name: user_compliance_info.first_name,
        last_name: user_compliance_info.last_name,
        email: user_compliance_info.user.email,
        phone: user_compliance_info.phone,

        dob: {
          day: user_compliance_info.birthday.try(:day),
          month: user_compliance_info.birthday.try(:month),
          year: user_compliance_info.birthday.try(:year)
        }
      }

      if user_compliance_info.legal_entity_country_code == Compliance::Countries::CAN.alpha2
        hash.deep_merge!(relationship: { title: user_compliance_info.job_title.presence || DEFAULT_RELATIONSHIP_TITLE })
      end

      if user_compliance_info.country_code == Compliance::Countries::JPN.alpha2
        hash.deep_merge!({
                           first_name_kanji: user_compliance_info.first_name_kanji,
                           last_name_kanji: user_compliance_info.last_name_kanji,
                           first_name_kana: user_compliance_info.first_name_kana,
                           last_name_kana: user_compliance_info.last_name_kana,
                           address_kanji: {
                             line1: user_compliance_info.building_number,
                             line2: user_compliance_info.street_address_kanji,
                             postal_code: user_compliance_info.zip_code
                           },
                           address_kana: {
                             line1: user_compliance_info.building_number,
                             line2: user_compliance_info.street_address_kana,
                             postal_code: user_compliance_info.zip_code
                           }
                         })
      else
        hash.deep_merge!({
                           address: {
                             line1: user_compliance_info.street_address,
                             line2: nil,
                             city: user_compliance_info.city,
                             state: user_compliance_info.state,
                             postal_code: user_compliance_info.zip_code,
                             country: user_compliance_info.country_code
                           },
                         })
      end

      # For US accounts, only submit the Personal Tax ID if it's longer than four digits, otherwise the field contains the SSN Last 4.
      # For non-US accounts, always submit the Personal Tax ID.
      if personal_tax_id && (user_compliance_info.country_code != Compliance::Countries::USA.alpha2 || personal_tax_id.length > 4)
        hash.deep_merge!(id_number: personal_tax_id)
      end

      # For US accounts, only submit the SSN Last 4 if we have enough digits in the Tax ID to get the last 4.
      # For non-US accounts, never submit this field, it is for US accounts only.
      if user_compliance_info.country_code == Compliance::Countries::USA.alpha2 && personal_tax_id && personal_tax_id.length == 4
        hash.deep_merge!(ssn_last_4: personal_tax_id.last(4))
      end

      if [Compliance::Countries::ARE.alpha2,
          Compliance::Countries::SGP.alpha2,
          Compliance::Countries::BGD.alpha2,
          Compliance::Countries::PAK.alpha2].include?(user_compliance_info.country_code)
        hash.deep_merge!(nationality: user_compliance_info.nationality)
      end

      hash.deep_values_strip!
    end
  end

  def self.company_hash(user_compliance_info, passphrase)
    return unless user_compliance_info.present?

    business_tax_id = user_compliance_info.business_tax_id.decrypt(passphrase)
    hash = {
      company: {
        name: user_compliance_info.business_name.presence,
        address: {
          line1: user_compliance_info.legal_entity_street_address,
          line2: nil,
          city: user_compliance_info.legal_entity_city,
          state: user_compliance_info.legal_entity_state,
          postal_code: user_compliance_info.legal_entity_zip_code,
          country: user_compliance_info.legal_entity_country_code
        },
        tax_id: business_tax_id.presence,
        phone: user_compliance_info.business_phone,
        directors_provided: true,
        executives_provided: true,
      }
    }

    if user_compliance_info.country_code == Compliance::Countries::JPN.alpha2
      hash.deep_merge!({
                         company: {
                           name_kanji: user_compliance_info.business_name_kanji,
                           name_kana: user_compliance_info.business_name_kana,
                           address_kanji: {
                             line1: user_compliance_info.business_building_number,
                             line2: user_compliance_info.business_street_address_kanji,
                             postal_code: user_compliance_info.legal_entity_zip_code
                           },
                           address_kana: {
                             line1: user_compliance_info.business_building_number,
                             line2: user_compliance_info.business_street_address_kana,
                             postal_code: user_compliance_info.legal_entity_zip_code
                           }
                         }
                       })
    end

    if user_compliance_info.country_code == Compliance::Countries::ARE.alpha2
      hash.deep_merge!(
        company: {
          structure: user_compliance_info.business_type,
          vat_id: user_compliance_info.business_vat_id_number
        }
      )
    elsif user_compliance_info.legal_entity_country_code == Compliance::Countries::CAN.alpha2
      hash.deep_merge!(
        company: {
          structure: user_compliance_info.business_type == "non_profit" ? "" : user_compliance_info.business_type,
        }
      )
    elsif user_compliance_info.country_code == Compliance::Countries::USA.alpha2 && user_compliance_info.business_type == UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP
      hash[:company][:structure] = user_compliance_info.business_type
    end

    hash
  end

  def self.handle_stripe_event(stripe_event)
    case stripe_event["type"]
    when "account.updated"
      handle_stripe_event_account_updated(stripe_event)
    when "account.application.deauthorized"
      handle_stripe_event_account_deauthorized(stripe_event)
    when "capability.updated"
      handle_stripe_event_capability_updated(stripe_event)
    end
  end

  def self.handle_stripe_event_account_deauthorized(stripe_event)
    stripe_event_id = stripe_event["id"]
    stripe_account = stripe_event["data"] && stripe_event["data"]["object"]
    raise "Stripe Event #{stripe_event_id} does not contain an 'account' object." if stripe_event["type"] != "account.application.deauthorized" && (stripe_account && stripe_account["object"]) != "account"

    stripe_account_id = if stripe_event["type"] == "account.application.deauthorized"
      stripe_event["user_id"].present? ? stripe_event["user_id"] : stripe_event["account"]
    else
      stripe_account["id"]
    end

    merchant_account = MerchantAccount.where(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             charge_processor_merchant_id: stripe_account_id).alive.last

    return if merchant_account.nil?

    merchant_account.delete_charge_processor_account!

    user = merchant_account.user

    if user.merchant_migration_enabled?
      MerchantRegistrationMailer.account_deauthorized_to_user(
        user.id,
        StripeChargeProcessor.charge_processor_id
      ).deliver_later(queue: "critical")
    end
  end

  def self.handle_stripe_event_capability_updated(stripe_event)
    stripe_event_id = stripe_event["id"]
    stripe_capability = stripe_event["data"]["object"]
    stripe_previous_attributes = stripe_event["data"]["previous_attributes"] || {}
    raise "Stripe Event #{stripe_event_id} does not contain a 'capability' object." if stripe_capability["object"] != "capability"

    stripe_account_id = stripe_capability["account"]
    merchant_account = MerchantAccount.where(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             charge_processor_merchant_id: stripe_account_id)
                                      .alive.charge_processor_alive.last
    return unless merchant_account&.country == Compliance::Countries::JPN.alpha2

    stripe_account = Stripe::Account.retrieve(stripe_account_id)
    handle_stripe_info_requirements(stripe_event_id, stripe_account, stripe_previous_attributes)
  end

  def self.handle_stripe_event_account_updated(stripe_event)
    stripe_event_id = stripe_event["id"]
    stripe_account = stripe_event["data"]["object"]
    stripe_previous_attributes = stripe_event["data"]["previous_attributes"] || {}
    raise "Stripe Event #{stripe_event_id} does not contain an 'account' object." if stripe_account["object"] != "account"
    handle_stripe_info_requirements(stripe_event_id, stripe_account, stripe_previous_attributes)
  end

  def self.handle_stripe_info_requirements(stripe_event_id, stripe_account, stripe_previous_attributes)
    return if stripe_account["type"] == "standard"

    stripe_account_id = stripe_account["id"]

    merchant_account = MerchantAccount.where(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             charge_processor_merchant_id: stripe_account_id).last
    raise "No Merchant Account for Stripe Account ID #{stripe_account_id}" if merchant_account.nil?

    return unless merchant_account.alive?

    unless merchant_account.charge_processor_alive?
      Rails.logger.info "Merchant account #{merchant_account.id} not marked as alive in Stripe, ignoring event #{stripe_event_id}"
      return
    end

    user = merchant_account.user

    return unless user.account_active?

    requirements = stripe_account["requirements"] || {}
    future_requirements = stripe_account["future_requirements"] || {}

    if stripe_account["default_currency"] && stripe_account["country"]
      merchant_account.currency = stripe_account["default_currency"]
      merchant_account.country = stripe_account["country"]
      merchant_account.save!
    end

    individual = if stripe_account["business_type"] == "individual"
      stripe_account["individual"] || {}
    else
      Stripe::Account.list_persons(stripe_account_id, { limit: 1 }).first || {}
    end
    individual_verification_status = individual["verification"].try(:[], "status")
    merchant_account.mark_charge_processor_verified! if individual_verification_status == "verified"
    merchant_account.mark_charge_processor_unverified! if individual_verification_status == "unverified"

    deadline = if requirements["current_deadline"].present? && future_requirements["current_deadline"].present?
      [requirements["current_deadline"], future_requirements["current_deadline"]].min
    else
      requirements["current_deadline"].presence || future_requirements["current_deadline"]
    end
    requirements_due_at = Time.zone.at(deadline) if deadline.present?

    alternative_requirements = requirements["alternatives"]&.map { _1["alternative_fields_due"] } || []
    alternative_future_requirements = future_requirements["alternatives"]&.map { _1["alternative_fields_due"] } || []
    alternative_fields_due = (alternative_requirements + alternative_future_requirements).compact.reduce([], :+).uniq

    # future_requirements["eventually_due"] contains fields that will be needed sometime in the future,
    # we don't need to collect those currently. E.g. Full 9-digit SSN is required for a US account once it
    # $500k in payments, but Stripe shows that field under future_requirements["eventually_due"] for all US accounts.
    stripe_fields_needed = [requirements["currently_due"], requirements["eventually_due"], requirements["past_due"],
                            future_requirements["currently_due"], future_requirements["past_due"], alternative_fields_due].compact.reduce([], :+).uniq
    stripe_fields_needed.map! do |stripe_field_needed|
      # Example identity-related missing field for individual account: `individual.dob.day`
      # Example identity-related missing field for business account: `person_IRWHQ2ZRlwIh1j.dob.day`
      # Here we convert the `person_IRWHQ2ZRlwIh1j.dob.day` => `individual.dob.day` before using it as a lookup key
      stripe_field_needed.gsub(/^person_\w+\./, "individual.")
    end

    fields_needed = []
    verification_errors = {}
    stripe_risk_fields_needed = []

    stripe_fields_needed.each do |stripe_field_needed|
      field_needed = StripeUserComplianceInfoFieldMap.map(stripe_field_needed).presence || stripe_field_needed
      if stripe_field_needed.match?(/^interv_/)
        stripe_risk_fields_needed << stripe_field_needed
      else
        field_options = StripeUserComplianceInfoFieldMap.options_for_field(stripe_field_needed)
        fields_needed << [field_needed, field_options]
        field_error = requirements["errors"].find { |error| error["requirement"] == stripe_field_needed } if requirements["errors"].present?
        field_error ||= future_requirements["errors"].find { |error| error["requirement"] == stripe_field_needed } if future_requirements["errors"].present?
        verification_errors[field_needed] = { code: field_error["code"], reason: field_error["reason"] } if field_error.present?
      end
    end

    user.user_compliance_info_requests.requested.find_each do |user_compliance_info|
      still_needed = fields_needed.map { |name_and_options| name_and_options[0] }.include?(user_compliance_info.field_needed)
      still_needed ||= stripe_risk_fields_needed.include?(user_compliance_info.field_needed)
      user_compliance_info.mark_provided! unless still_needed
    end

    new_risk_requirement_added = false
    stripe_risk_fields_needed.each do |stripe_risk_field_needed|
      next if user.user_compliance_info_requests.requested.where(field_needed: stripe_risk_field_needed).present?

      risk_requirement_category = stripe_risk_field_needed.split(".")[1]

      if %w(rejection_appeal supportability_rejection_appeal).include?(risk_requirement_category)
        # Account not supportable under Stripe supportability.
        # Suspend the account and inform the creator via email.
        user.suspend_due_to_stripe_risk
      else
        # Some info/verification is required by Stripe for supportability.
        # Send a Stripe remediation link to the creator via email so they can submit the info.
        user_compliance_info_request = user.user_compliance_info_requests.build
        user_compliance_info_request.field_needed = stripe_risk_field_needed
        user_compliance_info_request.due_at = requirements_due_at
        user_compliance_info_request.stripe_event_id = stripe_event_id
        user_compliance_info_request.save!
        new_risk_requirement_added = true
      end
    end

    ContactingCreatorMailer.stripe_remediation(user.id).deliver_later if new_risk_requirement_added

    is_charges_disabled = !stripe_account["charges_enabled"]
    charges_newly_disabled = stripe_account["charges_enabled"] == false && stripe_previous_attributes["charges_enabled"] == true

    if user.active_bank_account.is_a?(CardBankAccount)
      card_account_needs_syncing = user.active_bank_account.stripe_connect_account_id.blank?

      if is_charges_disabled
        # Ignore request for card bank account until charges become enabled
        fields_needed.delete_if { |field_needed| field_needed[0] == UserComplianceInfoFields::BANK_ACCOUNT }
      elsif card_account_needs_syncing
        update_bank_account(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        if user.active_bank_account.stripe_connect_account_id.present?
          fields_needed.delete_if { |field_needed| field_needed[0] == UserComplianceInfoFields::BANK_ACCOUNT }
        end
      end
    end

    if charges_newly_disabled &&
      stripe_fields_needed.present? &&
      requirements["disabled_reason"].in?(%w(action_required.requested_capabilities requirements.past_due))
      MerchantRegistrationMailer.stripe_charges_disabled(user.id).deliver_later(queue: "critical")
    end

    if stripe_account["payouts_enabled"] && user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE
      user.update!(payouts_paused_internally: false, payouts_paused_by: nil)
    elsif stripe_account["payouts_enabled"] == false && !user.payouts_paused_internally?
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
      if stripe_fields_needed.present? && requirements["disabled_reason"].in?(%w(action_required.requested_capabilities requirements.past_due))
        MerchantRegistrationMailer.stripe_payouts_disabled(user.id).deliver_later
      end
    end

    last_outstanding_request_at = user.user_compliance_info_requests.requested.last&.created_at

    return if fields_needed.empty?

    new_requests = []
    fields_needed.each do |field_needed, options|
      only_needs_field_to_be_partially_provided = options[:only_needs_field_to_be_partially_provided]
      next if user.user_compliance_info_requests
                  .requested
                  .where(field_needed:)
                  .only_needs_field_to_be_partially_provided(only_needs_field_to_be_partially_provided)
                  .present?

      user_compliance_info_request = user.user_compliance_info_requests.build
      user_compliance_info_request.only_needs_field_to_be_partially_provided = only_needs_field_to_be_partially_provided
      user_compliance_info_request.field_needed = field_needed
      user_compliance_info_request.due_at = requirements_due_at
      user_compliance_info_request.stripe_event_id = stripe_event_id
      if verification_errors[field_needed].present?
        user_compliance_info_request.verification_error = verification_errors[field_needed]
      end
      user_compliance_info_request.save!
      new_requests << user_compliance_info_request
    end

    return if new_requests.blank? && last_outstanding_request_at.to_i > 1.month.ago.to_i

    all_fields_needed = user.user_compliance_info_requests.requested.where.not("field_needed like 'interv_%'").map(&:field_needed).uniq
    return if all_fields_needed.empty?

    document_verification_error = verification_errors.select { |_field, error| error[:code].starts_with?("verification_document") }.first
    email_sent = if document_verification_error.present?
      ContactingCreatorMailer.stripe_document_verification_failed(user.id, document_verification_error[1][:reason]).deliver_later(queue: "critical")
    elsif verification_errors.present?
      ContactingCreatorMailer.stripe_identity_verification_failed(user.id, verification_errors.first[1][:reason]).deliver_later(queue: "critical")
    else
      ContactingCreatorMailer.more_kyc_needed(user.id, all_fields_needed).deliver_later(queue: "critical")
    end

    if email_sent
      email_sent_at = Time.current
      new_requests.each { |request| request.record_email_sent!(email_sent_at) }
    end
  end

  def self.handle_new_user_compliance_info(user_compliance_info)
    return if user_compliance_info.user.has_stripe_account_connected?
    return unless user_has_stripe_connect_merchant_account?(user_compliance_info.user)

    update_account(user_compliance_info.user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
  end

  def self.handle_new_bank_account(bank_account)
    return if bank_account.user.has_stripe_account_connected?
    return unless user_has_stripe_connect_merchant_account?(bank_account.user)

    update_bank_account(bank_account.user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
  end
end
