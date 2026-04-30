# frozen_string_literal: true

class UpdatePayoutMethod
  include AfterCommitEverywhere

  attr_reader :params, :user

  BANK_ACCOUNT_TYPES = {
    AchAccount.name => { class: AchAccount, permitted_params: [:routing_number] },
    CanadianBankAccount.name => { class: CanadianBankAccount, permitted_params: %i[institution_number transit_number] },
    AustralianBankAccount.name => { class: AustralianBankAccount, permitted_params: [:bsb_number] },
    UkBankAccount.name => { class: UkBankAccount, permitted_params: [:sort_code] },
    EuropeanBankAccount.name => { class: EuropeanBankAccount, permitted_params: [] },
    HongKongBankAccount.name => { class: HongKongBankAccount, permitted_params: [:clearing_code, :branch_code] },
    NewZealandBankAccount.name => { class: NewZealandBankAccount, permitted_params: [] },
    SingaporeanBankAccount.name => { class: SingaporeanBankAccount, permitted_params: [:bank_code, :branch_code] },
    SwissBankAccount.name => { class: SwissBankAccount, permitted_params: [] },
    PolandBankAccount.name => { class: PolandBankAccount, permitted_params: [] },
    CzechRepublicBankAccount.name => { class: CzechRepublicBankAccount, permitted_params: [] },
    ThailandBankAccount.name => { class: ThailandBankAccount, permitted_params: [:bank_code] },
    BulgariaBankAccount.name => { class: BulgariaBankAccount, permitted_params: [] },
    DenmarkBankAccount.name => { class: DenmarkBankAccount, permitted_params: [] },
    HungaryBankAccount.name => { class: HungaryBankAccount, permitted_params: [] },
    KoreaBankAccount.name => { class: KoreaBankAccount, permitted_params: [:bank_code] },
    UaeBankAccount.name => { class: UaeBankAccount, permitted_params: [] },
    AntiguaAndBarbudaBankAccount.name => { class: AntiguaAndBarbudaBankAccount, permitted_params: [:bank_code] },
    TanzaniaBankAccount.name => { class: TanzaniaBankAccount, permitted_params: [:bank_code] },
    NamibiaBankAccount.name => { class: NamibiaBankAccount, permitted_params: [:bank_code] },
    IsraelBankAccount.name => { class: IsraelBankAccount, permitted_params: [] },
    TrinidadAndTobagoBankAccount.name => { class: TrinidadAndTobagoBankAccount, permitted_params: [:bank_code, :branch_code] },
    PhilippinesBankAccount.name => { class: PhilippinesBankAccount, permitted_params: [:bank_code] },
    RomaniaBankAccount.name => { class: RomaniaBankAccount, permitted_params: [] },
    SwedenBankAccount.name => { class: SwedenBankAccount, permitted_params: [] },
    MexicoBankAccount.name => { class: MexicoBankAccount, permitted_params: [] },
    ArgentinaBankAccount.name => { class: ArgentinaBankAccount, permitted_params: [] },
    LiechtensteinBankAccount.name => { class: LiechtensteinBankAccount, permitted_params: [] },
    PeruBankAccount.name => { class: PeruBankAccount, permitted_params: [] },
    NorwayBankAccount.name => { class: NorwayBankAccount, permitted_params: [] },
    IndianBankAccount.name => { class: IndianBankAccount, permitted_params: [:ifsc] },
    VietnamBankAccount.name => { class: VietnamBankAccount, permitted_params: [:bank_code] },
    TaiwanBankAccount.name => { class: TaiwanBankAccount, permitted_params: [:bank_code] },
    BosniaAndHerzegovinaBankAccount.name => { class: BosniaAndHerzegovinaBankAccount, permitted_params: [:bank_code] },
    IndonesiaBankAccount.name => { class: IndonesiaBankAccount, permitted_params: [:bank_code] },
    CostaRicaBankAccount.name => { class: CostaRicaBankAccount, permitted_params: [] },
    BotswanaBankAccount.name => { class: BotswanaBankAccount, permitted_params: [:bank_code] },
    ChileBankAccount.name => { class: ChileBankAccount, permitted_params: [:bank_code] },
    PakistanBankAccount.name => { class: PakistanBankAccount, permitted_params: [:bank_code] },
    TurkeyBankAccount.name => { class: TurkeyBankAccount, permitted_params: [:bank_code] },
    MoroccoBankAccount.name => { class: MoroccoBankAccount, permitted_params: [:bank_code] },
    AzerbaijanBankAccount.name => { class: AzerbaijanBankAccount, permitted_params: [:bank_code, :branch_code] },
    AlbaniaBankAccount.name => { class: AlbaniaBankAccount, permitted_params: [:bank_code] },
    BahrainBankAccount.name => { class: BahrainBankAccount, permitted_params: [:bank_code] },
    JordanBankAccount.name => { class: JordanBankAccount, permitted_params: [:bank_code] },
    EthiopiaBankAccount.name => { class: EthiopiaBankAccount, permitted_params: [:bank_code] },
    BruneiBankAccount.name => { class: BruneiBankAccount, permitted_params: [:bank_code] },
    GuyanaBankAccount.name => { class: GuyanaBankAccount, permitted_params: [:bank_code] },
    GuatemalaBankAccount.name => { class: GuatemalaBankAccount, permitted_params: [:bank_code] },
    NigeriaBankAccount.name => { class: NigeriaBankAccount, permitted_params: [:bank_code] },
    SerbiaBankAccount.name => { class: SerbiaBankAccount, permitted_params: [:bank_code] },
    SouthAfricaBankAccount.name => { class: SouthAfricaBankAccount, permitted_params: [:bank_code] },
    KenyaBankAccount.name => { class: KenyaBankAccount, permitted_params: [:bank_code] },
    RwandaBankAccount.name => { class: RwandaBankAccount, permitted_params: [:bank_code] },
    EgyptBankAccount.name => { class: EgyptBankAccount, permitted_params: [:bank_code] },
    ColombiaBankAccount.name => { class: ColombiaBankAccount, permitted_params: [:bank_code, :account_type] },
    SaudiArabiaBankAccount.name => { class: SaudiArabiaBankAccount, permitted_params: [:bank_code] },
    JapanBankAccount.name => { class: JapanBankAccount, permitted_params: [:bank_code, :branch_code] },
    KazakhstanBankAccount.name => { class: KazakhstanBankAccount, permitted_params: [:bank_code] },
    EcuadorBankAccount.name => { class: EcuadorBankAccount, permitted_params: [:bank_code] },
    MalaysiaBankAccount.name => { class: MalaysiaBankAccount, permitted_params: [:bank_code] },
    GibraltarBankAccount.name => { class: GibraltarBankAccount, permitted_params: [:sort_code] },
    UruguayBankAccount.name => { class: UruguayBankAccount, permitted_params: [:bank_code] },
    MauritiusBankAccount.name => { class: MauritiusBankAccount, permitted_params: [:bank_code] },
    AngolaBankAccount.name => { class: AngolaBankAccount, permitted_params: [:bank_code] },
    NigerBankAccount.name => { class: NigerBankAccount, permitted_params: [] },
    SanMarinoBankAccount.name => { class: SanMarinoBankAccount, permitted_params: [:bank_code] },
    JamaicaBankAccount.name => { class: JamaicaBankAccount, permitted_params: [:bank_code, :branch_code] },
    BangladeshBankAccount.name => { class: BangladeshBankAccount, permitted_params: [:bank_code] },
    BhutanBankAccount.name => { class: BhutanBankAccount, permitted_params: [:bank_code] },
    LaosBankAccount.name => { class: LaosBankAccount, permitted_params: [:bank_code] },
    MozambiqueBankAccount.name => { class: MozambiqueBankAccount, permitted_params: [:bank_code] },
    OmanBankAccount.name => { class: OmanBankAccount, permitted_params: [:bank_code] },
    DominicanRepublicBankAccount.name => { class: DominicanRepublicBankAccount, permitted_params: [:bank_code, :branch_code] },
    UzbekistanBankAccount.name => { class: UzbekistanBankAccount, permitted_params: [:bank_code, :branch_code] },
    BoliviaBankAccount.name => { class: BoliviaBankAccount, permitted_params: [:bank_code] },
    TunisiaBankAccount.name => { class: TunisiaBankAccount, permitted_params: [] },
    MoldovaBankAccount.name => { class: MoldovaBankAccount, permitted_params: [:bank_code] },
    NorthMacedoniaBankAccount.name => { class: NorthMacedoniaBankAccount, permitted_params: [:bank_code] },
    PanamaBankAccount.name => { class: PanamaBankAccount, permitted_params: [:bank_code] },
    ElSalvadorBankAccount.name => { class: ElSalvadorBankAccount, permitted_params: [:bank_code] },
    MadagascarBankAccount.name => { class: MadagascarBankAccount, permitted_params: [:bank_code] },
    ParaguayBankAccount.name => { class: ParaguayBankAccount, permitted_params: [:bank_code] },
    GhanaBankAccount.name => { class: GhanaBankAccount, permitted_params: [:bank_code] },
    ArmeniaBankAccount.name => { class: ArmeniaBankAccount, permitted_params: [:bank_code] },
    SriLankaBankAccount.name => { class: SriLankaBankAccount, permitted_params: [:bank_code, :branch_code] },
    KuwaitBankAccount.name => { class: KuwaitBankAccount, permitted_params: [:bank_code] },
    IcelandBankAccount.name => { class: IcelandBankAccount, permitted_params: [] },
    QatarBankAccount.name => { class: QatarBankAccount, permitted_params: [:bank_code] },
    BahamasBankAccount.name => { class: BahamasBankAccount, permitted_params: [:bank_code] },
    SaintLuciaBankAccount.name => { class: SaintLuciaBankAccount, permitted_params: [:bank_code] },
    SenegalBankAccount.name => { class: SenegalBankAccount, permitted_params: [] },
    CambodiaBankAccount.name => { class: CambodiaBankAccount, permitted_params: [:bank_code] },
    MongoliaBankAccount.name => { class: MongoliaBankAccount, permitted_params: [:bank_code] },
    GabonBankAccount.name => { class: GabonBankAccount, permitted_params: [:bank_code] },
    MonacoBankAccount.name => { class: MonacoBankAccount, permitted_params: [] },
    AlgeriaBankAccount.name => { class: AlgeriaBankAccount, permitted_params: [:bank_code] },
    MacaoBankAccount.name => { class: MacaoBankAccount, permitted_params: [:bank_code] },
    BeninBankAccount.name => { class: BeninBankAccount, permitted_params: [] },
    CoteDIvoireBankAccount.name => { class: CoteDIvoireBankAccount, permitted_params: [] },
  }.freeze
  private_constant :BANK_ACCOUNT_TYPES

  def self.bank_account_types
    BANK_ACCOUNT_TYPES
  end

  def initialize(user_params:, seller:)
    @params = user_params
    @user = seller
  end

  def process
    credit_card = nil
    baseline_active_bank_id = nil
    if params[:card]
      baseline_active_bank_id = user.active_bank_account&.id
      credit_card, error = prepare_credit_card
      return error if error
    end

    user.with_lock do
      if credit_card
        if user.active_bank_account&.id != baseline_active_bank_id
          discard_prepared_credit_card!(credit_card)
          next { error: :concurrent_payout_method_change }
        end
        process_card_params(credit_card)
      elsif bank_account_params_present?
        process_bank_account_params
      elsif params[:payment_address].present?
        process_payment_address_params
      else
        { success: true }
      end
    end
  rescue
    discard_prepared_credit_card!(credit_card) if credit_card
    raise
  end

  private
    def bank_account_params_present?
      params[:bank_account].present? &&
        params[:bank_account][:type].present? &&
        (params[:bank_account][:account_holder_full_name].present? || params[:bank_account][:account_number].present?)
    end

    def prepare_credit_card
      chargeable = ChargeProcessor.get_chargeable_for_params(params[:card], nil)
      return [nil, { error: :check_card_information_prompt }] if chargeable.nil?

      credit_card = CreditCard.create(chargeable)
      return [nil, { error: :credit_card_error, data: credit_card.errors.full_messages.to_sentence }] if credit_card.errors.present?

      [credit_card, nil]
    end

    def discard_prepared_credit_card!(credit_card)
      credit_card.destroy!
    end

    def process_card_params(credit_card)
      bank_account = CardBankAccount.new
      bank_account.user = user
      bank_account.credit_card = credit_card
      return bank_account_error_for(bank_account) unless bank_account.valid?

      replace_active_bank_account_with_validated_delete!(bank_account)
      user.update!(payment_address: "") if user.payment_address.present?
      { success: true }
    end

    def process_bank_account_params
      raise unless params[:bank_account][:type].in?(BANK_ACCOUNT_TYPES)

      if params[:bank_account][:account_number].present?
        process_full_bank_account_replacement
      elsif params[:bank_account][:account_holder_full_name].present?
        process_holder_name_update
      else
        { success: true }
      end
    end

    MAX_ENCRYPTED_FIELD_LENGTH = 200

    def process_full_bank_account_replacement
      account_number = params[:bank_account][:account_number].delete("-").strip
      account_number_confirmation = params[:bank_account][:account_number_confirmation].to_s.delete("-").strip
      return { error: :account_number_does_not_match } if account_number != account_number_confirmation
      return { error: :bank_account_error, data: "Account number is too long" } if account_number.length > MAX_ENCRYPTED_FIELD_LENGTH

      bank_account = BANK_ACCOUNT_TYPES[params[:bank_account][:type]][:class].new(bank_account_params_for_bank_account_type)
      bank_account.user = user
      bank_account.account_holder_full_name = params[:bank_account][:account_holder_full_name]
      bank_account.account_number = account_number
      bank_account.account_number_last_four = account_number.last(4)
      bank_account.account_type = params[:bank_account][:account_type] if params[:bank_account][:account_type].present?
      return bank_account_error_for(bank_account) unless bank_account.valid?

      replace_active_bank_account_with_unvalidated_delete!(bank_account)
      user.update!(payment_address: "") if user.payment_address.present?
      { success: true }
    end

    def process_holder_name_update
      current_active = user.active_bank_account
      return { success: true } if current_active.blank? || current_active.is_a?(CardBankAccount)

      submitted_holder_name = params[:bank_account][:account_holder_full_name].to_s.strip
      if current_active.account_holder_full_name == submitted_holder_name
        current_active.valid?
        return bank_account_error_for_attribute(current_active, :account_holder_full_name) if current_active.errors[:account_holder_full_name].any?
        return { success: true }
      end

      current_active.account_holder_full_name = params[:bank_account][:account_holder_full_name]
      return bank_account_error_for(current_active) unless current_active.valid?
      current_active.save!

      if StripeMerchantAccountManager.account_holder_name_synced_to_stripe?(user)
        after_commit { HandleNewBankAccountWorker.perform_in(5.seconds, current_active.id) }
      end
      { success: true }
    end

    def process_payment_address_params
      payment_address = params[:payment_address].strip

      return { error: :provide_valid_email_prompt } unless EmailFormatValidator.valid?(payment_address)
      return { error: :provide_ascii_only_email_prompt } unless payment_address.ascii_only?
      return { error: :paypal_payouts_not_supported } unless paypal_payouts_supported?

      user.payment_address = payment_address
      user.save!

      user.forfeit_unpaid_balance!(:payout_method_change)
      user.stripe_account&.delete_charge_processor_account!
      user.active_bank_account&.mark_deleted!
      user.user_compliance_info_requests.requested.find_each(&:mark_provided!)
      user.update!(payouts_paused_internally: false, payouts_paused_by: nil) if user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE && !user.flagged? && !user.suspended?

      after_commit { CheckPaymentAddressWorker.perform_async(user.id) }
      { success: true }
    end

    def replace_active_bank_account_with_validated_delete!(new_bank_account)
      user.bank_accounts.alive.each(&:mark_deleted!)
      new_bank_account.save!
      notify_if_unexpected_alive_bank_accounts(new_bank_account)
    end

    def replace_active_bank_account_with_unvalidated_delete!(new_bank_account)
      user.bank_accounts.alive.find_each do |bank_account|
        bank_account.deleted_at = Time.current
        bank_account.save!(validate: false)
      end
      new_bank_account.save!
      notify_if_unexpected_alive_bank_accounts(new_bank_account)
    end

    def notify_if_unexpected_alive_bank_accounts(new_bank_account)
      alive_bank_account_ids = user.bank_accounts.alive.pluck(:id)
      return if alive_bank_account_ids.one?

      message = "Unexpected alive bank account count after payout method update"
      Rails.logger.error("#{message} for user #{user.id}: #{alive_bank_account_ids.join(', ')}")
      ErrorNotifier.notify(message,
                           user_id: user.id,
                           alive_count: alive_bank_account_ids.count,
                           alive_bank_account_ids:,
                           new_bank_account_id: new_bank_account.id)
    end

    def bank_account_error_for(record)
      { error: :bank_account_error, data: record.errors.full_messages.to_sentence }
    end

    def bank_account_error_for_attribute(record, attribute)
      { error: :bank_account_error, data: record.errors.full_messages_for(attribute).to_sentence }
    end

    def bank_account_params_for_bank_account_type
      bank_account_type = params[:bank_account][:type]
      permitted_params = BANK_ACCOUNT_TYPES[bank_account_type][:permitted_params]
      params[:bank_account].permit(*permitted_params)
    end

    def paypal_payouts_supported?
      user.can_setup_paypal_payouts? || switching_to_uae_individual_account?
    end

    def switching_to_uae_individual_account?
      params.dig(:user, :country) == Compliance::Countries::ARE.alpha2 && !params.dig(:user, :is_business)
    end
end
