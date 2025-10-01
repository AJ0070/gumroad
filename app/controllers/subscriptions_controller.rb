# frozen_string_literal: true

class SubscriptionsController < ApplicationController
  PUBLIC_ACTIONS = %i[manage unsubscribe_by_user magic_link send_magic_link].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :fetch_subscription, only: %i[unsubscribe_by_seller unsubscribe_by_user magic_link send_magic_link update_vat_id]
  before_action :hide_layouts, only: [:manage, :magic_link, :send_magic_link]
  before_action :set_noindex_header, only: [:manage]
  before_action :check_can_manage, only: [:manage, :unsubscribe_by_user]

  SUBSCRIPTION_COOKIE_EXPIRY = 1.week

  def unsubscribe_by_seller
    authorize @subscription

    @subscription.cancel!(by_seller: true)
    head :no_content
  end

  def unsubscribe_by_user
    @subscription.cancel!(by_seller: false)
    render json: { success: true }
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, error: e.message }
  end

  def manage
    @product = @subscription.link
    @card = @subscription.credit_card_to_charge
    @card_data_handling_mode = CardDataHandlingMode.get_card_data_handling_mode(@product.user)
    @title = @subscription.is_installment_plan ? "Manage installment plan" : "Manage membership"
    @body_id = "product_page"
    @is_on_product_page = true

    set_subscription_confirmed_redirect_cookie
  end

  def magic_link
    @body_class = "onboarding-page"

    @react_component_props = SubscriptionsPresenter.new(subscription: @subscription).magic_link_props
  end

  def send_magic_link
    @subscription.refresh_token

    emails = @subscription.emails
    email_source = params[:email_source].to_sym
    email = emails[email_source]
    e404 if email.nil?

    CustomerMailer.subscription_magic_link(@subscription.id, email).deliver_later(queue: "critical")

    head :no_content
  end

  def update_vat_id
    authorize @subscription

    vat_id = params[:vat_id].to_s.strip
    
    if vat_id.blank?
      render json: { success: false, error: "VAT ID is required" }
      return
    end

    # Validate VAT ID format before processing
    validation_result = validate_vat_id_format(vat_id, @subscription.original_purchase.country)
    unless validation_result[:valid]
      render json: { 
        success: false, 
        error: validation_result[:error],
        details: validation_result[:details]
      }
      return
    end

    result = @subscription.update_vat_id!(vat_id)
    
    if result
      render json: { 
        success: true, 
        message: "VAT ID updated successfully",
        refunds_processed: result,
        country: @subscription.original_purchase.country
      }
    else
      render json: { 
        success: false, 
        error: "VAT ID validation failed",
        details: "The provided VAT ID could not be validated. Please check the format and ensure it's valid for your country."
      }
    end
  rescue => e
    Rails.logger.error "VAT ID update error for subscription #{@subscription.id}: #{e.message}"
    render json: { 
      success: false, 
      error: "An error occurred while updating your VAT ID",
      details: "Please try again or contact support if the problem persists."
    }
  end

  private
    def validate_vat_id_format(vat_id, country)
      country_code = Compliance::Countries.find_by_name(country)&.alpha2
      
      return { valid: false, error: "Country not recognized", details: "Could not determine country for VAT validation" } unless country_code
      
      # Basic format validation by country
      case country_code
      when Compliance::Countries::AUS.alpha2
        { valid: vat_id.match?(/^\d{11}$/), error: "Invalid ABN format", details: "Australian ABN must be 11 digits" }
      when Compliance::Countries::SGP.alpha2
        { valid: vat_id.match?(/^GST\d{8}[A-Z]$/i), error: "Invalid GST format", details: "Singapore GST must start with GST followed by 8 digits and a letter" }
      when Compliance::Countries::CAN.alpha2
        { valid: vat_id.match?(/^\d{9}$/), error: "Invalid QST format", details: "Canadian QST number must be 9 digits" }
      when Compliance::Countries::NOR.alpha2
        { valid: vat_id.match?(/^\d{9}MVA$/i), error: "Invalid MVA format", details: "Norwegian MVA must be 9 digits followed by MVA" }
      else
        # For EU and other countries, use basic VAT format validation
        { valid: vat_id.match?(/^[A-Z]{2}\d+$/i), error: "Invalid VAT format", details: "VAT ID must start with country code followed by numbers" }
      end
    end

  private
    def check_can_manage
      (@subscription = Subscription.find_by_external_id(params[:id])) || e404
      e404 if @subscription.ended?
      cookie = cookies.encrypted[@subscription.cookie_key]
      return if cookie.present? && ActiveSupport::SecurityUtils.secure_compare(cookie, @subscription.external_id)
      return if user_signed_in? && logged_in_user.is_team_member?
      return if user_signed_in? && logged_in_user == @subscription.user
      token = params[:token]
      if token.present?
        return if @subscription.token.present? && ActiveSupport::SecurityUtils.secure_compare(token, @subscription.token) && @subscription.token_expires_at > Time.current
        return redirect_to magic_link_subscription_path(params[:id], { invalid: true })
      end

      respond_to do |format|
        format.html { redirect_to magic_link_subscription_path(params[:id]) }
        format.json { render json: { success: false, redirect_to: magic_link_subscription_path(params[:id]) } }
      end
    end

    def set_subscription_confirmed_redirect_cookie
      cookies.encrypted[@subscription.cookie_key] = {
        value: @subscription.external_id,
        httponly: true,
        expires: Rails.env.test? ? nil : SUBSCRIPTION_COOKIE_EXPIRY.from_now
      }
    end

    def fetch_subscription
      @subscription = Subscription.find_by_external_id(params[:id] || params[:subscription_id])
      render json: { success: false } if @subscription.nil?
    end
end
