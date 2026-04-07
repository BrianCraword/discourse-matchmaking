# frozen_string_literal: true

module DiscourseMatchmaking
  class ProfilesController < ::ApplicationController
    requires_plugin DiscourseMatchmaking::PLUGIN_NAME
    requires_login

    before_action :ensure_matchmaking_enabled
    before_action :ensure_user_in_allowed_group, except: %i[consent_status grant_consent show create update]
    before_action :ensure_consent, only: %i[show update]
    before_action :ensure_admin, only: %i[admin_approve admin_reject admin_reset admin_block admin_queue admin_profile_detail admin_search]

    # GET /matchmaking/profile
    # Returns the current user's matchmaking profile, or nil if none exists
    def show
      profile = MatchmakingProfile.find_by(user_id: current_user.id)
      if profile
        render json: MatchmakingProfileSerializer.new(profile, root: "matchmaking_profile").as_json.merge(consent_status: consent_status_for(current_user.id))
      else
        render json: { matchmaking_profile: nil, consent_status: consent_status_for(current_user.id) }
      end
    end

    # POST /matchmaking/profile
    # Creates a new profile (requires consent grant in the same request or prior)
    def create
      # Grant consent if included in the request
      if params[:grant_consent]
        MatchmakingConsent.grant_all!(current_user.id, ip_address: request.remote_ip)
      end

      unless MatchmakingConsent.has_active_consent?(current_user.id, "profile_creation")
        return render json: { error: "Consent required before creating a matchmaking profile." }, status: 403
      end

      existing = MatchmakingProfile.find_by(user_id: current_user.id)
      if existing
        return render json: { error: "Profile already exists. Use PUT to update." }, status: 422
      end

      profile_data = profile_params.merge(user_id: current_user.id)

      # Set initial verification status if verification is enabled
      if verification_enabled?
        profile_data[:verification_status] = "pending_interview"
      else
        profile_data[:verification_status] = "verified"
      end

      profile = MatchmakingProfile.new(profile_data)
      if profile.save
        if verification_enabled?
          # User is already in pending_verification group (added at registration via plugin.rb hook).
          # Sync the admin-visible custom user field.
          profile.send(:sync_verification_admin_field, "pending_interview")
        else
          # No verification required — auto-promote
          profile.verify!("auto_no_verification")
        end

        render json: MatchmakingProfileSerializer.new(profile, root: "matchmaking_profile").as_json.merge(
          consent_status: consent_status_for(current_user.id),
        ), status: 201
      else
        render json: { errors: profile.errors.full_messages }, status: 422
      end
    end

    # PUT /matchmaking/profile
    # Updates the current user's existing profile
    def update
      profile = MatchmakingProfile.find_by(user_id: current_user.id)
      unless profile
        return render json: { error: "No profile found. Use POST to create one." }, status: 404
      end

      if profile.update(profile_params)
        render json: MatchmakingProfileSerializer.new(profile, root: "matchmaking_profile")
      else
        render json: { errors: profile.errors.full_messages }, status: 422
      end
    end

    # DELETE /matchmaking/profile
    # Deletes all matchmaking data for the current user (profile, matches, consents)
    def destroy
      profile = MatchmakingProfile.find_by(user_id: current_user.id)

      # Audit log: record deletion (timestamp + user_id only, never deleted data)
      if profile
        Rails.logger.info(
          "[discourse-matchmaking] Data deletion: user_id=#{current_user.id} " \
          "profile_id=#{profile.id} at=#{Time.current.iso8601}"
        )
        # Clean up group membership
        group = Group.find_by(name: MatchmakingProfile::VERIFICATION_GROUP_NAME)
        group.remove(current_user) if group
        # Clear the admin custom field
        profile.send(:sync_verification_admin_field, "deleted")
      end

      profile&.destroy

      # Also clean up matches where this user was involved
      MatchmakingMatch.where("searcher_id = ? OR candidate_id = ?", current_user.id, current_user.id).destroy_all

      # Withdraw all consents (keep records for audit trail, mark as withdrawn)
      MatchmakingConsent.withdraw_all!(current_user.id)

      render json: { success: true, message: "All matchmaking data has been deleted." }
    end

    # GET /matchmaking/consent-status
    # Returns the user's current consent status without requiring prior consent
    def consent_status
      render json: { consent_status: consent_status_for(current_user.id) }
    end

    # POST /matchmaking/grant-consent
    # Grants all three consent types
    def grant_consent
      MatchmakingConsent.grant_all!(current_user.id, ip_address: request.remote_ip)
      render json: { consent_status: consent_status_for(current_user.id) }
    end

    # GET /matchmaking/export
    # Phase 5: GDPR data export — returns all matchmaking data for current user as JSON
    def export_data
      profile = MatchmakingProfile.find_by(user_id: current_user.id)
      matches_as_searcher = MatchmakingMatch.where(searcher_id: current_user.id).order(created_at: :desc)
      matches_as_candidate = MatchmakingMatch.where(candidate_id: current_user.id).order(created_at: :desc)
      consents = MatchmakingConsent.for_user(current_user.id).order(updated_at: :desc)

      export = {
        exported_at: Time.current.iso8601,
        user_id: current_user.id,
        username: current_user.username,
        profile: profile ? profile_export_hash(profile) : nil,
        matches_initiated: matches_as_searcher.map { |m| match_export_hash(m) },
        matches_received: matches_as_candidate.map { |m| match_export_hash(m) },
        consent_records: consents.map { |c| consent_export_hash(c) },
      }

      render json: export
    end

    # POST /matchmaking/admin/approve/:user_id
    # Admin approves a flagged verification
    def admin_approve
      profile = MatchmakingProfile.find_by(user_id: params[:user_id])
      unless profile
        return render json: { error: "Profile not found." }, status: 404
      end

      profile.verify!(current_user.username)

      render json: {
        success: true,
        message: "User #{profile.user.username} has been verified and promoted to TL1.",
        verification_status: profile.verification_status,
      }
    end

    # POST /matchmaking/admin/reject/:user_id
    # Admin rejects a flagged verification
    def admin_reject
      profile = MatchmakingProfile.find_by(user_id: params[:user_id])
      unless profile
        return render json: { error: "Profile not found." }, status: 404
      end

      profile.reject!(current_user.username)

      render json: {
        success: true,
        message: "User #{profile.user.username} has been rejected.",
        verification_status: profile.verification_status,
      }
    end

    # POST /matchmaking/admin/reset/:user_id
    # Admin resets a user back to pending_interview for re-verification
    def admin_reset
      profile = MatchmakingProfile.find_by(user_id: params[:user_id])
      unless profile
        return render json: { error: "Profile not found." }, status: 404
      end

      profile.reset_verification!

      render json: {
        success: true,
        message: "User #{profile.user.username} has been reset to pending interview. They can re-verify by talking to the Verification Companion.",
        verification_status: profile.verification_status,
      }
    end

    # POST /matchmaking/admin/block/:user_id
    # Admin rejects AND blocks the user's IP
    def admin_block
      profile = MatchmakingProfile.find_by(user_id: params[:user_id])
      return render json: { error: "Profile not found." }, status: 404 unless profile

      profile.reject!(current_user.username)

      ip = profile.user.ip_address || profile.user.registration_ip_address
      ip_blocked = false
      if ip.present?
        ScreenedIpAddress.create(
          ip_address: ip,
          action_type: ScreenedIpAddress.actions[:block],
        )
        ip_blocked = true
      end

      render json: {
        success: true,
        message: "User #{profile.user.username} rejected#{ip_blocked ? ' and IP blocked' : ''}.",
        verification_status: profile.verification_status,
        ip_blocked: ip_blocked,
      }
    end

    # GET /matchmaking/admin/queue
    # Returns all profiles grouped by verification status for the admin panel
    def admin_queue
      flagged = MatchmakingProfile.where(verification_status: "flagged")
        .includes(:user).order("matchmaking_profiles.updated_at DESC")
      pending = MatchmakingProfile.where(verification_status: "pending_interview")
        .includes(:user).order("matchmaking_profiles.created_at DESC")
      verified = MatchmakingProfile.where(verification_status: "verified")
        .includes(:user).order("matchmaking_profiles.verified_at DESC NULLS LAST").limit(20)
      rejected = MatchmakingProfile.where(verification_status: "rejected")
        .includes(:user).order("matchmaking_profiles.updated_at DESC")

      render json: {
        flagged: flagged.map { |p| admin_profile_hash(p) },
        pending: pending.map { |p| admin_profile_hash(p) },
        verified: verified.map { |p| admin_profile_hash(p) },
        rejected: rejected.map { |p| admin_profile_hash(p) },
      }
    end

    # GET /matchmaking/admin/profile/:user_id
    # Returns detailed profile + verification data for admin review
    def admin_profile_detail
      profile = MatchmakingProfile.find_by(user_id: params[:user_id])
      return render json: { error: "Profile not found." }, status: 404 unless profile

      render json: {
        profile: admin_profile_hash(profile),
        verification_data: profile.verification_data,
        transcript_url: profile.verification_conversation_topic_id ?
          "#{Discourse.base_url}/t/#{profile.verification_conversation_topic_id}" : nil,
      }
    end

    # GET /matchmaking/admin/search?q=username
    # Search for any user by username — returns profile if exists, user info if not
    def admin_search
      query = params[:q].to_s.strip
      return render json: { error: "Search query required." }, status: 400 if query.blank?

      # Find matching users (case-insensitive, prefix match)
      users = User.where("username ILIKE ?", "#{query}%").limit(10)
      results = users.map do |user|
        profile = MatchmakingProfile.find_by(user_id: user.id)
        if profile
          admin_profile_hash(profile)
        else
          {
            user_id: user.id,
            username: user.username,
            name: user.name,
            avatar_url: user.avatar_template&.gsub("{size}", "45"),
            registered_at: user.created_at&.iso8601,
            trust_level: user.trust_level,
            verification_status: "no_profile",
            completion_percentage: 0,
            has_conversation: false,
            confidenceDisplay: "—",
            recBadgeClass: "",
            recBadgeLabel: "No Profile",
            firstConcern: "User has not created a matchmaking profile",
          }
        end
      end

      render json: { results: results }
    end

    private

    def ensure_matchmaking_enabled
      unless SiteSetting.matchmaking_enabled
        render json: { error: "Matchmaking is not enabled." }, status: 403
      end
    end

    def ensure_user_in_allowed_group
      allowed_groups = SiteSetting.matchmaking_allowed_groups
      return if allowed_groups.blank?

      group_ids = allowed_groups.split("|").map(&:to_i)
      unless current_user.group_ids.any? { |gid| group_ids.include?(gid) }
        render json: { error: "You do not have access to matchmaking." }, status: 403
      end
    end

    def ensure_consent
      unless MatchmakingConsent.has_active_consent?(current_user.id, "profile_creation")
        render json: {
          error: "consent_required",
          consent_status: consent_status_for(current_user.id),
          policy_version: MatchmakingConsent::CURRENT_POLICY_VERSION,
        }, status: 403
      end
    end

    def ensure_admin
      unless current_user.admin?
        render json: { error: "Admin access required." }, status: 403
      end
    end

    def verification_enabled?
      SiteSetting.respond_to?(:matchmaking_verification_enabled) && SiteSetting.matchmaking_verification_enabled
    end

    def consent_status_for(user_id)
      {
        profile_creation: MatchmakingConsent.has_active_consent?(user_id, "profile_creation"),
        ai_matching: MatchmakingConsent.has_active_consent?(user_id, "ai_matching"),
        llm_processing: MatchmakingConsent.has_active_consent?(user_id, "llm_processing"),
        needs_reconsent: MatchmakingConsent.needs_reconsent?(user_id),
        policy_version: MatchmakingConsent::CURRENT_POLICY_VERSION,
      }
    end

    def admin_profile_hash(profile)
      {
        user_id: profile.user_id,
        username: profile.user&.username,
        name: profile.user&.name,
        avatar_url: profile.user&.avatar_template&.gsub("{size}", "45"),
        registered_at: profile.user&.created_at&.iso8601,
        trust_level: profile.user&.trust_level,
        verification_status: profile.verification_status,
        verified_at: profile.verified_at&.iso8601,
        verified_by: profile.verified_by,
        confidence_score: profile.verification_data&.dig("confidence_score"),
        recommendation: profile.verification_data&.dig("recommendation"),
        recommendation_reason: profile.verification_data&.dig("recommendation_reason"),
        key_concerns: profile.verification_data&.dig("key_concerns") || [],
        flags: profile.verification_data&.dig("flags") || [],
        summary: profile.verification_data&.dig("summary"),
        scores: {
          coherence: profile.verification_data&.dig("coherence"),
          depth: profile.verification_data&.dig("depth"),
          theological_consistency: profile.verification_data&.dig("theological_consistency"),
          engagement_quality: profile.verification_data&.dig("engagement_quality"),
          interview_completeness: profile.verification_data&.dig("interview_completeness"),
        },
        profile_excerpts: {
          testimony: profile.testimony.to_s.truncate(300),
          life_goals: profile.life_goals.to_s.truncate(300),
          partner_description: profile.partner_description.to_s.truncate(300),
          ministry_involvement: profile.ministry_involvement.to_s.truncate(300),
          denomination: profile.denomination,
          church_attendance: profile.church_attendance,
        },
        completion_percentage: profile.completion_percentage,
        has_conversation: profile.verification_conversation_topic_id.present?,
        conversation_topic_id: profile.verification_conversation_topic_id,
        created_at: profile.created_at&.iso8601,
      }
    end

    def profile_export_hash(profile)
      {
        created_at: profile.created_at&.iso8601,
        updated_at: profile.updated_at&.iso8601,
        gender: profile.gender,
        seeking_gender: profile.seeking_gender,
        birth_year: profile.birth_year,
        age_min_preference: profile.age_min_preference,
        age_max_preference: profile.age_max_preference,
        country: profile.country,
        state: profile.state,
        city: profile.city,
        zip_code: profile.zip_code,
        location_flexibility: profile.location_flexibility,
        denomination: profile.denomination,
        denomination_importance: profile.denomination_importance,
        church_attendance: profile.church_attendance,
        baptism_status: profile.baptism_status,
        bible_engagement: profile.bible_engagement,
        testimony: profile.testimony,
        theological_views: profile.theological_views,
        relationship_intention: profile.relationship_intention,
        children_preference: profile.children_preference,
        life_goals: profile.life_goals,
        ministry_involvement: profile.ministry_involvement,
        partner_description: profile.partner_description,
        interests: profile.interests,
        lifestyle: profile.lifestyle,
        dealbreakers: profile.dealbreakers,
        active: profile.active,
        visible: profile.visible,
        faith_summary: profile.faith_summary,
        faith_tags: profile.faith_tags,
        verification_status: profile.verification_status,
        verified_at: profile.verified_at&.iso8601,
        completion_percentage: profile.completion_percentage,
      }
    end

    def match_export_hash(match)
      {
        created_at: match.created_at&.iso8601,
        status: match.status,
        compatibility_score: match.compatibility_score,
        role: match.searcher_id == current_user.id ? "searcher" : "candidate",
      }
    end

    def consent_export_hash(consent)
      {
        consent_type: consent.consent_type,
        policy_version: consent.policy_version,
        granted: consent.granted,
        granted_at: consent.granted_at&.iso8601,
        withdrawn_at: consent.withdrawn_at&.iso8601,
      }
    end

    def profile_params
      permitted = params.require(:matchmaking_profile).permit(
        :gender,
        :seeking_gender,
        :birth_year,
        :age_min_preference,
        :age_max_preference,
        :country,
        :state,
        :city,
        :location_flexibility,
        :zip_code,
        :denomination,
        :denomination_importance,
        :church_attendance,
        :baptism_status,
        :bible_engagement,
        :testimony,
        :relationship_intention,
        :children_preference,
        :life_goals,
        :ministry_involvement,
        :partner_description,
        :active,
        :visible,
        theological_views: {},
        interests: [],
        lifestyle: [],
        dealbreakers: [],
      )
      permitted
    end
  end
end
