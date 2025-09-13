# frozen_string_literal: true

require "spec_helper"

describe Subscription, "automatic VAT refunds" do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }
  let(:subscription) { create(:subscription, link: product, user: buyer) }

  before do
    # Set up VAT rate for Germany
    create(:zip_tax_rate, country: "DE", combined_rate: 0.19, flags: 0)
    
    # Ensure original purchase exists with proper setup
    original_purchase = subscription.original_purchase
    original_purchase.update!(
      price_cents: 1000,
      gumroad_tax_cents: 190,
      country: "Germany",
      zip_code: "10115",
      state: "Berlin",
      ip_address: "85.88.1.1"
    )
  end

  describe "#apply_automatic_vat_refund" do
    context "when subscription has valid VAT ID" do
      let(:vat_id) { "DE123456789" }
      
      before do
        # Mock VAT validation to return true
        allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
        
        # Create original purchase with VAT ID
        original_purchase = subscription.original_purchase
        original_purchase.create_purchase_sales_tax_info!(
          business_vat_id: vat_id,
          country_code: "DE",
          postal_code: "10115",
          ip_address: "85.88.1.1"
        )
        original_purchase.update!(gumroad_tax_cents: 190) # 19% VAT on 1000 cents
      end

      it "automatically applies VAT refund for recurring charges" do
        # Create a recurring purchase (not original)
        recurring_purchase = create(:purchase, 
          subscription: subscription,
          link: product,
          is_original_subscription_purchase: false,
          gumroad_tax_cents: 190,
          state: "successful"
        )

        expect(recurring_purchase).to receive(:refund_gumroad_taxes!).with(
          refunding_user_id: nil,
          note: "Automatic VAT refund for recurring subscription with valid VAT ID",
          business_vat_id: vat_id
        )

        subscription.send(:apply_automatic_vat_refund, recurring_purchase)
      end

      it "does not apply VAT refund for original subscription purchase" do
        original_purchase = subscription.original_purchase
        original_purchase.is_original_subscription_purchase = true
        original_purchase.gumroad_tax_cents = 190
        original_purchase.state = "successful"

        expect(original_purchase).not_to receive(:refund_gumroad_taxes!)

        subscription.send(:apply_automatic_vat_refund, original_purchase)
      end

      it "does not apply VAT refund when purchase has no VAT" do
        recurring_purchase = subscription.build_purchase
        recurring_purchase.is_original_subscription_purchase = false
        recurring_purchase.gumroad_tax_cents = 0
        recurring_purchase.state = "successful"
        recurring_purchase.save!

        expect(recurring_purchase).not_to receive(:refund_gumroad_taxes!)

        subscription.send(:apply_automatic_vat_refund, recurring_purchase)
      end

      it "does not apply VAT refund when purchase is not successful" do
        recurring_purchase = subscription.build_purchase
        recurring_purchase.is_original_subscription_purchase = false
        recurring_purchase.gumroad_tax_cents = 190
        recurring_purchase.state = "failed"
        recurring_purchase.save!

        expect(recurring_purchase).not_to receive(:refund_gumroad_taxes!)

        subscription.send(:apply_automatic_vat_refund, recurring_purchase)
      end

      it "logs success when VAT refund is applied" do
        recurring_purchase = subscription.build_purchase
        recurring_purchase.is_original_subscription_purchase = false
        recurring_purchase.gumroad_tax_cents = 190
        recurring_purchase.state = "successful"
        recurring_purchase.save!

        allow(recurring_purchase).to receive(:refund_gumroad_taxes!).and_return(true)

        expect(Rails.logger).to receive(:info).with(
          "Applying automatic VAT refund for subscription #{subscription.external_id}, purchase #{recurring_purchase.external_id}"
        )
        expect(Rails.logger).to receive(:info).with(
          "Successfully applied automatic VAT refund for subscription #{subscription.external_id}, purchase #{recurring_purchase.external_id}"
        )

        subscription.send(:apply_automatic_vat_refund, recurring_purchase)
      end

      it "logs error and continues when VAT refund fails" do
        recurring_purchase = subscription.build_purchase
        recurring_purchase.is_original_subscription_purchase = false
        recurring_purchase.gumroad_tax_cents = 190
        recurring_purchase.state = "successful"
        recurring_purchase.save!

        error_message = "Refund failed"
        allow(recurring_purchase).to receive(:refund_gumroad_taxes!).and_raise(StandardError.new(error_message))

        expect(Rails.logger).to receive(:error).with(
          "Failed to apply automatic VAT refund for subscription #{subscription.external_id}, purchase #{recurring_purchase.external_id}: #{error_message}"
        )

        # Should not raise error
        expect { subscription.send(:apply_automatic_vat_refund, recurring_purchase) }.not_to raise_error
      end
    end

    context "when subscription has no VAT ID" do
      it "does not apply VAT refund" do
        recurring_purchase = subscription.build_purchase
        recurring_purchase.is_original_subscription_purchase = false
        recurring_purchase.gumroad_tax_cents = 190
        recurring_purchase.state = "successful"
        recurring_purchase.save!

        expect(recurring_purchase).not_to receive(:refund_gumroad_taxes!)

        subscription.send(:apply_automatic_vat_refund, recurring_purchase)
      end
    end

    context "when VAT ID is invalid" do
      let(:invalid_vat_id) { "INVALID123" }
      
      before do
        # Mock VAT validation to return false
        allow_any_instance_of(VatValidationService).to receive(:process).and_return(false)
        
        original_purchase = subscription.original_purchase
        original_purchase.create_purchase_sales_tax_info!(
          business_vat_id: invalid_vat_id,
          country_code: "DE",
          postal_code: "10115",
          ip_address: "85.88.1.1"
        )
      end

      it "does not apply VAT refund" do
        recurring_purchase = subscription.build_purchase
        recurring_purchase.is_original_subscription_purchase = false
        recurring_purchase.gumroad_tax_cents = 190
        recurring_purchase.state = "successful"
        recurring_purchase.save!

        expect(recurring_purchase).not_to receive(:refund_gumroad_taxes!)

        subscription.send(:apply_automatic_vat_refund, recurring_purchase)
      end
    end
  end

  describe "#has_valid_vat_id?" do
    let(:purchase) { subscription.build_purchase }

    context "with valid German VAT ID" do
      before do
        allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
        purchase.create_purchase_sales_tax_info!(
          business_vat_id: "DE123456789",
          country_code: "DE"
        )
      end

      it "returns true" do
        expect(subscription.send(:has_valid_vat_id?, purchase)).to be true
      end
    end

    context "with invalid VAT ID" do
      before do
        allow_any_instance_of(VatValidationService).to receive(:process).and_return(false)
        purchase.create_purchase_sales_tax_info!(
          business_vat_id: "INVALID",
          country_code: "DE"
        )
      end

      it "returns false" do
        expect(subscription.send(:has_valid_vat_id?, purchase)).to be false
      end
    end

    context "with no VAT ID" do
      before do
        purchase.create_purchase_sales_tax_info!(
          country_code: "DE"
        )
      end

      it "returns false" do
        expect(subscription.send(:has_valid_vat_id?, purchase)).to be false
      end
    end

    context "with no country code" do
      before do
        purchase.create_purchase_sales_tax_info!(
          business_vat_id: "DE123456789"
        )
      end

      it "returns false" do
        expect(subscription.send(:has_valid_vat_id?, purchase)).to be false
      end
    end
  end

  describe "#validate_vat_id_for_country" do
    context "for different countries" do
      it "uses VatValidationService for EU countries" do
        expect_any_instance_of(VatValidationService).to receive(:process).and_return(true)
        result = subscription.send(:validate_vat_id_for_country, "DE123456789", "DE")
        expect(result).to be true
      end

      it "uses AbnValidationService for Australia" do
        expect_any_instance_of(AbnValidationService).to receive(:process).and_return(true)
        result = subscription.send(:validate_vat_id_for_country, "12345678901", "AU")
        expect(result).to be true
      end

      it "uses GstValidationService for Singapore" do
        expect_any_instance_of(GstValidationService).to receive(:process).and_return(true)
        result = subscription.send(:validate_vat_id_for_country, "123456789F", "SG")
        expect(result).to be true
      end

      it "handles validation errors gracefully" do
        allow_any_instance_of(VatValidationService).to receive(:process).and_raise(StandardError.new("API error"))
        
        expect(Rails.logger).to receive(:error).with(/VAT ID validation failed/)
        
        result = subscription.send(:validate_vat_id_for_country, "DE123456789", "DE")
        expect(result).to be false
      end
    end
  end

  describe "integration with handle_purchase_success" do
    let(:vat_id) { "DE123456789" }
    
    before do
      allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
      
      original_purchase = subscription.original_purchase
      original_purchase.create_purchase_sales_tax_info!(
        business_vat_id: vat_id,
        country_code: "DE",
        postal_code: "10115",
        ip_address: "85.88.1.1"
      )
    end

    it "calls apply_automatic_vat_refund after successful purchase" do
      recurring_purchase = subscription.build_purchase
      recurring_purchase.is_original_subscription_purchase = false
      recurring_purchase.gumroad_tax_cents = 190
      recurring_purchase.state = "successful"
      recurring_purchase.save!

      expect(subscription).to receive(:apply_automatic_vat_refund).with(recurring_purchase)

      subscription.handle_purchase_success(recurring_purchase)
    end
  end
end
