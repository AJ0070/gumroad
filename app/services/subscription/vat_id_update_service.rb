# frozen_string_literal: true

class Subscription::VatIdUpdateService
  attr_reader :subscription, :vat_id, :errors

  def initialize(subscription, vat_id)
    @subscription = subscription
    @vat_id = vat_id&.strip
    @errors = []
  end

  def call
    return false unless validate_inputs
    return false unless validate_vat_id

    update_subscription_vat_id
    apply_retroactive_refunds if should_apply_retroactive_refunds?
    
    true
  rescue => e
    Rails.logger.error("Failed to update VAT ID for subscription #{subscription.external_id}: #{e.message}")
    @errors << "Failed to update VAT ID: #{e.message}"
    false
  end

  private

  def validate_inputs
    if subscription.blank?
      @errors << "Subscription is required"
      return false
    end

    unless subscription.alive?
      @errors << "Cannot update VAT ID for inactive subscription"
      return false
    end

    if vat_id.blank?
      @errors << "VAT ID is required"
      return false
    end

    true
  end

  def validate_vat_id
    country_code = subscription.original_purchase.purchase_sales_tax_info&.country_code
    
    if country_code.blank?
      @errors << "Cannot determine country for VAT ID validation"
      return false
    end

    unless subscription.send(:validate_vat_id_for_country, vat_id, country_code)
      @errors << "Invalid VAT ID for country #{country_code}"
      return false
    end

    true
  end

  def update_subscription_vat_id
    ActiveRecord::Base.transaction do
      # Update the original purchase's sales tax info
      sales_tax_info = subscription.original_purchase.purchase_sales_tax_info
      if sales_tax_info.present?
        sales_tax_info.update!(business_vat_id: vat_id)
      else
        # Create sales tax info if it doesn't exist
        subscription.original_purchase.create_purchase_sales_tax_info!(
          business_vat_id: vat_id,
          country_code: subscription.original_purchase.country,
          postal_code: subscription.original_purchase.zip_code,
          state_code: subscription.original_purchase.state,
          ip_address: subscription.original_purchase.ip_address
        )
      end

      Rails.logger.info("Updated VAT ID for subscription #{subscription.external_id} to #{vat_id}")
    end
  end

  def should_apply_retroactive_refunds?
    # Only apply retroactive refunds for recent charges (within last 30 days)
    # to avoid processing very old charges
    subscription.purchases.successful
                          .where("created_at > ?", 30.days.ago)
                          .where("gumroad_tax_cents > 0")
                          .where.not(is_original_subscription_purchase: true)
                          .exists?
  end

  def apply_retroactive_refunds
    Rails.logger.info("Applying retroactive VAT refunds for subscription #{subscription.external_id}")
    
    eligible_purchases = subscription.purchases.successful
                                              .where("created_at > ?", 30.days.ago)
                                              .where("gumroad_tax_cents > 0")
                                              .where.not(is_original_subscription_purchase: true)
                                              .where.not(id: subscription.purchases.joins(:refunds)
                                                                    .where("refunds.gumroad_tax_cents > 0")
                                                                    .select(:id))

    eligible_purchases.each do |purchase|
      begin
        purchase.refund_gumroad_taxes!(
          refunding_user_id: nil,
          note: "Retroactive VAT refund after VAT ID update for subscription",
          business_vat_id: vat_id
        )
        Rails.logger.info("Applied retroactive VAT refund for purchase #{purchase.external_id}")
      rescue => e
        Rails.logger.error("Failed to apply retroactive VAT refund for purchase #{purchase.external_id}: #{e.message}")
        # Continue with other purchases even if one fails
      end
    end
  end
end
