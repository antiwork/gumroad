# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::LinksController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = {}
      @product1 = create(:product, user: @user, description: "des1", created_at: Time.current)
      @product2 = create(:product, user: @user, description: "des2", created_at: Time.current + 3600, purchase_disabled_at: Time.current + 3600)
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "returns the right response" do
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          products: [@product2, @product1]
        }.as_json(api_scopes: ["view_public"]))
      end
    end

    describe "when logged in with sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "returns the right response" do
        get @action, params: @params
        @product1.reload
        @product2.reload
        expect(response.parsed_body).to eq({ success: true, products: [@product2, @product1] }.as_json(api_scopes: ["view_sales"]))
      end
    end
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @params = { name: "Some product", url: "http://www.google.com", price: 200 }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @product = create(:product, user: @user, description: "des1", price_cents: 500)
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "returns a 404" do
        expect { post @action, params: @params }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "GET 'show'" do
    before do
      @product = create(:product, user: @user, description: "des1")

      @action = :show
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in without view_sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "returns the right response" do
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          product: @product
        }.as_json(api_scopes: ["edit_products"]))
      end

      describe "purchasing power parity", :vcr do
        before do
          UpdatePurchasingPowerParityFactorsWorker.new.perform
          @product.update!(price_cents: 1000)
          @user.update!(purchasing_power_parity_enabled: true)
        end

        it "includes the purchasing power parity prices" do
          @user.update!(purchasing_power_parity_limit: 50)
          get :show, params: @params
          expect(response.parsed_body["product"]["purchasing_power_parity_prices"]).to eq({ "AD" => 740, "AE" => 640, "AF" => 500, "AG" => 680, "AI" => 1000, "AL" => 500, "AM" => 500, "AO" => 1000, "AQ" => 1000, "AR" => 1000, "AS" => 1000, "AT" => 1000, "AU" => 1000, "AW" => 750, "AX" => 1000, "AZ" => 650, "BA" => 500, "BB" => 1000, "BD" => 500, "BE" => 1000, "BF" => 500, "BG" => 500, "BH" => 500, "BI" => 560, "BJ" => 500, "BL" => 1000, "BM" => 1000, "BN" => 500, "BO" => 500, "BQ" => 1000, "BR" => 1000, "BS" => 1000, "BT" => 500, "BV" => 1000, "BW" => 680, "BY" => 1000, "BZ" => 550, "CA" => 1000, "CC" => 1000, "CD" => 1000, "CF" => 500, "CG" => 500, "CH" => 1000, "CI" => 500, "CK" => 1000, "CL" => 1000, "CM" => 500, "CN" => 580, "CO" => 760, "CR" => 640, "CU" => 1000, "CV" => 550, "CW" => 690, "CX" => 1000, "CY" => 690, "CZ" => 620, "DE" => 1000, "DJ" => 500, "DK" => 1000, "DM" => 510, "DO" => 610, "DZ" => 570, "EC" => 500, "EE" => 690, "EG" => 790, "EH" => 1000, "ER" => 500, "ES" => 710, "ET" => 1000, "FI" => 1000, "FJ" => 500, "FK" => 1000, "FM" => 1000, "FO" => 1000, "FR" => 1000, "GA" => 500, "GB" => 1000, "GD" => 600, "GE" => 520, "GF" => 1000, "GG" => 1000, "GH" => 1000, "GI" => 1000, "GL" => 500, "GM" => 570, "GN" => 500, "GP" => 1000, "GQ" => 500, "GR" => 640, "GS" => 1000, "GT" => 500, "GU" => 1000, "GW" => 500, "GY" => 500, "HK" => 710, "HM" => 1000, "HN" => 580, "HR" => 530, "HT" => 1000, "HU" => 690, "ID" => 530, "IE" => 1000, "IL" => 1000, "IM" => 1000, "IN" => 500, "IO" => 1000, "IQ" => 500, "IR" => 1000, "IS" => 1000, "IT" => 740, "JE" => 1000, "JM" => 1000, "JO" => 500, "JP" => 1000, "KE" => 500, "KG" => 520, "KH" => 500, "KI" => 1000, "KM" => 500, "KN" => 670, "KP" => 500, "KR" => 700, "KW" => 720, "KY" => 1000, "KZ" => 1000, "LA" => 500, "LB" => 500, "LC" => 520, "LI" => 1000, "LK" => 760, "LR" => 500, "LS" => 720, "LT" => 600, "LU" => 1000, "LV" => 620, "LY" => 1000, "MA" => 500, "MC" => 1000, "MD" => 580, "ME" => 500, "MF" => 1000, "MG" => 550, "MH" => 1000, "MK" => 500, "ML" => 500, "MM" => 1000, "MN" => 790, "MO" => 580, "MP" => 1000, "MQ" => 1000, "MR" => 1000, "MS" => 1000, "MT" => 690, "MU" => 590, "MV" => 510, "MW" => 1000, "MX" => 710, "MY" => 500, "MZ" => 1000, "NA" => 1000, "NC" => 500, "NE" => 500, "NF" => 1000, "NG" => 1000, "NI" => 500, "NL" => 1000, "NO" => 1000, "NP" => 500, "NR" => 1000, "NU" => 1000, "NZ" => 1000, "OM" => 510, "PA" => 500, "PE" => 650, "PF" => 500, "PG" => 1000, "PH" => 500, "PK" => 620, "PL" => 540, "PM" => 1000, "PN" => 1000, "PR" => 770, "PS" => 500, "PT" => 640, "PW" => 1000, "PY" => 570, "QA" => 620, "RE" => 1000, "RO" => 520, "RS" => 540, "RU" => 1000, "RW" => 570, "SA" => 530, "SB" => 1000, "SC" => 560, "SD" => 1000, "SE" => 1000, "SG" => 620, "SH" => 1000, "SI" => 670, "SJ" => 1000, "SK" => 620, "SL" => 500, "SM" => 1000, "SN" => 500, "SO" => 1000, "SR" => 1000, "SS" => 1000, "ST" => 500, "SV" => 500, "SX" => 760, "SY" => 500, "SZ" => 730, "TC" => 1000, "TD" => 500, "TF" => 1000, "TG" => 500, "TH" => 500, "TJ" => 530, "TK" => 1000, "TL" => 500, "TM" => 510, "TN" => 580, "TO" => 570, "TR" => 1000, "TT" => 600, "TV" => 1000, "TW" => 1000, "TZ" => 500, "UA" => 1000, "UG" => 500, "UM" => 1000, "US" => 1000, "UY" => 1000, "UZ" => 1000, "VA" => 1000, "VC" => 520, "VE" => 1000, "VG" => 1000, "VI" => 1000, "VN" => 500, "VU" => 1000, "WF" => 1000, "WS" => 700, "YE" => 500, "YT" => 1000, "ZA" => 620, "ZM" => 1000, "ZW" => 1000, "XK" => 1000 })
        end

        it "excludes the purchasing power parity prices when disabled" do
          @product.update! purchasing_power_parity_disabled: true
          get :show, params: @params
          expect(response.parsed_body["product"]["purchasing_power_parity_prices"]).to eq(nil)
        end

        context "when the product is a versioned product" do
          let(:versioned_product) { create(:product_with_digital_versions, user: @user) }

          before do
            versioned_product.alive_variants.second.update!(price_difference_cents: 1000)
            @params[:id] = versioned_product.external_id
          end

          it "includes the purchasing power parity prices" do
            get :show, params: @params
            expect(response.parsed_body["product"]["variants"][0]["options"][0]["purchasing_power_parity_prices"])
              .to eq({
                       "AD" => 99, "AE" => 99, "AF" => 99, "AG" => 99, "AI" => 100, "AL" => 99, "AM" => 99, "AO" => 100, "AQ" => 100, "AR" => 100, "AS" => 100, "AT" => 100, "AU" => 100, "AW" => 99, "AX" => 100, "AZ" => 99, "BA" => 99, "BB" => 100, "BD" => 99, "BE" => 100, "BF" => 99, "BG" => 99, "BH" => 99, "BI" => 99, "BJ" => 99, "BL" => 100, "BM" => 100, "BN" => 99, "BO" => 99, "BQ" => 100, "BR" => 100, "BS" => 100, "BT" => 99, "BV" => 100, "BW" => 99, "BY" => 100, "BZ" => 99, "CA" => 100, "CC" => 100, "CD" => 100, "CF" => 99, "CG" => 99, "CH" => 100, "CI" => 99, "CK" => 100, "CL" => 100, "CM" => 99, "CN" => 99, "CO" => 99, "CR" => 99, "CU" => 100, "CV" => 99, "CW" => 99, "CX" => 100, "CY" => 99, "CZ" => 99, "DE" => 100, "DJ" => 99, "DK" => 100, "DM" => 99, "DO" => 99, "DZ" => 99, "EC" => 99, "EE" => 99, "EG" => 99, "EH" => 100, "ER" => 99, "ES" => 99, "ET" => 100, "FI" => 100, "FJ" => 99, "FK" => 100, "FM" => 100, "FO" => 100, "FR" => 100, "GA" => 99, "GB" => 100, "GD" => 99, "GE" => 99, "GF" => 100, "GG" => 100, "GH" => 100, "GI" => 100, "GL" => 99, "GM" => 99, "GN" => 99, "GP" => 100, "GQ" => 99, "GR" => 99, "GS" => 100, "GT" => 99, "GU" => 100, "GW" => 99, "GY" => 99, "HK" => 99, "HM" => 100, "HN" => 99, "HR" => 99, "HT" => 100, "HU" => 99, "ID" => 99, "IE" => 100, "IL" => 100, "IM" => 100, "IN" => 99, "IO" => 100, "IQ" => 99, "IR" => 100, "IS" => 100, "IT" => 99, "JE" => 100, "JM" => 100, "JO" => 99, "JP" => 100, "KE" => 99, "KG" => 99, "KH" => 99, "KI" => 100, "KM" => 99, "KN" => 99, "KP" => 99, "KR" => 99, "KW" => 99, "KY" => 100, "KZ" => 100, "LA" => 99, "LB" => 99, "LC" => 99, "LI" => 100, "LK" => 99, "LR" => 99, "LS" => 99, "LT" => 99, "LU" => 100, "LV" => 99, "LY" => 100, "MA" => 99, "MC" => 100, "MD" => 99, "ME" => 99, "MF" => 100, "MG" => 99, "MH" => 100, "MK" => 99, "ML" => 99, "MM" => 100, "MN" => 99, "MO" => 99, "MP" => 100, "MQ" => 100, "MR" => 100, "MS" => 100, "MT" => 99, "MU" => 99, "MV" => 99, "MW" => 100, "MX" => 99, "MY" => 99, "MZ" => 100, "NA" => 100, "NC" => 99, "NE" => 99, "NF" => 100, "NG" => 100, "NI" => 99, "NL" => 100, "NO" => 100, "NP" => 99, "NR" => 100, "NU" => 100, "NZ" => 100, "OM" => 99, "PA" => 99, "PE" => 99, "PF" => 99, "PG" => 100, "PH" => 99, "PK" => 99, "PL" => 99, "PM" => 100, "PN" => 100, "PR" => 99, "PS" => 99, "PT" => 99, "PW" => 100, "PY" => 99, "QA" => 99, "RE" => 100, "RO" => 99, "RS" => 99, "RU" => 100, "RW" => 99, "SA" => 99, "SB" => 100, "SC" => 99, "SD" => 100, "SE" => 100, "SG" => 99, "SH" => 100, "SI" => 99, "SJ" => 100, "SK" => 99, "SL" => 99, "SM" => 100, "SN" => 99, "SO" => 100, "SR" => 100, "SS" => 100, "ST" => 99, "SV" => 99, "SX" => 99, "SY" => 99, "SZ" => 99, "TC" => 100, "TD" => 99, "TF" => 100, "TG" => 99, "TH" => 99, "TJ" => 99, "TK" => 100, "TL" => 99, "TM" => 99, "TN" => 99, "TO" => 99, "TR" => 100, "TT" => 99, "TV" => 100, "TW" => 100, "TZ" => 99, "UA" => 100, "UG" => 99, "UM" => 100, "US" => 100, "UY" => 100, "UZ" => 100, "VA" => 100, "VC" => 99, "VE" => 100, "VG" => 100, "VI" => 100, "VN" => 99, "VU" => 100, "WF" => 100, "WS" => 99, "YE" => 99, "YT" => 100, "ZA" => 99, "ZM" => 100, "ZW" => 100, "XK" => 100
                     })
            expect(response.parsed_body["product"]["variants"][0]["options"][1]["purchasing_power_parity_prices"])
              .to eq({
                       "AD" => 814, "AE" => 704, "AF" => 440, "AG" => 748, "AI" => 1100, "AL" => 440, "AM" => 440, "AO" => 1100, "AQ" => 1100, "AR" => 1100, "AS" => 1100, "AT" => 1100, "AU" => 1100, "AW" => 825, "AX" => 1100, "AZ" => 715, "BA" => 473, "BB" => 1100, "BD" => 440, "BE" => 1100, "BF" => 440, "BG" => 528, "BH" => 506, "BI" => 616, "BJ" => 440, "BL" => 1100, "BM" => 1100, "BN" => 440, "BO" => 440, "BQ" => 1100, "BR" => 1100, "BS" => 1100, "BT" => 440, "BV" => 1100, "BW" => 748, "BY" => 1100, "BZ" => 605, "CA" => 1100, "CC" => 1100, "CD" => 1100, "CF" => 506, "CG" => 462, "CH" => 1100, "CI" => 451, "CK" => 1100, "CL" => 1100, "CM" => 440, "CN" => 638, "CO" => 836, "CR" => 704, "CU" => 1100, "CV" => 605, "CW" => 759, "CX" => 1100, "CY" => 759, "CZ" => 682, "DE" => 1100, "DJ" => 539, "DK" => 1100, "DM" => 561, "DO" => 671, "DZ" => 627, "EC" => 451, "EE" => 759, "EG" => 869, "EH" => 1100, "ER" => 440, "ES" => 781, "ET" => 1100, "FI" => 1100, "FJ" => 528, "FK" => 1100, "FM" => 1100, "FO" => 1100, "FR" => 1100, "GA" => 484, "GB" => 1100, "GD" => 660, "GE" => 572, "GF" => 1100, "GG" => 1100, "GH" => 1100, "GI" => 1100, "GL" => 440, "GM" => 627, "GN" => 451, "GP" => 1100, "GQ" => 495, "GR" => 704, "GS" => 1100, "GT" => 462, "GU" => 1100, "GW" => 440, "GY" => 440, "HK" => 781, "HM" => 1100, "HN" => 638, "HR" => 583, "HT" => 1100, "HU" => 759, "ID" => 583, "IE" => 1100, "IL" => 1100, "IM" => 1100, "IN" => 440, "IO" => 1100, "IQ" => 484, "IR" => 1100, "IS" => 1100, "IT" => 814, "JE" => 1100, "JM" => 1100, "JO" => 473, "JP" => 1100, "KE" => 550, "KG" => 572, "KH" => 440, "KI" => 1100, "KM" => 528, "KN" => 737, "KP" => 440, "KR" => 770, "KW" => 792, "KY" => 1100, "KZ" => 1100, "LA" => 539, "LB" => 440, "LC" => 572, "LI" => 1100, "LK" => 836, "LR" => 440, "LS" => 792, "LT" => 660, "LU" => 1100, "LV" => 682, "LY" => 1100, "MA" => 484, "MC" => 1100, "MD" => 638, "ME" => 484, "MF" => 1100, "MG" => 605, "MH" => 1100, "MK" => 440, "ML" => 440, "MM" => 1100, "MN" => 869, "MO" => 638, "MP" => 1100, "MQ" => 1100, "MR" => 1100, "MS" => 1100, "MT" => 759, "MU" => 649, "MV" => 561, "MW" => 1100, "MX" => 781, "MY" => 495, "MZ" => 1100, "NA" => 1100, "NC" => 440, "NE" => 440, "NF" => 1100, "NG" => 1100, "NI" => 550, "NL" => 1100, "NO" => 1100, "NP" => 451, "NR" => 1100, "NU" => 1100, "NZ" => 1100, "OM" => 561, "PA" => 517, "PE" => 715, "PF" => 440, "PG" => 1100, "PH" => 484, "PK" => 682, "PL" => 594, "PM" => 1100, "PN" => 1100, "PR" => 847, "PS" => 440, "PT" => 704, "PW" => 1100, "PY" => 627, "QA" => 682, "RE" => 1100, "RO" => 572, "RS" => 594, "RU" => 1100, "RW" => 627, "SA" => 583, "SB" => 1100, "SC" => 616, "SD" => 1100, "SE" => 1100, "SG" => 682, "SH" => 1100, "SI" => 737, "SJ" => 1100, "SK" => 682, "SL" => 440, "SM" => 1100, "SN" => 462, "SO" => 1100, "SR" => 1100, "SS" => 1100, "ST" => 440, "SV" => 473, "SX" => 836, "SY" => 440, "SZ" => 803, "TC" => 1100, "TD" => 473, "TF" => 1100, "TG" => 440, "TH" => 440, "TJ" => 583, "TK" => 1100, "TL" => 440, "TM" => 561, "TN" => 638, "TO" => 627, "TR" => 1100, "TT" => 660, "TV" => 1100, "TW" => 1100, "TZ" => 506, "UA" => 1100, "UG" => 550, "UM" => 1100, "US" => 1100, "UY" => 1100, "UZ" => 1100, "VA" => 1100, "VC" => 572, "VE" => 1100, "VG" => 1100, "VI" => 1100, "VN" => 440, "VU" => 1100, "WF" => 1100, "WS" => 770, "YE" => 440, "YT" => 1100, "ZA" => 682, "ZM" => 1100, "ZW" => 1100, "XK" => 1100
                     })
          end
        end

        context "when the product is a membership product" do
          let(:membership) { create(:membership_product_with_preset_tiered_pricing, user: @user) }

          before do
            @params[:id] = membership.external_id
          end

          it "includes the purchasing power parity prices" do
            get :show, params: @params
            expect(response.parsed_body["product"]["variants"][0]["options"][1]["recurrence_prices"]["monthly"]["purchasing_power_parity_prices"])
              .to eq({
                       "AD" => 370, "AE" => 320, "AF" => 200, "AG" => 340, "AI" => 500, "AL" => 200, "AM" => 200, "AO" => 500, "AQ" => 500, "AR" => 500, "AS" => 500, "AT" => 500, "AU" => 500, "AW" => 375, "AX" => 500, "AZ" => 325, "BA" => 215, "BB" => 500, "BD" => 200, "BE" => 500, "BF" => 200, "BG" => 240, "BH" => 230, "BI" => 280, "BJ" => 200, "BL" => 500, "BM" => 500, "BN" => 200, "BO" => 200, "BQ" => 500, "BR" => 500, "BS" => 500, "BT" => 200, "BV" => 500, "BW" => 340, "BY" => 500, "BZ" => 275, "CA" => 500, "CC" => 500, "CD" => 500, "CF" => 230, "CG" => 210, "CH" => 500, "CI" => 205, "CK" => 500, "CL" => 500, "CM" => 200, "CN" => 290, "CO" => 380, "CR" => 320, "CU" => 500, "CV" => 275, "CW" => 345, "CX" => 500, "CY" => 345, "CZ" => 310, "DE" => 500, "DJ" => 245, "DK" => 500, "DM" => 255, "DO" => 305, "DZ" => 285, "EC" => 205, "EE" => 345, "EG" => 395, "EH" => 500, "ER" => 200, "ES" => 355, "ET" => 500, "FI" => 500, "FJ" => 240, "FK" => 500, "FM" => 500, "FO" => 500, "FR" => 500, "GA" => 220, "GB" => 500, "GD" => 300, "GE" => 260, "GF" => 500, "GG" => 500, "GH" => 500, "GI" => 500, "GL" => 200, "GM" => 285, "GN" => 205, "GP" => 500, "GQ" => 225, "GR" => 320, "GS" => 500, "GT" => 210, "GU" => 500, "GW" => 200, "GY" => 200, "HK" => 355, "HM" => 500, "HN" => 290, "HR" => 265, "HT" => 500, "HU" => 345, "ID" => 265, "IE" => 500, "IL" => 500, "IM" => 500, "IN" => 200, "IO" => 500, "IQ" => 220, "IR" => 500, "IS" => 500, "IT" => 370, "JE" => 500, "JM" => 500, "JO" => 215, "JP" => 500, "KE" => 250, "KG" => 260, "KH" => 200, "KI" => 500, "KM" => 240, "KN" => 335, "KP" => 200, "KR" => 350, "KW" => 360, "KY" => 500, "KZ" => 500, "LA" => 245, "LB" => 200, "LC" => 260, "LI" => 500, "LK" => 380, "LR" => 200, "LS" => 360, "LT" => 300, "LU" => 500, "LV" => 310, "LY" => 500, "MA" => 220, "MC" => 500, "MD" => 290, "ME" => 220, "MF" => 500, "MG" => 275, "MH" => 500, "MK" => 200, "ML" => 200, "MM" => 500, "MN" => 395, "MO" => 290, "MP" => 500, "MQ" => 500, "MR" => 500, "MS" => 500, "MT" => 345, "MU" => 295, "MV" => 255, "MW" => 500, "MX" => 355, "MY" => 225, "MZ" => 500, "NA" => 500, "NC" => 200, "NE" => 200, "NF" => 500, "NG" => 500, "NI" => 250, "NL" => 500, "NO" => 500, "NP" => 205, "NR" => 500, "NU" => 500, "NZ" => 500, "OM" => 255, "PA" => 235, "PE" => 325, "PF" => 200, "PG" => 500, "PH" => 220, "PK" => 310, "PL" => 270, "PM" => 500, "PN" => 500, "PR" => 385, "PS" => 200, "PT" => 320, "PW" => 500, "PY" => 285, "QA" => 310, "RE" => 500, "RO" => 260, "RS" => 270, "RU" => 500, "RW" => 285, "SA" => 265, "SB" => 500, "SC" => 280, "SD" => 500, "SE" => 500, "SG" => 310, "SH" => 500, "SI" => 335, "SJ" => 500, "SK" => 310, "SL" => 200, "SM" => 500, "SN" => 210, "SO" => 500, "SR" => 500, "SS" => 500, "ST" => 200, "SV" => 215, "SX" => 380, "SY" => 200, "SZ" => 365, "TC" => 500, "TD" => 215, "TF" => 500, "TG" => 200, "TH" => 200, "TJ" => 265, "TK" => 500, "TL" => 200, "TM" => 255, "TN" => 290, "TO" => 285, "TR" => 500, "TT" => 300, "TV" => 500, "TW" => 500, "TZ" => 230, "UA" => 500, "UG" => 250, "UM" => 500, "US" => 500, "UY" => 500, "UZ" => 500, "VA" => 500, "VC" => 260, "VE" => 500, "VG" => 500, "VI" => 500, "VN" => 200, "VU" => 500, "WF" => 500, "WS" => 350, "YE" => 200, "YT" => 500, "ZA" => 310, "ZM" => 500, "ZW" => 500, "XK" => 500
                     })
            expect(response.parsed_body["product"]["variants"][0]["options"][0]["recurrence_prices"]["monthly"]["purchasing_power_parity_prices"])
              .to eq({
                       "AD" => 222, "AE" => 192, "AF" => 120, "AG" => 204, "AI" => 300, "AL" => 120, "AM" => 120, "AO" => 300, "AQ" => 300, "AR" => 300, "AS" => 300, "AT" => 300, "AU" => 300, "AW" => 225, "AX" => 300, "AZ" => 195, "BA" => 129, "BB" => 300, "BD" => 120, "BE" => 300, "BF" => 120, "BG" => 144, "BH" => 138, "BI" => 168, "BJ" => 120, "BL" => 300, "BM" => 300, "BN" => 120, "BO" => 120, "BQ" => 300, "BR" => 300, "BS" => 300, "BT" => 120, "BV" => 300, "BW" => 204, "BY" => 300, "BZ" => 165, "CA" => 300, "CC" => 300, "CD" => 300, "CF" => 138, "CG" => 126, "CH" => 300, "CI" => 123, "CK" => 300, "CL" => 300, "CM" => 120, "CN" => 174, "CO" => 228, "CR" => 192, "CU" => 300, "CV" => 165, "CW" => 207, "CX" => 300, "CY" => 207, "CZ" => 186, "DE" => 300, "DJ" => 147, "DK" => 300, "DM" => 153, "DO" => 183, "DZ" => 171, "EC" => 123, "EE" => 207, "EG" => 237, "EH" => 300, "ER" => 120, "ES" => 213, "ET" => 300, "FI" => 300, "FJ" => 144, "FK" => 300, "FM" => 300, "FO" => 300, "FR" => 300, "GA" => 132, "GB" => 300, "GD" => 180, "GE" => 156, "GF" => 300, "GG" => 300, "GH" => 300, "GI" => 300, "GL" => 120, "GM" => 171, "GN" => 123, "GP" => 300, "GQ" => 135, "GR" => 192, "GS" => 300, "GT" => 126, "GU" => 300, "GW" => 120, "GY" => 120, "HK" => 213, "HM" => 300, "HN" => 174, "HR" => 159, "HT" => 300, "HU" => 207, "ID" => 159, "IE" => 300, "IL" => 300, "IM" => 300, "IN" => 120, "IO" => 300, "IQ" => 132, "IR" => 300, "IS" => 300, "IT" => 222, "JE" => 300, "JM" => 300, "JO" => 129, "JP" => 300, "KE" => 150, "KG" => 156, "KH" => 120, "KI" => 300, "KM" => 144, "KN" => 201, "KP" => 120, "KR" => 210, "KW" => 216, "KY" => 300, "KZ" => 300, "LA" => 147, "LB" => 120, "LC" => 156, "LI" => 300, "LK" => 228, "LR" => 120, "LS" => 216, "LT" => 180, "LU" => 300, "LV" => 186, "LY" => 300, "MA" => 132, "MC" => 300, "MD" => 174, "ME" => 132, "MF" => 300, "MG" => 165, "MH" => 300, "MK" => 120, "ML" => 120, "MM" => 300, "MN" => 237, "MO" => 174, "MP" => 300, "MQ" => 300, "MR" => 300, "MS" => 300, "MT" => 207, "MU" => 177, "MV" => 153, "MW" => 300, "MX" => 213, "MY" => 135, "MZ" => 300, "NA" => 300, "NC" => 120, "NE" => 120, "NF" => 300, "NG" => 300, "NI" => 150, "NL" => 300, "NO" => 300, "NP" => 123, "NR" => 300, "NU" => 300, "NZ" => 300, "OM" => 153, "PA" => 141, "PE" => 195, "PF" => 120, "PG" => 300, "PH" => 132, "PK" => 186, "PL" => 162, "PM" => 300, "PN" => 300, "PR" => 231, "PS" => 120, "PT" => 192, "PW" => 300, "PY" => 171, "QA" => 186, "RE" => 300, "RO" => 156, "RS" => 162, "RU" => 300, "RW" => 171, "SA" => 159, "SB" => 300, "SC" => 168, "SD" => 300, "SE" => 300, "SG" => 186, "SH" => 300, "SI" => 201, "SJ" => 300, "SK" => 186, "SL" => 120, "SM" => 300, "SN" => 126, "SO" => 300, "SR" => 300, "SS" => 300, "ST" => 120, "SV" => 129, "SX" => 228, "SY" => 120, "SZ" => 219, "TC" => 300, "TD" => 129, "TF" => 300, "TG" => 120, "TH" => 120, "TJ" => 159, "TK" => 300, "TL" => 120, "TM" => 153, "TN" => 174, "TO" => 171, "TR" => 300, "TT" => 180, "TV" => 300, "TW" => 300, "TZ" => 138, "UA" => 300, "UG" => 150, "UM" => 300, "US" => 300, "UY" => 300, "UZ" => 300, "VA" => 300, "VC" => 156, "VE" => 300, "VG" => 300, "VI" => 300, "VN" => 120, "VU" => 300, "WF" => 300, "WS" => 210, "YE" => 120, "YT" => 300, "ZA" => 186, "ZM" => 300, "ZW" => 300, "XK" => 300
                     })
            expect(response.parsed_body["product"]["purchasing_power_parity_prices"].values.all? { _1 == 0 }).to eq(true)
          end
        end
      end
    end

    describe "when logged in with view_sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")
        @params.merge!(access_token: @token.token)
      end

      it "shows me my products" do
        get :show, params: @params
        expect(response.parsed_body["product"]).to eq(@product.as_json(api_scopes: ["view_sales"]))
      end

      it "includes deprecated `custom_delivery_url` attribute" do
        get :show, params: @params.merge(id: create(:product, user: @user).external_id)
        expect(response.parsed_body["product"]).to include("custom_delivery_url" => nil)
      end
    end
  end

  describe "PUT 'update'" do
    before do
      @product = create(:product, user: @user, description: "des1", filetype: "mp3", filegroup: "audio")
      @action = :update
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products and view_sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products view_sales")
        @params.merge!(access_token: @token.token)
      end

      it "returns a 404" do
        expect { put @action, params: @params.merge(description: "a real description") }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "PUT 'disable'" do
    before do
      @product = create(:product, user: @user, description: "des1")

      @action = :disable
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "returns the right response" do
        put @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          product: @product.reload
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "disables a product" do
        put @action, params: @params
        expect(@product.reload.purchase_disabled_at).to_not be(nil)
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]).to eq(@product.reload.as_json(api_scopes: ["edit_products"]))
      end
    end
  end

  describe "PUT 'enable'" do
    before do
      @product = create(:physical_product, user: @user, description: "des1")
      @action = :enable
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "returns the right response" do
        put @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          product: @product.reload
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "enables a product" do
        put @action, params: @params
        expect(@product.reload.purchase_disabled_at).to be(nil)
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]).to eq(@product.reload.as_json(api_scopes: ["edit_products"]))
      end
    end

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "does not publish a product if it violates existing universal offer_codes" do
        offer_code = create(:universal_offer_code, user: @user, amount_cents: 100)
        offer_code.update_column(:amount_cents, 50) # bypassing validation.

        post @action, params: @params
        expect(response.parsed_body).to eq({
          success: false,
          message: "An existing discount code puts the price of this product below the $0.99 minimum after discount."
        }.as_json)
      end

      it "enables a link" do
        put @action, params: @params
        expect(@product.reload.purchase_disabled_at).to be_nil
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]).to eq(@product.reload.as_json(api_scopes: ["edit_products"]))
      end

      context "when new account and no valid merchant account connected" do
        before do
          @user.check_merchant_account_is_linked = true
          @user.payment_address = nil
          @user.save!

          @product.update!(purchase_disabled_at: 1.day.ago)
        end

        it "does not publish the product" do
          put @action, params: @params

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["message"]).to eq("You must connect at least one payment method before you can publish this product for sale.")

          expect(@product.purchase_disabled_at).to_not be_nil
        end
      end

      context "when an unknown exception is raised" do
        before do
          @product.update!(purchase_disabled_at: 1.day.ago)

          allow_any_instance_of(Link).to receive(:publish!).and_raise("error")
        end

        it "sends a Bugsnag notification" do
          expect(Bugsnag).to receive(:notify).once

          put @action, params: @params
        end

        it "returns an error message" do
          put @action, params: @params

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["message"]).to eq("Something broke. We're looking into what happened. Sorry about this!")
        end

        it "does not publish the link" do
          put @action, params: @params

          expect(@product.purchase_disabled_at).to_not be_nil
        end
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @product = create(:product, user: @user, description: "des1")
      @action = :destroy
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "returns the right response" do
        delete @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          message: "The product was deleted successfully."
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "deletes a product" do
        delete @action, params: @params
        expect(@product.reload.deleted_at).to_not be(nil)
        expect(response.parsed_body["success"]).to be(true)
      end

      it "tells you if a product can't be found" do
        delete @action, params: { id: "NOT_REAL_TOKEN", access_token: @token.token }
        expect(response.parsed_body["success"]).to be(false)
      end
    end
  end
end
