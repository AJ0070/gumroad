# frozen_string_literal: true

require "spec_helper"

RSpec.describe Subscription::VatIdUpdateService, type: :service do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }
  let(:subscription) { create(:subscription, link: product, user: buyer) }
  let(:vat_id) { "DE123456789" }
  let(:service) { described_class.new(subscription, vat_id) }

  before do
    # Set up VAT rate for Germany
    create(:zip_tax_rate, country: "DE", combined_rate: 0.19, flags: 0)
    
    # Create original purchase with German address
    original_purchase = subscription.original_purchase
    original_purchase.update!(
      country: "Germany",
      zip_code: "10115",
      state: "Berlin",
      ip_address: "85.88.1.1",
      gumroad_tax_cents: 190
    )
  end

  describe "#call" do
    context "with valid inputs" do
      before do
        allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
      end

      it "returns true when successful" do
        expect(service.call).to be true
      end

      it "updates the original purchase sales tax info with VAT ID" do
        service.call
        
        subscription.original_purchase.reload
        expect(subscription.original_purchase.purchase_sales_tax_info.business_vat_id).to eq(vat_id)
      end

      it "creates sales tax info if it doesn't exist" do
        expect(subscription.original_purchase.purchase_sales_tax_info).to be_nil
        
        service.call
        
        subscription.original_purchase.reload
        sales_tax_info = subscription.original_purchase.purchase_sales_tax_info
        expect(sales_tax_info).to be_present
        expect(sales_tax_info.business_vat_id).to eq(vat_id)
        expect(sales_tax_info.country_code).to eq("DE")
      end

      it "logs the VAT ID update" do
        expect(Rails.logger).to receive(:info).with(
          "Updated VAT ID for subscription #{subscription.external_id} to #{vat_id}"
        )
        
        service.call
      end

      context "when there are recent eligible purchases for retroactive refunds" do
        let!(:recent_purchase) do
          create(:purchase, 
            subscription: subscription,
            is_original_subscription_purchase: false,
            gumroad_tax_cents: 190,
            state: "successful",
            created_at: 15.days.ago
          )
        end

        it "applies retroactive refunds to eligible purchases" do
          expect(Rails.logger).to receive(:info).with(
            "Applying retroactive VAT refunds for subscription #{subscription.external_id}"
          )
          expect(Rails.logger).to receive(:info).with(
            "Applied retroactive VAT refund for purchase #{recent_purchase.external_id}"
          )
          
          expect(recent_purchase).to receive(:refund_gumroad_taxes!).with(
            refunding_user_id: nil,
            note: "Retroactive VAT refund after VAT ID update for subscription",
            business_vat_id: vat_id
          )
          
          service.call
        end

        it "continues with other purchases if one refund fails" do
          let!(:another_purchase) do
            create(:purchase, 
              subscription: subscription,
              is_original_subscription_purchase: false,
              gumroad_tax_cents: 190,
              state: "successful",
              created_at: 10.days.ago
            )
          end

          allow(recent_purchase).to receive(:refund_gumroad_taxes!).and_raise(StandardError.new("Refund failed"))
          expect(another_purchase).to receive(:refund_gumroad_taxes!)
          
          expect(Rails.logger).to receive(:error).with(
            "Failed to apply retroactive VAT refund for purchase #{recent_purchase.external_id}: Refund failed"
          )
          
          service.call
        end

        it "does not apply retroactive refunds to purchases that already have VAT refunds" do
          # Create a refund for the purchase
          create(:refund, purchase: recent_purchase, gumroad_tax_cents: 190)
          
          expect(recent_purchase).not_to receive(:refund_gumroad_taxes!)
          
          service.call
        end

        it "does not apply retroactive refunds to old purchases (>30 days)" do
          old_purchase = create(:purchase, 
            subscription: subscription,
            is_original_subscription_purchase: false,
            gumroad_tax_cents: 190,
            state: "successful",
            created_at: 45.days.ago
          )
          
          expect(old_purchase).not_to receive(:refund_gumroad_taxes!)
          
          service.call
        end
      end
    end

    context "with invalid inputs" do
      it "returns false when subscription is nil" do
        service = described_class.new(nil, vat_id)
        expect(service.call).to be false
        expect(service.errors).to include("Subscription is required")
      end

      it "returns false when subscription is inactive" do
        subscription.update!(deactivated_at: 1.day.ago)
        expect(service.call).to be false
        expect(service.errors).to include("Cannot update VAT ID for inactive subscription")
      end

      it "returns false when VAT ID is blank" do
        service = described_class.new(subscription, "")
        expect(service.call).to be false
        expect(service.errors).to include("VAT ID is required")
      end

      it "returns false when VAT ID is invalid" do
        allow_any_instance_of(VatValidationService).to receive(:process).and_return(false)
        expect(service.call).to be false
        expect(service.errors).to include("Invalid VAT ID for country DE")
      end

      it "returns false when country code cannot be determined" do
        subscription.original_purchase.update!(country: nil)
        expect(service.call).to be false
        expect(service.errors).to include("Cannot determine country for VAT ID validation")
      end
    end

    context "when an error occurs during update" do
      before do
        allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
        allow_any_instance_of(ActiveRecord::Base).to receive(:transaction).and_raise(StandardError.new("Database error"))
      end

      it "returns false and logs the error" do
        expect(Rails.logger).to receive(:error).with(
          "Failed to update VAT ID for subscription #{subscription.external_id}: Database error"
        )
        
        expect(service.call).to be false
        expect(service.errors).to include("Failed to update VAT ID: Database error")
      end
    end
  end

  describe "VAT ID validation for different countries" do
    context "for Australia" do
      before do
        subscription.original_purchase.update!(country: "Australia")
        subscription.original_purchase.create_purchase_sales_tax_info!(country_code: "AU")
      end

      it "uses AbnValidationService" do
        expect_any_instance_of(AbnValidationService).to receive(:process).and_return(true)
        
        service = described_class.new(subscription, "12345678901")
        expect(service.call).to be true
      end
    end

    context "for Singapore" do
      before do
        subscription.original_purchase.update!(country: "Singapore")
        subscription.original_purchase.create_purchase_sales_tax_info!(country_code: "SG")
      end

      it "uses GstValidationService" do
        expect_any_instance_of(GstValidationService).to receive(:process).and_return(true)
        
        service = described_class.new(subscription, "123456789F")
        expect(service.call).to be true
      end
    end

    context "for Canada (Quebec)" do
      before do
        subscription.original_purchase.update!(country: "Canada", state: "Quebec")
        subscription.original_purchase.create_purchase_sales_tax_info!(country_code: "CA", state_code: "QC")
      end

      it "uses QstValidationService" do
        expect_any_instance_of(QstValidationService).to receive(:process).and_return(true)
        
        service = described_class.new(subscription, "1234567890TQ1234")
        expect(service.call).to be true
      end
    end
  end

  describe "#should_apply_retroactive_refunds?" do
    it "returns true when there are recent eligible purchases" do
      create(:purchase, 
        subscription: subscription,
        is_original_subscription_purchase: false,
        gumroad_tax_cents: 190,
        state: "successful",
        created_at: 15.days.ago
      )
      
      expect(service.send(:should_apply_retroactive_refunds?)).to be true
    end

    it "returns false when there are no recent eligible purchases" do
      expect(service.send(:should_apply_retroactive_refunds?)).to be false
    end

    it "returns false when purchases are too old" do
      create(:purchase, 
        subscription: subscription,
        is_original_subscription_purchase: false,
        gumroad_tax_cents: 190,
        state: "successful",
        created_at: 45.days.ago
      )
      
      expect(service.send(:should_apply_retroactive_refunds?)).to be false
    end

    it "returns false when purchases have no VAT" do
      create(:purchase, 
        subscription: subscription,
        is_original_subscription_purchase: false,
        gumroad_tax_cents: 0,
        state: "successful",
        created_at: 15.days.ago
      )
      
      expect(service.send(:should_apply_retroactive_refunds?)).to be false
    end
  end
end
