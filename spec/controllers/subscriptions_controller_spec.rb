# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe SubscriptionsController do
  let(:seller) { create(:named_seller) }
  let(:subscriber) { create(:user) }

  before do
    @product = create(:membership_product, subscription_duration: "monthly", user: seller)
    @subscription = create(:subscription, link: @product, user: subscriber)
    @purchase = create(:purchase, link: @product, subscription: @subscription, is_original_subscription_purchase: true)
  end

  context "within seller area" do
    include_context "with user signed in as admin for seller"

    describe "POST unsubscribe_by_seller" do
      it_behaves_like "authorize called for action", :post, :unsubscribe_by_seller do
        let(:record) { @subscription }
        let(:request_params) { { id: @subscription.external_id } }
      end

      it "unsubscribes the user from the seller" do
        travel_to(Time.current) do
          expect do
            post :unsubscribe_by_seller, params: { id: @subscription.external_id }
          end.to change { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }.from(nil).to(Time.current.to_i)
          expect(response).to be_successful
        end
      end

      it "sends the correct email" do
        mailer_double = double
        allow(mailer_double).to receive(:deliver_later)
        expect(CustomerLowPriorityMailer).to receive(:subscription_cancelled_by_seller).and_return(mailer_double)
        post :unsubscribe_by_seller, params: { id: @subscription.external_id }
        expect(response).to be_successful
      end
    end
  end

  context "within consumer area" do
    describe "POST unsubscribe_by_user" do
      before do
        cookies.encrypted[@subscription.cookie_key] = @subscription.external_id
      end

      it "unsubscribes the user" do
        travel_to(Time.current) do
          expect { post :unsubscribe_by_user, params: { id: @subscription.external_id } }
            .to change { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }.from(nil).to(Time.current.to_i)
        end
      end

      it "sends the correct email" do
        mail_double = double
        allow(mail_double).to receive(:deliver_later)
        expect(CustomerLowPriorityMailer).to receive(:subscription_cancelled).and_return(mail_double)
        post :unsubscribe_by_user, params: { id: @subscription.external_id }
      end

      it "does not send the incorrect email" do
        expect(CustomerLowPriorityMailer).to_not receive(:subscription_cancelled_by_seller)
        post :unsubscribe_by_user, params: { id: @subscription.external_id }
      end

      it "returns json success" do
        post :unsubscribe_by_user, params: { id: @subscription.external_id }
        expect(response.parsed_body["success"]).to be(true)
      end

      it "is not allowed for installment plans" do
        product = create(:product, :with_installment_plan, user: seller, price_cents: 30_00)
        purchase_with_installment_plan = create(:installment_plan_purchase, link: product, purchaser: subscriber)
        subscription = purchase_with_installment_plan.subscription
        cookies.encrypted[subscription.cookie_key] = subscription.external_id

        post :unsubscribe_by_user, params: { id: subscription.external_id }

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to include("Installment plans cannot be cancelled by the customer")
      end

      context "when the encrypted cookie is not present" do
        before do
          cookies.encrypted[@subscription.cookie_key] = nil
        end

        it "renders success false with redirect_to URL" do
          expect do
            post :unsubscribe_by_user, params: { id: @subscription.external_id }, format: :json
          end.to_not change { @subscription.reload.user_requested_cancellation_at }

          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["redirect_to"]).to eq(magic_link_subscription_path(@subscription.external_id))
        end
      end
    end

    describe "GET manage" do
      context "when subscription has ended" do
        it "returns 404" do
          expect { get :manage, params: { id: @subscription.external_id } }.not_to raise_error

          @subscription.end_subscription!

          expect { get :manage, params: { id: @subscription.external_id } }.to raise_error(ActionController::RoutingError)
        end
      end

      context "when encrypted cookie is present" do
        it "renders the manage page" do
          cookies.encrypted[@subscription.cookie_key] = @subscription.external_id
          get :manage, params: { id: @subscription.external_id }

          expect(response).to be_successful
        end
      end

      context "when the user is signed in" do
        it "renders the manage page" do
          sign_in subscriber
          get :manage, params: { id: @subscription.external_id }

          expect(response).to be_successful
        end
      end

      context "when the token param is same as subscription's token" do
        it "renders the manage page" do
          @subscription.update!(token: "valid_token", token_expires_at: 1.day.from_now)
          get :manage, params: { id: @subscription.external_id, token: "valid_token" }

          expect(response).to be_successful
        end
      end

      context "when the token is provided but doesn't match with subscription's token" do
        it "redirects to the magic link page" do
          get :manage, params: { id: @subscription.external_id, token: "not_valid_token" }

          expect(response).to redirect_to(magic_link_subscription_path(@subscription.external_id, invalid: true))
        end
      end

      context "when the token is provided but it has expired" do
        it "redirects to the magic link page" do
          @subscription.update!(token: "valid_token", token_expires_at: 1.day.ago)
          get :manage, params: { id: @subscription.external_id, token: "valid_token" }

          expect(response).to redirect_to(magic_link_subscription_path(@subscription.external_id, invalid: true))
        end
      end

      context "when it renders manage page successfully" do
        it "sets subscription cookie" do
          @subscription.update!(token: "valid_token", token_expires_at: 1.day.from_now)

          get :manage, params: { id: @subscription.external_id, token: "valid_token" }
          expect(response.cookies[@subscription.cookie_key]).to_not be_nil
        end
      end

      it "sets X-Robots-Tag response header to avoid search engines indexing the page" do
        get :manage, params: { id: @subscription.external_id }

        expect(response.headers["X-Robots-Tag"]).to eq "noindex"
      end
    end

    describe "GET magic_link" do
      it "renders the magic link page" do
        get :magic_link, params: { id: @subscription.external_id }

        expect(response).to be_successful
      end
    end

    describe "POST send_magic_link" do
      it "sets up the token in the subscription" do
        expect(@subscription.token).to be_nil
        post :send_magic_link, params: { id: @subscription.external_id, email_source: "user" }
        expect(@subscription.reload.token).to_not be_nil
      end

      it "sets the token to expire in 24 hours" do
        expect(@subscription.token_expires_at).to be_nil
        post :send_magic_link, params: { id: @subscription.external_id, email_source: "user" }
        expect(@subscription.reload.token_expires_at).to be_within(1.second).of(24.hours.from_now)
      end

      it "sends the magic link email" do
        mail_double = double
        allow(mail_double).to receive(:deliver_later)
        expect(CustomerMailer).to receive(:subscription_magic_link).and_return(mail_double)
        post :send_magic_link, params: { id: @subscription.external_id, email_source: "user" }
        expect(response).to be_successful
      end

      describe "email_source param" do
        before do
          @original_purchasing_user_email = subscriber.email
          @purchase.update!(email: "purchase@email.com")
          subscriber.update!(email: "subscriber@email.com")
        end

        context "when the email source is `user`" do
          it "sends the magic link email to the user's email" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, @original_purchasing_user_email).and_return(mail_double)
            post :send_magic_link, params: { id: @subscription.external_id, email_source: "user" }
            expect(response).to be_successful
          end
        end

        context "when the email source is `purchase`" do
          it "sends the magic link email to the email associated to the original purchase" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, "purchase@email.com").and_return(mail_double)
            post :send_magic_link, params: { id: @subscription.external_id, email_source: "purchase" }
            expect(response).to be_successful
          end
        end

        context "when the email source is `subscription`" do
          it "sends the magic link email to the email associated to the subscription" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, "subscriber@email.com").and_return(mail_double)
            post :send_magic_link, params: { id: @subscription.external_id, email_source: "subscription" }
            expect(response).to be_successful
          end
        end

        context "when the email source is not valid" do
          it "raises a 404 error" do
            expect do
              post :send_magic_link, params: { id: @subscription.external_id, email_source: "invalid source" }
            end.to raise_error(ActionController::RoutingError, "Not Found")
          end
        end
      end
    end

    describe "PUT update_vat_id" do
      before do
        cookies.encrypted[@subscription.cookie_key] = @subscription.external_id
      end

      context "when subscription is active and eligible" do
        let(:valid_au_vat_id) { "12345678901" } # Valid ABN format
        let(:valid_eu_vat_id) { "DE123456789" } # Valid EU VAT format

        before do
          # Mock the validation services to return true
          allow(AbnValidationService).to receive_message_chain(:new, :process).and_return(true)
          allow(VatValidationService).to receive_message_chain(:new, :process).and_return(true)
          
          # Create a purchase with tax that should be refunded
          @taxed_purchase = create(:purchase,
            link: @product,
            subscription: @subscription,
            is_original_subscription_purchase: false,
            created_at: 30.days.ago,
            price_cents: 10000,
            gumroad_tax_cents: 1000,
            country: "AU",
            state: nil)
        end

        it "updates the VAT ID successfully for Australian ABN" do
          put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_au_vat_id }
          
          expect(response).to be_successful
          expect(json_response["success"]).to be true
          expect(json_response["message"]).to include("VAT ID updated successfully")
          
          # Verify the VAT ID was stored
          expect(@subscription.reload.business_vat_id).to eq(valid_au_vat_id)
        end

        it "updates the VAT ID successfully for EU VAT" do
          put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_eu_vat_id }
          
          expect(response).to be_successful
          expect(json_response["success"]).to be true
          expect(json_response["message"]).to include("VAT ID updated successfully")
          
          # Verify the VAT ID was stored
          expect(@subscription.reload.business_vat_id).to eq(valid_eu_vat_id)
        end

        it "processes automatic VAT refunds for eligible purchases" do
          expect do
            put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_au_vat_id }
          end.to change(Refund, :count).by(1)
          
          # Verify the refund was created for the tax amount
          refund = Refund.last
          expect(refund.purchase_id).to eq(@taxed_purchase.id)
          expect(refund.amount_cents).to eq(1000) # The tax amount
          expect(refund.note).to include("Automatic VAT refund")
        end

        it "does not process refunds for purchases older than 90 days" do
          old_purchase = create(:purchase,
            link: @product,
            subscription: @subscription,
            is_original_subscription_purchase: false,
            created_at: 100.days.ago,
            price_cents: 10000,
            gumroad_tax_cents: 1000,
            country: "AU",
            state: nil)
          
          expect do
            put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_au_vat_id }
          end.to change(Refund, :count).by(1) # Only the recent purchase gets refunded
          
          # Verify the old purchase was not refunded
          expect(Refund.where(purchase_id: old_purchase.id)).to be_empty
        end

        it "does not process refunds for already tax-exempt purchases" do
          exempt_purchase = create(:purchase,
            link: @product,
            subscription: @subscription,
            is_original_subscription_purchase: false,
            created_at: 30.days.ago,
            price_cents: 10000,
            gumroad_tax_cents: 0, # Already exempt
            country: "AU",
            state: nil)
          
          expect do
            put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_au_vat_id }
          end.to change(Refund, :count).by(1) # Only the taxed purchase gets refunded
          
          # Verify the exempt purchase was not refunded
          expect(Refund.where(purchase_id: exempt_purchase.id)).to be_empty
        end
      end

      context "when VAT ID validation fails" do
        let(:invalid_vat_id) { "INVALID" }

        before do
          # Mock the validation services to return false
          allow(AbnValidationService).to receive_message_chain(:new, :process).and_return(false)
          allow(VatValidationService).to receive_message_chain(:new, :process).and_return(false)
        end

        it "returns error response for invalid VAT ID" do
          put :update_vat_id, params: { id: @subscription.external_id, vat_id: invalid_vat_id }
          
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response["success"]).to be false
          expect(json_response["message"]).to include("Invalid VAT ID format")
          
          # Verify the VAT ID was not stored
          expect(@subscription.reload.business_vat_id).to be_nil
        end

        it "does not process any refunds when validation fails" do
          create(:purchase,
            link: @product,
            subscription: @subscription,
            is_original_subscription_purchase: false,
            created_at: 30.days.ago,
            price_cents: 10000,
            gumroad_tax_cents: 1000,
            country: "AU",
            state: nil)
          
          expect do
            put :update_vat_id, params: { id: @subscription.external_id, vat_id: invalid_vat_id }
          end.not_to change(Refund, :count)
        end
      end

      context "when subscription is not eligible for VAT ID updates" do
        let(:valid_vat_id) { "12345678901" }

        before do
          allow(AbnValidationService).to receive_message_chain(:new, :process).and_return(true)
        end

        context "when subscription is cancelled" do
          before do
            @subscription.update!(cancelled_at: Time.current)
          end

          it "returns error response" do
            put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_vat_id }
            
            expect(response).to have_http_status(:unprocessable_entity)
            expect(json_response["success"]).to be false
            expect(json_response["message"]).to include("not eligible")
          end
        end

        context "when subscription has ended" do
          before do
            @subscription.update!(end_time_of_subscription: 1.day.ago)
          end

          it "returns error response" do
            put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_vat_id }
            
            expect(response).to have_http_status(:unprocessable_entity)
            expect(json_response["success"]).to be false
            expect(json_response["message"]).to include("not eligible")
          end
        end

        context "when subscription is for a non-taxable product" do
          before do
            @product.update!(is_physical: true) # Physical products don't have VAT
          end

          it "returns error response" do
            put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_vat_id }
            
            expect(response).to have_http_status(:unprocessable_entity)
            expect(json_response["success"]).to be false
            expect(json_response["message"]).to include("not eligible")
          end
        end
      end

      context "when country is not eligible for VAT exemption" do
        let(:valid_vat_id) { "12345678901" }

        before do
          # Create a purchase from a non-VAT country
          @purchase.update!(country: "US") # US doesn't have VAT
          allow(AbnValidationService).to receive_message_chain(:new, :process).and_return(true)
        end

        it "returns error response" do
          put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_vat_id }
          
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response["success"]).to be false
          expect(json_response["message"]).to include("not eligible")
        end
      end

      context "when duplicate refund prevention is triggered" do
        let(:valid_vat_id) { "12345678901" }

        before do
          allow(AbnValidationService).to receive_message_chain(:new, :process).and_return(true)
          
          # Create a purchase with tax
          @taxed_purchase = create(:purchase,
            link: @product,
            subscription: @subscription,
            is_original_subscription_purchase: false,
            created_at: 30.days.ago,
            price_cents: 10000,
            gumroad_tax_cents: 1000,
            country: "AU",
            state: nil)
          
          # Create an existing refund with the same note
          create(:refund,
            purchase: @taxed_purchase,
            amount_cents: 1000,
            note: "Automatic VAT refund for ABN: #{valid_vat_id}")
        end

        it "does not create duplicate refunds" do
          expect do
            put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_vat_id }
          end.not_to change(Refund, :count)
          
          # Still returns success since the VAT ID was updated
          expect(response).to be_successful
          expect(json_response["success"]).to be true
        end
      end

      context "error handling" do
        let(:valid_vat_id) { "12345678901" }

        before do
          allow(AbnValidationService).to receive_message_chain(:new, :process).and_return(true)
        end

        it "handles unexpected errors gracefully" do
          # Mock the update_vat_id! method to raise an exception
          allow(@subscription).to receive(:update_vat_id!).and_raise(StandardError.new("Unexpected error"))
          
          put :update_vat_id, params: { id: @subscription.external_id, vat_id: valid_vat_id }
          
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json_response["success"]).to be false
          expect(json_response["message"]).to include("An error occurred")
        end
      end
    end
  end
end
