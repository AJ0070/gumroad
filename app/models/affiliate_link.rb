# frozen_string_literal: true

class AffiliateLink < ApplicationRecord
  self.table_name = 'affiliates_links'
  
  # Status values
  PENDING = 'pending'.freeze
  APPROVED = 'approved'.freeze
  DENIED = 'denied'.freeze
  REVOKED = 'revoked'.freeze
  
  STATUSES = [PENDING, APPROVED, DENIED, REVOKED].freeze
  
  # Associations
  belongs_to :affiliate, class_name: 'Affiliate'
  belongs_to :link, class_name: 'Link'
  
  # Validations
  validates :status, presence: true, inclusion: { in: STATUSES }
  
  # Scopes
  scope :pending, -> { where(status: PENDING) }
  scope :approved, -> { where(status: APPROVED) }
  scope :denied, -> { where(status: DENIED) }
  scope :revoked, -> { where(status: REVOKED) }
  scope :active, -> { where(status: [PENDING, APPROVED]) }
  
  # State machine for status transitions
  state_machine :status, initial: PENDING do
    event :approve do
      transition PENDING => APPROVED
    end
    
    event :deny do
      transition PENDING => DENIED
    end
    
    event :revoke do
      transition [PENDING, APPROVED] => REVOKED
    end
    
    event :reset do
      transition [DENIED, REVOKED] => PENDING
    end
    
    before_transition any => any do |affiliate_link, transition|
      affiliate_link.status_updated_at = Time.current
    end
    
    after_transition PENDING => APPROVED do |affiliate_link|
      # Notify the affiliate that they've been approved
      AffiliateMailer.affiliate_approved(affiliate_link).deliver_later
    end
    
    after_transition PENDING => DENIED do |affiliate_link|
      # Notify the affiliate that they've been denied
      AffiliateMailer.affiliate_denied(affiliate_link).deliver_later
    end
    
    after_transition any => REVOKED do |affiliate_link, transition|
      # Notify the affiliate that their access has been revoked
      AffiliateMailer.affiliate_revoked(affiliate_link, transition.from).deliver_later
    end
  end
  
  # Returns true if the affiliate link is in an active state
  def active?
    [PENDING, APPROVED].include?(status)
  end
  
  # Returns the affiliate percentage for this link
  def affiliate_percentage
    affiliate_basis_points.to_f / 100
  end
  
  # Returns the human-readable status
  def status_humanized
    status.titleize
  end
  
  # Returns the product associated with this link
  def product
    link.try(:product)
  end
  
  # Returns the affiliate user
  def affiliate_user
    affiliate.try(:affiliate_user)
  end
  
  # Returns the seller (product owner)
  def seller
    product.try(:user)
  end
end
