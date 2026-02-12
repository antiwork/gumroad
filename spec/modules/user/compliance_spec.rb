# frozen_string_literal: true

require "spec_helper"

describe User::Compliance do
  describe "native_payouts_supported?" do
    it "returns true for US, CA, AU, and UK creators" do
      %w(US CA AU GB).each do |country_code|
        creator = create(:user)
        create(:user_compliance_info_empty, user: creator, country: ISO3166::Country[country_code].common_name)
        expect(creator.native_payouts_supported?).to be true
      end
    end

    it "returns true for creators from EU, HK, NZ, SG, and CH" do
      country_codes = User::Compliance.european_countries.map(&:alpha2) + %w(HK NZ SG CH)
      country_codes.each do |country_code|
        creator = create(:user)
        create(:user_compliance_info_empty, user: creator, country: ISO3166::Country[country_code].common_name)
        expect(creator.native_payouts_supported?).to be true
      end
    end

    it "returns true for creators from BG, DK, and HU" do
      %w(BG DK HU).each do |country_code|
        creator = create(:user)
        create(:user_compliance_info_empty, user: creator, country: ISO3166::Country[country_code].common_name)
        expect(creator.native_payouts_supported?).to be true
      end
    end

    it "returns false for other countries" do
      venezuela_user = create(:user)
      create(:user_compliance_info_empty, user: venezuela_user, country: "Venezuela")

      expect(venezuela_user.native_payouts_supported?).to be false
    end

    it "accepts country_code as optional argument" do
      jordan_user = create(:user)
      create(:user_compliance_info_empty, user: jordan_user, country: "Jordan")

      expect(jordan_user.native_payouts_supported?(country_code: "US")).to be true
      expect(jordan_user.native_payouts_supported?(country_code: "RU")).to be false
    end
  end

  describe "signed_up_from_united_states?" do
    before do
      @us_user = create(:user)
      @user_compliance_info = create(:user_compliance_info_empty, user: @us_user,
                                                                  first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                                                  zip_code: "94107", country: "United States")
    end

    it "returns true if from the us" do
      expect(@us_user.signed_up_from_united_states?).to be true
      expect(@us_user.compliance_country_has_states?).to be true
    end
  end

  describe "signed_up_from_canada?" do
    before do
      @can_user = create(:user)
      @user_compliance_info = create(:user_compliance_info_empty, user: @can_user,
                                                                  first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                                                  zip_code: "94107", country: "Canada")
    end

    it "returns true if from canada" do
      expect(@can_user.signed_up_from_canada?).to be true
      expect(@can_user.compliance_country_has_states?).to be true
    end
  end

  describe "signed_up_from_united_kingdom?" do
    before do
      @uk_user = create(:user)
      @user_compliance_info = create(:user_compliance_info_empty, user: @uk_user,
                                                                  first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                                                  zip_code: "94107", country: "United Kingdom")
    end

    it "returns true if from united_kingdom" do
      expect(@uk_user.signed_up_from_united_kingdom?).to be true
      expect(@uk_user.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_australia?" do
    it "returns true if from australia" do
      au_creator = create(:user)
      create(:user_compliance_info_empty, user: au_creator, country: "Australia")
      expect(au_creator.signed_up_from_australia?).to be true
      expect(au_creator.compliance_country_has_states?).to be true
    end
  end

  describe "signed_up_from_hong_kong?" do
    it "returns true if from hong kong" do
      hk_creator = create(:user)
      create(:user_compliance_info_empty, user: hk_creator, country: "Hong Kong")
      expect(hk_creator.signed_up_from_hong_kong?).to be true
      expect(hk_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_singapore?" do
    it "returns true if from singapore" do
      sg_creator = create(:user)
      create(:user_compliance_info_empty, user: sg_creator, country: "Singapore")
      expect(sg_creator.signed_up_from_singapore?).to be true
      expect(sg_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_new_zealand?" do
    it "returns true if from new zealand" do
      nz_creator = create(:user)
      create(:user_compliance_info_empty, user: nz_creator, country: "New Zealand")
      expect(nz_creator.signed_up_from_new_zealand?).to be true
      expect(nz_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_switzerland?" do
    it "returns true if from switzerland" do
      ch_creator = create(:user)
      create(:user_compliance_info_empty, user: ch_creator, country: "Switzerland")
      expect(ch_creator.signed_up_from_switzerland?).to be true
      expect(ch_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_bulgaria?" do
    it "returns true if from bulgaria" do
      bg_creator = create(:user)
      create(:user_compliance_info_empty, user: bg_creator, country: "Bulgaria")
      expect(bg_creator.signed_up_from_bulgaria?).to be true
      expect(bg_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_denmark?" do
    it "returns true if from denmark" do
      dk_creator = create(:user)
      create(:user_compliance_info_empty, user: dk_creator, country: "Denmark")
      expect(dk_creator.signed_up_from_denmark?).to be true
      expect(dk_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_czechia?" do
    it "returns true if from Czech Republic" do
      cz_creator = create(:user)
      create(:user_compliance_info_empty, user: cz_creator, country: "Czech Republic")
      expect(cz_creator.signed_up_from_czechia?).to be true
      expect(cz_creator.compliance_country_has_states?).to be false
    end

    it "returns true if from Czechia" do
      cz_creator = create(:user)
      create(:user_compliance_info_empty, user: cz_creator, country: "Czechia")
      expect(cz_creator.signed_up_from_czechia?).to be true
      expect(cz_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_bulgaria?" do
    it "returns true if from hungary" do
      hu_creator = create(:user)
      create(:user_compliance_info_empty, user: hu_creator, country: "Hungary")
      expect(hu_creator.signed_up_from_hungary?).to be true
      expect(hu_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_south_korea?" do
    it "returns true if from Korea, Republic of" do
      kr_creator = create(:user)
      create(:user_compliance_info_empty, user: kr_creator, country: "Korea, Republic of")
      expect(kr_creator.signed_up_from_south_korea?).to be true
      expect(kr_creator.compliance_country_has_states?).to be false
    end

    it "returns true if from South Korea" do
      kr_creator = create(:user)
      create(:user_compliance_info_empty, user: kr_creator, country: "South Korea")
      expect(kr_creator.signed_up_from_south_korea?).to be true
      expect(kr_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_united_arab_emirates?" do
    it "returns true if from uae" do
      uae_creator = create(:user)
      create(:user_compliance_info_empty, user: uae_creator, country: "United Arab Emirates")
      expect(uae_creator.signed_up_from_united_arab_emirates?).to be true
      expect(uae_creator.compliance_country_has_states?).to be true
    end
  end

  describe "signed_up_from_israel?" do
    it "returns true if from israel" do
      il_creator = create(:user)
      create(:user_compliance_info_empty, user: il_creator, country: "Israel")
      expect(il_creator.signed_up_from_israel?).to be true
      expect(il_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_trinidad_and_tobago?" do
    it "returns true if from trinidad and tobago" do
      tt_creator = create(:user)
      create(:user_compliance_info_empty, user: tt_creator, country: "Trinidad and Tobago")
      expect(tt_creator.signed_up_from_trinidad_and_tobago?).to be true
      expect(tt_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_philippines?" do
    it "returns true if from philippines" do
      ph_creator = create(:user)
      create(:user_compliance_info_empty, user: ph_creator, country: "Philippines")
      expect(ph_creator.signed_up_from_philippines?).to be true
      expect(ph_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_argentina?" do
    it "returns true if from argentina" do
      ar_creator = create(:user)
      create(:user_compliance_info_empty, user: ar_creator, country: "Argentina")
      expect(ar_creator.signed_up_from_argentina?).to be true
      expect(ar_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_peru?" do
    it "returns true if from peru" do
      pe_creator = create(:user)
      create(:user_compliance_info_empty, user: pe_creator, country: "Peru")
      expect(pe_creator.signed_up_from_peru?).to be true
      expect(pe_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_europe?" do
    it "returns true if from one of the listed EU countries else false" do
      User::Compliance.european_countries.each do |eu_country|
        eu_creator = create(:user)
        create(:user_compliance_info_empty, user: eu_creator, country: eu_country.common_name)
        expect(eu_creator.signed_up_from_europe?).to be true
      end
      %w(US CA AU GB HK NZ SG CH IN).each do |non_eu_country_code|
        non_eu_creator = create(:user)
        create(:user_compliance_info_empty, user: non_eu_creator,
                                            country: ISO3166::Country[non_eu_country_code].common_name)
        expect(non_eu_creator.signed_up_from_europe?).to be false
      end
    end
  end

  describe "signed_up_from_romania?" do
    it "returns true if from romania" do
      creator = create(:user)
      create(:user_compliance_info_empty, user: creator, country: "Romania")
      expect(creator.signed_up_from_romania?).to be true
      expect(creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_sweden?" do
    it "returns true if from sweden" do
      creator = create(:user)
      create(:user_compliance_info_empty, user: creator, country: "Sweden")
      expect(creator.signed_up_from_sweden?).to be true
      expect(creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_mexico?" do
    it "returns true if from mexico" do
      creator = create(:user)
      create(:user_compliance_info_empty, user: creator, country: "Mexico")
      expect(creator.signed_up_from_mexico?).to be true
      expect(creator.compliance_country_has_states?).to be true
    end
  end

  describe "signed_up_from_india?" do
    it "returns true if from India" do
      in_creator = create(:user)
      create(:user_compliance_info_empty, user: in_creator, country: "India")
      expect(in_creator.signed_up_from_india?).to be true
      expect(in_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_pakistan?" do
    it "returns true if from Pakistan" do
      pk_creator = create(:user)
      create(:user_compliance_info_empty, user: pk_creator, country: "Pakistan")
      expect(pk_creator.signed_up_from_pakistan?).to be true
      expect(pk_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_turkiye?" do
    it "returns true if from Turkey" do
      tr_creator = create(:user)
      create(:user_compliance_info_empty, user: tr_creator, country: "Türkiye")
      expect(tr_creator.signed_up_from_turkiye?).to be true
      expect(tr_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_south_africa?" do
    it "returns true if from South Africa" do
      za_creator = create(:user)
      create(:user_compliance_info_empty, user: za_creator, country: "South Africa")
      expect(za_creator.signed_up_from_south_africa?).to be true
      expect(za_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_kenya?" do
    it "returns true if from Kenya" do
      ke_creator = create(:user)
      create(:user_compliance_info_empty, user: ke_creator, country: "Kenya")
      expect(ke_creator.signed_up_from_kenya?).to be true
      expect(ke_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_egypt?" do
    it "returns true if from Egypt" do
      eg_creator = create(:user)
      create(:user_compliance_info_empty, user: eg_creator, country: "Egypt")
      expect(eg_creator.signed_up_from_egypt?).to be true
      expect(eg_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_colombia?" do
    it "returns true if from Colombia" do
      co_creator = create(:user)
      create(:user_compliance_info_empty, user: co_creator, country: "Colombia")
      expect(co_creator.signed_up_from_colombia?).to be true
      expect(co_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_saudi_arabia?" do
    it "returns true if from Saudi Arabia" do
      sa_creator = create(:user)
      create(:user_compliance_info_empty, user: sa_creator, country: "Saudi Arabia")
      expect(sa_creator.signed_up_from_saudi_arabia?).to be true
      expect(sa_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_angola?" do
    it "returns true if from Angola" do
      ao_creator = create(:user)
      create(:user_compliance_info_empty, user: ao_creator, country: "Angola")
      expect(ao_creator.signed_up_from_angola?).to be true
      expect(ao_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_niger?" do
    it "returns true if from Niger" do
      ne_creator = create(:user)
      create(:user_compliance_info_empty, user: ne_creator, country: "Niger")
      expect(ne_creator.signed_up_from_niger?).to be true
      expect(ne_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_san_marino?" do
    it "returns true if from San Marino" do
      sm_creator = create(:user)
      create(:user_compliance_info_empty, user: sm_creator, country: "San Marino")
      expect(sm_creator.signed_up_from_san_marino?).to be true
      expect(sm_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_uruguay?" do
    it "returns true if from Uruguay" do
      uy_creator = create(:user)
      create(:user_compliance_info_empty, user: uy_creator, country: "Uruguay")
      expect(uy_creator.signed_up_from_uruguay?).to be true
      expect(uy_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_botswana?" do
    it "returns true if from Botswana" do
      bw_creator = create(:user)
      create(:user_compliance_info_empty, user: bw_creator, country: "Botswana")
      expect(bw_creator.signed_up_from_botswana?).to be true
      expect(bw_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_mauritius?" do
    it "returns true if from Mauritius" do
      mu_creator = create(:user)
      create(:user_compliance_info_empty, user: mu_creator, country: "Mauritius")
      expect(mu_creator.signed_up_from_mauritius?).to be true
      expect(mu_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_jamaica?" do
    it "returns true if from Jamaica" do
      jm_creator = create(:user)
      create(:user_compliance_info_empty, user: jm_creator, country: "Jamaica")
      expect(jm_creator.signed_up_from_jamaica?).to be true
      expect(jm_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_antigua_and_barbuda?" do
    it "returns true if from Antigua and Barbuda" do
      ag_creator = create(:user)
      create(:user_compliance_info_empty, user: ag_creator, country: "Antigua and Barbuda")
      expect(ag_creator.signed_up_from_antigua_and_barbuda?).to be true
      expect(ag_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_namibia?" do
    it "returns true if from Namibia" do
      na_creator = create(:user)
      create(:user_compliance_info_empty, user: na_creator, country: "Namibia")
      expect(na_creator.signed_up_from_namibia?).to be true
      expect(na_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_tanzania?" do
    it "returns true if from Tanzania" do
      tz_creator = create(:user)
      create(:user_compliance_info_empty, user: tz_creator, country: "Tanzania")
      expect(tz_creator.signed_up_from_tanzania?).to be true
      expect(tz_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_rwanda?" do
    it "returns true if from Rwanda" do
      rw_creator = create(:user)
      create(:user_compliance_info_empty, user: rw_creator, country: "Rwanda")
      expect(rw_creator.signed_up_from_rwanda?).to be true
      expect(rw_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_bangladesh?" do
    it "returns true if from Bangladesh" do
      bd_creator = create(:user)
      create(:user_compliance_info_empty, user: bd_creator, country: "Bangladesh")
      expect(bd_creator.signed_up_from_bangladesh?).to be true
      expect(bd_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_bhutan?" do
    it "returns true if from Bhutan" do
      bt_creator = create(:user)
      create(:user_compliance_info_empty, user: bt_creator, country: "Bhutan")
      expect(bt_creator.signed_up_from_bhutan?).to be true
      expect(bt_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_lao_people_s_democratic_republic?" do
    it "returns true if from Lao People's Democratic Republic" do
      la_creator = create(:user)
      create(:user_compliance_info_empty, user: la_creator, country: "Lao People's Democratic Republic")
      expect(la_creator.signed_up_from_lao_people_s_democratic_republic?).to be true
      expect(la_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_mozambique?" do
    it "returns true if from Mozambique" do
      mz_creator = create(:user)
      create(:user_compliance_info_empty, user: mz_creator, country: "Mozambique")
      expect(mz_creator.signed_up_from_mozambique?).to be true
      expect(mz_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_ethiopia?" do
    it "returns true if from Ethiopia" do
      et_creator = create(:user)
      create(:user_compliance_info_empty, user: et_creator, country: "Ethiopia")
      expect(et_creator.signed_up_from_ethiopia?).to be true
      expect(et_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_brunei_darussalam?" do
    it "returns true if from Brunei Darussalam" do
      bn_creator = create(:user)
      create(:user_compliance_info_empty, user: bn_creator, country: "Brunei Darussalam")
      expect(bn_creator.signed_up_from_brunei_darussalam?).to be true
      expect(bn_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_guyana?" do
    it "returns true if from Guyana" do
      gy_creator = create(:user)
      create(:user_compliance_info_empty, user: gy_creator, country: "Guyana")
      expect(gy_creator.signed_up_from_guyana?).to be true
      expect(gy_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_guatemala?" do
    it "returns true if from Guatemala" do
      gt_creator = create(:user)
      create(:user_compliance_info_empty, user: gt_creator, country: "Guatemala")
      expect(gt_creator.signed_up_from_guatemala?).to be true
      expect(gt_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_ecuador?" do
    it "returns true if from Ecuador" do
      ec_creator = create(:user)
      create(:user_compliance_info_empty, user: ec_creator, country: "Ecuador")
      expect(ec_creator.signed_up_from_ecuador?).to be true
      expect(ec_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_ghana?" do
    it "returns true if from Ghana" do
      gh_creator = create(:user)
      create(:user_compliance_info_empty, user: gh_creator, country: "Ghana")
      expect(gh_creator.signed_up_from_ghana?).to be true
      expect(gh_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_oman?" do
    it "returns true if from Oman" do
      om_creator = create(:user)
      create(:user_compliance_info_empty, user: om_creator, country: "Oman")
      expect(om_creator.signed_up_from_oman?).to be true
      expect(om_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_armenia?" do
    it "returns true if from Armenia" do
      am_creator = create(:user)
      create(:user_compliance_info_empty, user: am_creator, country: "Armenia")
      expect(am_creator.signed_up_from_armenia?).to be true
      expect(am_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_sri_lanka?" do
    it "returns true if from Sri Lanka" do
      lk_creator = create(:user)
      create(:user_compliance_info_empty, user: lk_creator, country: "Sri Lanka")
      expect(lk_creator.signed_up_from_sri_lanka?).to be true
      expect(lk_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_kuwait?" do
    it "returns true if from Kuwait" do
      kw_creator = create(:user)
      create(:user_compliance_info_empty, user: kw_creator, country: "Kuwait")
      expect(kw_creator.signed_up_from_kuwait?).to be true
      expect(kw_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_dominican_republic?" do
    it "returns true if from Dominican Republic" do
      do_creator = create(:user)
      create(:user_compliance_info_empty, user: do_creator, country: "Dominican Republic")
      expect(do_creator.signed_up_from_dominican_republic?).to be true
      expect(do_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_uzbekistan?" do
    it "returns true if from Uzbekistan" do
      uz_creator = create(:user)
      create(:user_compliance_info_empty, user: uz_creator, country: "Uzbekistan")
      expect(uz_creator.signed_up_from_uzbekistan?).to be true
      expect(uz_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_bolivia?" do
    it "returns true if from Bolivia" do
      bo_creator = create(:user)
      create(:user_compliance_info_empty, user: bo_creator, country: "Bolivia")
      expect(bo_creator.signed_up_from_bolivia?).to be true
      expect(bo_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_moldova?" do
    it "returns true if from Moldova" do
      md_creator = create(:user)
      create(:user_compliance_info_empty, user: md_creator, country: "Moldova")
      expect(md_creator.signed_up_from_moldova?).to be true
      expect(md_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_panama?" do
    it "returns true if from Panama" do
      pa_creator = create(:user)
      create(:user_compliance_info_empty, user: pa_creator, country: "Panama")
      expect(pa_creator.signed_up_from_panama?).to be true
      expect(pa_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_el_salvador?" do
    it "returns true if from El Salvador" do
      sv_creator = create(:user)
      create(:user_compliance_info_empty, user: sv_creator, country: "El Salvador")
      expect(sv_creator.signed_up_from_el_salvador?).to be true
      expect(sv_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_paraguay?" do
    it "returns true if from Paraguay" do
      py_creator = create(:user)
      create(:user_compliance_info_empty, user: py_creator, country: "Paraguay")
      expect(py_creator.signed_up_from_paraguay?).to be true
      expect(py_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_iceland?" do
    it "returns true if from Iceland" do
      is_creator = create(:user)
      create(:user_compliance_info_empty, user: is_creator, country: "Iceland")
      expect(is_creator.signed_up_from_iceland?).to be true
      expect(is_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_qatar?" do
    it "returns true if from Qatar" do
      qa_creator = create(:user)
      create(:user_compliance_info_empty, user: qa_creator, country: "Qatar")
      expect(qa_creator.signed_up_from_qatar?).to be true
      expect(qa_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_bahamas?" do
    it "returns true if from Bahamas" do
      bs_creator = create(:user)
      create(:user_compliance_info_empty, user: bs_creator, country: "Bahamas")
      expect(bs_creator.signed_up_from_bahamas?).to be true
      expect(bs_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_saint_lucia?" do
    it "returns true if from Saint Lucia" do
      lc_creator = create(:user)
      create(:user_compliance_info_empty, user: lc_creator, country: "Saint Lucia")
      expect(lc_creator.signed_up_from_saint_lucia?).to be true
      expect(lc_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_cambodia?" do
    it "returns true if from Cambodia" do
      kh_creator = create(:user)
      create(:user_compliance_info_empty, user: kh_creator, country: "Cambodia")
      expect(kh_creator.signed_up_from_cambodia?).to be true
      expect(kh_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_mongolia?" do
    it "returns true if from Mongolia" do
      mn_creator = create(:user)
      create(:user_compliance_info_empty, user: mn_creator, country: "Mongolia")
      expect(mn_creator.signed_up_from_mongolia?).to be true
      expect(mn_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_algeria?" do
    it "returns true if from Algeria" do
      al_creator = create(:user)
      create(:user_compliance_info_empty, user: al_creator, country: "Algeria")
      expect(al_creator.signed_up_from_algeria?).to be true
      expect(al_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_macao?" do
    it "returns true if from Macao" do
      mo_creator = create(:user)
      create(:user_compliance_info_empty, user: mo_creator, country: "Macao")
      expect(mo_creator.signed_up_from_macao?).to be true
      expect(mo_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_benin?" do
    it "returns true if from Benin" do
      bj_creator = create(:user)
      create(:user_compliance_info_empty, user: bj_creator, country: "Benin")
      expect(bj_creator.signed_up_from_benin?).to be true
      expect(bj_creator.compliance_country_has_states?).to be false
    end
  end

  describe "signed_up_from_cote_d_ivoire?" do
    it "returns true if from Cote d'Ivoire" do
      ci_creator = create(:user)
      create(:user_compliance_info_empty, user: ci_creator, country: "Cote d'Ivoire")
      expect(ci_creator.signed_up_from_cote_d_ivoire?).to be true
      expect(ci_creator.compliance_country_has_states?).to be false
    end
  end

  describe "compliance_country_code" do
    describe "user with an alive compliance info" do
      before do
        @uk_user = create(:user)
        @user_compliance_info = create(:user_compliance_info_empty, user: @uk_user,
                                                                    first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                                                    zip_code: "94107", country: "United Kingdom")
        create(:user_compliance_info_empty, user: @uk_user,
                                            first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                            zip_code: "94107", country: "Ireland", deleted_at: Time.current)
      end

      it "returns the country code of the currently active user compliance record" do
        expect(@uk_user.compliance_country_code).to eq(Compliance::Countries::GBR.alpha2)
      end
    end

    describe "user with no (alive) compliance info" do
      before do
        @uk_user = create(:user)
        @user_compliance_info = create(:user_compliance_info_empty, user: @uk_user,
                                                                    first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                                                    zip_code: "94107", country: "Ireland", deleted_at: Time.current)
      end

      it "returns the country code of the currently active user compliance record" do
        expect(@uk_user.compliance_country_code).to be(nil)
      end
    end

    describe "user with no compliance info" do
      before do
        @user = create(:user)
      end

      it "returns nil" do
        expect(@user.compliance_country_code).to be(nil)
      end
    end
  end
end
