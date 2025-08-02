# frozen_string_literal: true

class AffiliateLinksController < ApplicationController
  before_action :authenticate_user!
  before_action :set_affiliate_link
  before_action :authorize_affiliate_link

  # PATCH /affiliate_links/:id/approve
  def approve
    if @affiliate_link.approve
      render json: { success: true, status: @affiliate_link.status }
    else
      render json: { success: false, errors: @affiliate_link.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /affiliate_links/:id/deny
  def deny
    if @affiliate_link.deny
      render json: { success: true, status: @affiliate_link.status }
    else
      render json: { success: false, errors: @affiliate_link.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /affiliate_links/:id/revoke
  def revoke
    if @affiliate_link.revoke
      render json: { success: true, status: @affiliate_link.status }
    else
      render json: { success: false, errors: @affiliate_link.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def set_affiliate_link
    @affiliate_link = AffiliateLink.find_by(id: params[:id])
    return if @affiliate_link
    
    render json: { success: false, error: 'Affiliate link not found' }, status: :not_found
  end

  def authorize_affiliate_link
    # Only the product owner (seller) or the affiliate user can modify the status
    unless current_user == @affiliate_link.seller || current_user == @affiliate_link.affiliate_user
      render json: { success: false, error: 'Not authorized' }, status: :forbidden
    end
  end
end
