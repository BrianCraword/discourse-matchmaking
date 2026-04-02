# frozen_string_literal: true

class MatchmakingConsent < ActiveRecord::Base
  belongs_to :user

  CONSENT_TYPES = %w[profile_creation ai_matching llm_processing].freeze
  CURRENT_POLICY_VERSION = "1.0".freeze

  validates :user_id, presence: true
  validates :consent_type, presence: true, inclusion: { in: CONSENT_TYPES }
  validates :policy_version, presence: true
  validates :granted, inclusion: { in: [true, false] }

  scope :active, -> { where(granted: true, withdrawn_at: nil) }
  scope :for_user, ->(user_id) { where(user_id: user_id) }
  scope :of_type, ->(type) { where(consent_type: type) }

  # ── Class Methods ────────────────────────────────────────────────────

  # Check if a user has active consent of a given type
  def self.has_active_consent?(user_id, consent_type)
    active.for_user(user_id).of_type(consent_type).exists?
  end

  # Check if user has all three required consents
  def self.fully_consented?(user_id)
    CONSENT_TYPES.all? { |type| has_active_consent?(user_id, type) }
  end

  # Grant consent — creates or updates the consent record
  def self.grant!(user_id, consent_type, ip_address: nil)
    record = find_or_initialize_by(user_id: user_id, consent_type: consent_type)
    record.assign_attributes(
      policy_version: CURRENT_POLICY_VERSION,
      granted: true,
      ip_address: ip_address,
      granted_at: Time.current,
      withdrawn_at: nil,
    )
    record.save!
    record
  end

  # Grant all three consent types at once (used by the consent gate UI)
  def self.grant_all!(user_id, ip_address: nil)
    CONSENT_TYPES.map { |type| grant!(user_id, type, ip_address: ip_address) }
  end

  # Withdraw a specific consent
  def self.withdraw!(user_id, consent_type)
    record = active.for_user(user_id).of_type(consent_type).first
    return false unless record
    record.update!(granted: false, withdrawn_at: Time.current)
    true
  end

  # Withdraw all consents — used when user requests data deletion
  def self.withdraw_all!(user_id)
    active.for_user(user_id).update_all(granted: false, withdrawn_at: Time.current)
  end

  # Check if user needs to re-consent due to policy version change
  def self.needs_reconsent?(user_id)
    latest = for_user(user_id).active.order(updated_at: :desc).first
    return true unless latest
    latest.policy_version != CURRENT_POLICY_VERSION
  end
end
