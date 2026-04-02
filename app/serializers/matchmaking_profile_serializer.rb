# frozen_string_literal: true

class MatchmakingProfileSerializer < ApplicationSerializer
  attributes :id,
             :user_id,
             # Identity
             :gender,
             :seeking_gender,
             :birth_year,
             :age_min_preference,
             :age_max_preference,
             # Location
             :country,
             :state,
             :city,
             :location_flexibility,
             :zip_code,
             # Faith Foundation
             :denomination,
             :denomination_importance,
             :church_attendance,
             :baptism_status,
             :bible_engagement,
             :testimony,
             # Theological Views
             :theological_views,
             # Values and Goals
             :relationship_intention,
             :children_preference,
             :life_goals,
             :ministry_involvement,
             :interests,
             :lifestyle,
             # Partner Preferences
             :partner_description,
             :dealbreakers,
             # System
             :active,
             :visible,
             :last_search_at,
             # Verification
             :verification_status,
             # Computed
             :completion_percentage,
             :meets_minimum_completion

  def meets_minimum_completion
    object.meets_minimum_completion?
  end

  def completion_percentage
    object.completion_percentage
  end
end
