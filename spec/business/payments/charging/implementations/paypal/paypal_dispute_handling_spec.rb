# frozen_string_literal: true

require "spec_helper"

describe PaypalChargeProcessor, :vcr do
  let(:paypal_auth_token) do
    "Bearer A21AAI9v6NTs3Y42Ufo-5Q-cskFZtTLkOodRO1uJQvdaWnsbiCt078vvzYnSy5X1gLFwGZIyhtT6D_EUZyyyp_YjB9CudeK7w"
  end

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product) }
  let(:charge) { create(:charge, purchase: purchase, charge_processor: "paypal", charge_processor_transaction_id: "PP-D-12345") }
  let(:dispute) { create(:dispute, disputable: charge) }
  let(:dispute_evidence) { create(:dispute_evidence, dispute: dispute) }

  before do
    allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return(paypal_auth_token)
  end

  describe "#fight_chargeback" do
    let(:paypal_charge_processor) { described_class.new }

    context "when dispute retrieval is successful" do
      before do
        mock_dispute_response = OpenStruct.new(
          status_code: 200,
          result: OpenStruct.new(
            status: "WAITING_FOR_BUYER_RESPONSE",
            dispute_id: "PP-D-12345"
          )
        )
        mock_appeal_response = OpenStruct.new(
          status_code: 200,
          result: OpenStruct.new(
            status: "UNDER_REVIEW",
            dispute_id: "PP-D-12345"
          )
        )

        paypal_rest_api = instance_double(PaypalRestApi)
        allow(paypal_rest_api).to receive(:successful_response?).and_return(true)
        allow(paypal_rest_api).to receive(:get_dispute).with("PP-D-12345").and_return(mock_dispute_response)
        allow(paypal_rest_api).to receive(:appeal_dispute).with("PP-D-12345", anything).and_return(mock_appeal_response)
        allow(PaypalRestApi).to receive(:new).and_return(paypal_rest_api)
      end

      it "successfully appeals the dispute" do
        result = paypal_charge_processor.fight_chargeback("PP-D-12345", dispute_evidence)
        expect(result.status).to eq("UNDER_REVIEW")
      end

      it "includes license key information in evidence if available" do
        license = create(:license, purchase: purchase, serial: "TEST-KEY-123", uses: 3)
        dispute_evidence.update!(license_key: license.serial, license_key_activation_count: license.uses)

        paypal_rest_api = instance_double(PaypalRestApi)
        allow(paypal_rest_api).to receive(:successful_response?).and_return(true)
        allow(paypal_rest_api).to receive(:get_dispute).and_return(
          OpenStruct.new(status_code: 200, result: OpenStruct.new(status: "WAITING_FOR_BUYER_RESPONSE"))
        )
        allow(paypal_rest_api).to receive(:appeal_dispute).with("PP-D-12345", anything) do |_, evidence|
          expect(evidence[:evidence_info][:license_key]).to eq("TEST-KEY-123")
          expect(evidence[:evidence_info][:license_key_activation_count]).to eq(3)
          OpenStruct.new(status_code: 200, result: OpenStruct.new(status: "UNDER_REVIEW"))
        end
        allow(PaypalRestApi).to receive(:new).and_return(paypal_rest_api)

        paypal_charge_processor.fight_chargeback("PP-D-12345", dispute_evidence)
      end
    end

    context "when dispute retrieval fails" do
      before do
        mock_error_response = OpenStruct.new(
          status_code: 404,
          result: OpenStruct.new(
            details: [{ description: "Dispute not found" }]
          )
        )

        paypal_rest_api = instance_double(PaypalRestApi)
        allow(paypal_rest_api).to receive(:successful_response?).and_return(false)
        allow(paypal_rest_api).to receive(:get_dispute).with("PP-D-12345").and_return(mock_error_response)
        allow(PaypalRestApi).to receive(:new).and_return(paypal_rest_api)
      end

      it "raises ChargeProcessorInvalidRequestError" do
        expect do
          paypal_charge_processor.fight_chargeback("PP-D-12345", dispute_evidence)
        end.to raise_error(ChargeProcessorInvalidRequestError, /Failed to retrieve PayPal dispute details/)
      end
    end

    context "when evidence submission fails" do
      before do
        mock_dispute_response = OpenStruct.new(
          status_code: 200,
          result: OpenStruct.new(
            status: "WAITING_FOR_BUYER_RESPONSE",
            dispute_id: "PP-D-12345"
          )
        )
        mock_error_response = OpenStruct.new(
          status_code: 400,
          result: OpenStruct.new(
            details: [{ description: "Invalid evidence format" }]
          )
        )

        paypal_rest_api = instance_double(PaypalRestApi)
        allow(paypal_rest_api).to receive(:successful_response?).and_return(true, false)
        allow(paypal_rest_api).to receive(:get_dispute).with("PP-D-12345").and_return(mock_dispute_response)
        allow(paypal_rest_api).to receive(:appeal_dispute).with("PP-D-12345", anything).and_return(mock_error_response)
        allow(PaypalRestApi).to receive(:new).and_return(paypal_rest_api)
      end

      it "raises ChargeProcessorInvalidRequestError" do
        expect do
          paypal_charge_processor.fight_chargeback("PP-D-12345", dispute_evidence)
        end.to raise_error(ChargeProcessorInvalidRequestError, /Failed to submit evidence for PayPal dispute/)
      end
    end
  end

  describe "#build_paypal_dispute_evidence" do
    let(:paypal_charge_processor) { described_class.new }

    it "builds evidence with customer information" do
      dispute_evidence.update!(
        customer_email: "customer@example.com",
        customer_name: "John Doe",
        billing_address: "123 Main St, City, State 12345",
        shipping_address: "123 Main St, City, State 12345"
      )

      evidence = paypal_charge_processor.send(:build_paypal_dispute_evidence, dispute_evidence)

      expect(evidence[:customer_email]).to eq("customer@example.com")
      expect(evidence[:customer_name]).to eq("John Doe")
      expect(evidence[:billing_address]).to eq("123 Main St, City, State 12345")
      expect(evidence[:shipping_address]).to eq("123 Main St, City, State 12345")
    end

    it "builds evidence with product information" do
      dispute_evidence.update!(
        product_description: "Test Product Description",
        reason_for_winning: "Customer activated the product multiple times"
      )

      evidence = paypal_charge_processor.send(:build_paypal_dispute_evidence, dispute_evidence)

      expect(evidence[:product_description]).to eq("Test Product Description")
      expect(evidence[:reason_for_winning]).to eq("Customer activated the product multiple times")
    end

    it "includes shipping tracking number if present" do
      dispute_evidence.update!(shipping_tracking_number: "1Z9999W99999999999")

      evidence = paypal_charge_processor.send(:build_paypal_dispute_evidence, dispute_evidence)

      expect(evidence[:shipping_tracking_number]).to eq("1Z9999W99999999999")
    end

    it "does not include shipping tracking number if not present" do
      dispute_evidence.update!(shipping_tracking_number: nil)

      evidence = paypal_charge_processor.send(:build_paypal_dispute_evidence, dispute_evidence)

      expect(evidence[:shipping_tracking_number]).to be_nil
    end
  end

  describe "#add_license_key_info" do
    let(:paypal_charge_processor) { described_class.new }

    context "when license key information is present" do
      it "adds license key and activation count to evidence" do
        dispute_evidence.update!(
          license_key: "TEST-KEY-123",
          license_key_activation_count: 5
        )

        evidence = {}
        paypal_charge_processor.send(:add_license_key_info, evidence, dispute_evidence)

        expect(evidence[:license_key]).to eq("TEST-KEY-123")
        expect(evidence[:license_key_activation_count]).to eq(5)
      end
    end

    context "when license key information is not present" do
      it "does not add license key information to evidence" do
        dispute_evidence.update!(
          license_key: nil,
          license_key_activation_count: nil
        )

        evidence = {}
        paypal_charge_processor.send(:add_license_key_info, evidence, dispute_evidence)

        expect(evidence[:license_key]).to be_nil
        expect(evidence[:license_key_activation_count]).to be_nil
      end
    end
  end

  describe ".handle_dispute_updated_event" do
    let(:event_info) do
      {
        "event_type" => "CUSTOMER.DISPUTE.UPDATED",
        "resource" => {
          "dispute_id" => "PP-D-12345",
          "status" => "UNDER_REVIEW",
          "dispute_amount" => {
            "currency_code" => "USD",
            "value" => "10.00"
          }
        }
      }
    end

    context "when dispute status changes" do
      it "logs the dispute update with dispute ID and new status" do
        expect(Rails.logger).to receive(:info).with("PayPal dispute updated: PP-D-12345 - Status: UNDER_REVIEW")
        
        described_class.handle_dispute_updated_event(event_info)
      end

      it "handles different dispute statuses" do
        event_info["resource"]["status"] = "WAITING_FOR_SELLER_RESPONSE"
        
        expect(Rails.logger).to receive(:info).with("PayPal dispute updated: PP-D-12345 - Status: WAITING_FOR_SELLER_RESPONSE")
        
        described_class.handle_dispute_updated_event(event_info)
      end

      it "handles RESOLVED status" do
        event_info["resource"]["status"] = "RESOLVED"
        
        expect(Rails.logger).to receive(:info).with("PayPal dispute updated: PP-D-12345 - Status: RESOLVED")
        
        described_class.handle_dispute_updated_event(event_info)
      end
    end

    context "when event structure is invalid" do
      it "raises ChargeProcessorError for missing resource" do
        invalid_event = event_info.dup
        invalid_event.delete("resource")
        
        expect do
          described_class.handle_dispute_updated_event(invalid_event)
        end.to raise_error(ChargeProcessorError, /undefined method `dig' for nil:NilClass/)
      end

      it "raises ChargeProcessorError for missing dispute_id" do
        invalid_event = event_info.dup
        invalid_event["resource"].delete("dispute_id")
        
        expect do
          described_class.handle_dispute_updated_event(invalid_event)
        end.to raise_error(ChargeProcessorError, /undefined method `dig' for nil:NilClass/)
      end

      it "raises ChargeProcessorError for missing status" do
        invalid_event = event_info.dup
        invalid_event["resource"].delete("status")
        
        expect do
          described_class.handle_dispute_updated_event(invalid_event)
        end.to raise_error(ChargeProcessorError, /undefined method `dig' for nil:NilClass/)
      end
    end

    context "when logging fails" do
      it "raises ChargeProcessorError with original error message" do
        allow(Rails.logger).to receive(:info).and_raise(StandardError.new("Logging failed"))
        
        expect do
          described_class.handle_dispute_updated_event(event_info)
        end.to raise_error(ChargeProcessorError, /Logging failed/)
      end
    end
  end

  describe ".handle_order_events" do
    let(:dispute_updated_event) do
      {
        "event_type" => "CUSTOMER.DISPUTE.UPDATED",
        "resource" => {
          "dispute_id" => "PP-D-12345",
          "status" => "UNDER_REVIEW"
        }
      }
    end

    let(:dispute_created_event) do
      {
        "event_type" => "CUSTOMER.DISPUTE.CREATED",
        "resource" => {
          "dispute_id" => "PP-D-12345",
          "status" => "WAITING_FOR_BUYER_RESPONSE"
        }
      }
    end

    let(:dispute_resolved_event) do
      {
        "event_type" => "CUSTOMER.DISPUTE.RESOLVED",
        "resource" => {
          "dispute_id" => "PP-D-12345",
          "status" => "RESOLVED"
        }
      }
    end

    it "routes CUSTOMER.DISPUTE.UPDATED events to handle_dispute_updated_event" do
      expect(described_class).to receive(:handle_dispute_updated_event).with(dispute_updated_event)
      
      described_class.handle_order_events(dispute_updated_event)
    end

    it "routes CUSTOMER.DISPUTE.CREATED events to handle_dispute_created_event" do
      expect(described_class).to receive(:handle_dispute_created_event).with(dispute_created_event)
      
      described_class.handle_order_events(dispute_created_event)
    end

    it "routes CUSTOMER.DISPUTE.RESOLVED events to handle_dispute_resolved_event" do
      expect(described_class).to receive(:handle_dispute_resolved_event).with(dispute_resolved_event)
      
      described_class.handle_order_events(dispute_resolved_event)
    end

    it "sticks to primary database" do
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!)
      
      described_class.handle_order_events(dispute_updated_event)
    end

    it "does nothing for unknown event types" do
      unknown_event = dispute_updated_event.dup
      unknown_event["event_type"] = "UNKNOWN.EVENT.TYPE"
      
      expect(described_class).not_to receive(:handle_dispute_updated_event)
      expect(described_class).not_to receive(:handle_dispute_created_event)
      expect(described_class).not_to receive(:handle_dispute_resolved_event)
      
      described_class.handle_order_events(unknown_event)
    end
  end
end

describe PaypalRestApi, :vcr do
  let(:paypal_auth_token) do
    "Bearer A21AAI9v6NTs3Y42Ufo-5Q-cskFZtTLkOodRO1uJQvdaWnsbiCt078vvzYnSy5X1gLFwGZIyhtT6D_EUZyyyp_YjB9CudeK7w"
  end

  before do
    allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return(paypal_auth_token)
  end

  describe "#get_dispute" do
    let(:paypal_rest_api) { described_class.new }

    it "makes a GET request to the disputes endpoint" do
      # This test would require VCR setup for actual PayPal API calls
      # For now, we'll test the request construction
      expect(paypal_rest_api).to receive(:new_request).with(path: "/v1/customer/disputes/PP-D-12345", verb: "GET")
      expect(paypal_rest_api).to receive(:execute_request)

      paypal_rest_api.get_dispute("PP-D-12345")
    end
  end

  describe "#appeal_dispute" do
    let(:paypal_rest_api) { described_class.new }
    let(:evidence) { { evidence_type: "OTHER", evidence_info: { notes: "Customer activated the product" } } }

    it "makes a POST request to the appeal endpoint" do
      expect(paypal_rest_api).to receive(:new_request).with(path: "/v1/customer/disputes/PP-D-12345/appeal", verb: "POST")
      expect(paypal_rest_api).to receive(:execute_request)

      paypal_rest_api.appeal_dispute("PP-D-12345", evidence)
    end

    it "sets the Prefer header" do
      request = double("request")
      allow(request).to receive(:headers=).and_return({})
      allow(request).to receive(:body=).and_return({})
      allow(paypal_rest_api).to receive(:new_request).and_return(request)
      allow(paypal_rest_api).to receive(:execute_request)

      paypal_rest_api.appeal_dispute("PP-D-12345", evidence)

      expect(request.headers).to have_key("Prefer")
      expect(request.headers["Prefer"]).to eq("return=representation")
    end
  end

  describe "#provide_evidence_for_dispute" do
    let(:paypal_rest_api) { described_class.new }
    let(:evidence) { { evidence_type: "OTHER", evidence_info: { notes: "Customer activated the product" } } }

    it "makes a POST request to the provide-evidence endpoint" do
      expect(paypal_rest_api).to receive(:new_request).with(path: "/v1/customer/disputes/PP-D-12345/provide-evidence", verb: "POST")
      expect(paypal_rest_api).to receive(:execute_request)

      paypal_rest_api.provide_evidence_for_dispute("PP-D-12345", evidence)
    end

    it "sets the Prefer header" do
      request = double("request")
      allow(request).to receive(:headers=).and_return({})
      allow(request).to receive(:body=).and_return({})
      allow(paypal_rest_api).to receive(:new_request).and_return(request)
      allow(paypal_rest_api).to receive(:execute_request)

      paypal_rest_api.provide_evidence_for_dispute("PP-D-12345", evidence)

      expect(request.headers).to have_key("Prefer")
      expect(request.headers["Prefer"]).to eq("return=representation")
    end
  end

  describe "#build_dispute_evidence" do
    let(:paypal_rest_api) { described_class.new }

    it "builds evidence with basic customer information" do
      evidence = {
        customer_email: "customer@example.com",
        customer_name: "John Doe",
        product_description: "Test Product"
      }

      result = paypal_rest_api.send(:build_dispute_evidence, evidence)

      expect(result[:evidence_type]).to eq("OTHER")
      expect(result[:evidence_info][:customer_email]).to eq("customer@example.com")
      expect(result[:evidence_info][:customer_name]).to eq("John Doe")
      expect(result[:evidence_info][:product_description]).to eq("Test Product")
    end

    it "includes license key information if present" do
      evidence = {
        license_key: "TEST-KEY-123",
        license_key_activation_count: 3
      }

      result = paypal_rest_api.send(:build_dispute_evidence, evidence)

      expect(result[:evidence_info][:license_key]).to eq("TEST-KEY-123")
      expect(result[:evidence_info][:license_key_activation_count]).to eq(3)
    end

    it "maps reason_for_winning to notes" do
      evidence = {
        reason_for_winning: "Customer activated the product multiple times"
      }

      result = paypal_rest_api.send(:build_dispute_evidence, evidence)

      expect(result[:evidence_info][:notes]).to eq("Customer activated the product multiple times")
    end

    it "maps shipping_tracking_number to tracking_number" do
      evidence = {
        shipping_tracking_number: "1Z9999W99999999999"
      }

      result = paypal_rest_api.send(:build_dispute_evidence, evidence)

      expect(result[:evidence_info][:tracking_number]).to eq("1Z9999W99999999999")
    end
  end
end
