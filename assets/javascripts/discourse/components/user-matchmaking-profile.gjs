import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/components/d-button";
import { i18n } from "discourse-i18n";

const TEXT_MAX = 500;

export default class UserMatchmakingProfile extends Component {
  @tracked loading = true;
  @tracked saving = false;
  @tracked saved = false;
  @tracked profile = null;
  @tracked consentStatus = null;
  @tracked error = null;
  @tracked deleteConfirming = false;
  @tracked validationErrors = [];

  // Phase 5: Toggle + consent modal state
  @tracked featureEnabled = false;
  @tracked showConsentModal = false;
  @tracked showDeactivateModal = false;
  @tracked exporting = false;
  @tracked exported = false;

  // Trust Gate: Verification status
  @tracked verificationStatus = null;

  @tracked gender = "";
  @tracked seekingGender = "";
  @tracked birthYear = "";
  @tracked ageMinPreference = "";
  @tracked ageMaxPreference = "";
  @tracked country = "United States";
  @tracked state = "";
  @tracked city = "";
  @tracked zipCode = "";
  @tracked locationFlexibility = "";
  @tracked denomination = "";
  @tracked denominationImportance = "";
  @tracked churchAttendance = "";
  @tracked baptismStatus = "";
  @tracked bibleEngagement = "";
  @tracked testimony = "";
  @tracked relationshipIntention = "";
  @tracked childrenPreference = "";
  @tracked lifeGoals = "";
  @tracked ministryInvolvement = "";
  @tracked partnerDescription = "";
  @tracked profileActive = true;
  @tracked profileVisible = true;

  @tracked tvSpiritualGifts = "";
  @tracked tvCreation = "";
  @tracked tvGenderRoles = "";
  @tracked tvEndTimes = "";
  @tracked tvSalvationSecurity = "";

  @tracked selectedInterests = [];
  @tracked selectedLifestyle = [];
  @tracked selectedDealbreakers = [];

  constructor() {
    super(...arguments);
    this.loadProfile();
  }

  // Phase 5: Feature is "enabled" if user has active consent
  get isFeatureOn() { return this.featureEnabled; }
  get isFeatureOff() { return !this.featureEnabled && !this.loading; }

  get needsConsent() { return this.consentStatus && !this.consentStatus.profile_creation; }
  get hasConsent() { return this.consentStatus && this.consentStatus.profile_creation; }
  get hasProfile() { return !!this.profile; }
  get hasErrors() { return this.validationErrors.length > 0; }
  get saveLabel() { return this.saving ? "discourse_matchmaking.profile.saving" : "discourse_matchmaking.profile.save"; }

  // Trust Gate: Verification status getters
  get showVerificationBanner() {
    return this.hasProfile && this.verificationStatus && this.verificationStatus !== "unverified";
  }
  get isVerificationPending() { return this.verificationStatus === "pending_interview"; }
  get isVerificationReview() { return this.verificationStatus === "flagged"; }
  get isVerificationVerified() { return this.verificationStatus === "verified"; }
  get isVerificationRejected() { return this.verificationStatus === "rejected"; }

  get verificationBannerClass() {
    if (this.isVerificationPending) return "status-pending";
    if (this.isVerificationReview) return "status-review";
    if (this.isVerificationVerified) return "status-verified";
    if (this.isVerificationRejected) return "status-flagged";
    return "";
  }

  get verificationIcon() {
    if (this.isVerificationPending) return "💬";
    if (this.isVerificationReview) return "⏳";
    if (this.isVerificationVerified) return "✓";
    if (this.isVerificationRejected) return "⚠";
    return "";
  }

  get aiConversationsUrl() {
    return "/discourse-ai/ai-bot/conversations";
  }

  get completionPercentage() {
    if (this.profile) return this.profile.completion_percentage;
    let s = 0;
    const h = (v) => v !== "" && v != null;
    s += 20 * ([this.gender, this.seekingGender, this.birthYear, this.ageMinPreference, this.ageMaxPreference].filter(h).length / 5);
    s += 10 * ([this.country, this.state, this.locationFlexibility].filter(h).length / 3);
    s += 30 * ([this.denomination, this.churchAttendance, this.testimony].filter(h).length / 3);
    const tvCount = [this.tvSpiritualGifts, this.tvCreation, this.tvGenderRoles, this.tvEndTimes, this.tvSalvationSecurity].filter(h).length;
    s += 10 * Math.min(tvCount / 3, 1);
    s += 15 * ([this.relationshipIntention, this.childrenPreference, this.lifeGoals].filter(h).length / 3);
    if (h(this.partnerDescription)) s += 15;
    return Math.round(s);
  }

  get completionStyle() { return `width: ${this.completionPercentage}%`; }
  get testimonyLen() { return (this.testimony || "").length; }
  get lifeGoalsLen() { return (this.lifeGoals || "").length; }
  get ministryLen() { return (this.ministryInvolvement || "").length; }
  get partnerLen() { return (this.partnerDescription || "").length; }
  get testimonyNear() { return this.testimonyLen > 450; }
  get lifeGoalsNear() { return this.lifeGoalsLen > 450; }
  get ministryNear() { return this.ministryLen > 450; }
  get partnerNear() { return this.partnerLen > 450; }

  get interestChips() {
    return ["hiking", "worship_music", "cooking", "travel", "reading", "sports", "art", "gardening", "technology", "volunteering", "missions", "bible_study", "prayer", "writing", "photography", "fitness", "music", "outdoors", "board_games", "movies"]
      .map((v) => ({ value: v, label: v.replace(/_/g, " "), selected: this.selectedInterests.includes(v) }));
  }

  get lifestyleChips() {
    return ["no_alcohol", "no_tobacco", "fitness_active", "homeschool_interest", "minimalist", "outdoorsy", "early_riser", "night_owl", "vegetarian", "health_conscious"]
      .map((v) => ({ value: v, label: v.replace(/_/g, " "), selected: this.selectedLifestyle.includes(v) }));
  }

  get dealbreakerChips() {
    return ["smoking", "heavy_drinking", "different_denomination", "no_church_attendance", "no_children", "dishonesty", "unequally_yoked"]
      .map((v) => ({ value: v, label: v.replace(/_/g, " "), selected: this.selectedDealbreakers.includes(v) }));
  }

  _populate(p) {
    this.gender = p.gender || "";
    this.seekingGender = p.seeking_gender || "";
    this.birthYear = p.birth_year || "";
    this.ageMinPreference = p.age_min_preference || "";
    this.ageMaxPreference = p.age_max_preference || "";
    this.country = p.country || "United States";
    this.state = p.state || "";
    this.city = p.city || "";
    this.zipCode = p.zip_code || "";
    this.locationFlexibility = p.location_flexibility || "";
    this.denomination = p.denomination || "";
    this.denominationImportance = p.denomination_importance || "";
    this.churchAttendance = p.church_attendance || "";
    this.baptismStatus = p.baptism_status || "";
    this.bibleEngagement = p.bible_engagement || "";
    this.testimony = p.testimony || "";
    this.relationshipIntention = p.relationship_intention || "";
    this.childrenPreference = p.children_preference || "";
    this.lifeGoals = p.life_goals || "";
    this.ministryInvolvement = p.ministry_involvement || "";
    this.partnerDescription = p.partner_description || "";
    this.profileActive = p.active !== false;
    this.profileVisible = p.visible !== false;
    const tv = p.theological_views || {};
    this.tvSpiritualGifts = tv.spiritual_gifts || "";
    this.tvCreation = tv.creation || "";
    this.tvGenderRoles = tv.gender_roles || "";
    this.tvEndTimes = tv.end_times || "";
    this.tvSalvationSecurity = tv.salvation_security || "";
    this.selectedInterests = p.interests || [];
    this.selectedLifestyle = p.lifestyle || [];
    this.selectedDealbreakers = p.dealbreakers || [];
    // Trust Gate: track verification status
    this.verificationStatus = p.verification_status || null;
  }

  _payload() {
    const tv = {};
    if (this.tvSpiritualGifts) tv.spiritual_gifts = this.tvSpiritualGifts;
    if (this.tvCreation) tv.creation = this.tvCreation;
    if (this.tvGenderRoles) tv.gender_roles = this.tvGenderRoles;
    if (this.tvEndTimes) tv.end_times = this.tvEndTimes;
    if (this.tvSalvationSecurity) tv.salvation_security = this.tvSalvationSecurity;
    return {
      matchmaking_profile: {
        gender: this.gender, seeking_gender: this.seekingGender,
        birth_year: this.birthYear ? parseInt(this.birthYear, 10) : null,
        age_min_preference: this.ageMinPreference ? parseInt(this.ageMinPreference, 10) : null,
        age_max_preference: this.ageMaxPreference ? parseInt(this.ageMaxPreference, 10) : null,
        country: this.country, state: this.state, city: this.city,
        zip_code: this.zipCode,
        location_flexibility: this.locationFlexibility,
        denomination: this.denomination, denomination_importance: this.denominationImportance,
        church_attendance: this.churchAttendance, baptism_status: this.baptismStatus,
        bible_engagement: this.bibleEngagement,
        testimony: (this.testimony || "").slice(0, TEXT_MAX),
        relationship_intention: this.relationshipIntention,
        children_preference: this.childrenPreference,
        life_goals: (this.lifeGoals || "").slice(0, TEXT_MAX),
        ministry_involvement: (this.ministryInvolvement || "").slice(0, TEXT_MAX),
        partner_description: (this.partnerDescription || "").slice(0, TEXT_MAX),
        active: this.profileActive, visible: this.profileVisible,
        theological_views: tv,
        interests: this.selectedInterests, lifestyle: this.selectedLifestyle,
        dealbreakers: this.selectedDealbreakers,
      },
    };
  }

  async loadProfile() {
    try {
      const result = await ajax("/matchmaking/profile");
      this.profile = result.matchmaking_profile;
      this.consentStatus = result.consent_status;
      if (this.profile) {
        this._populate(this.profile);
        this.featureEnabled = true;
      } else if (this.consentStatus && this.consentStatus.profile_creation) {
        this.featureEnabled = true;
      }
    } catch (e) {
      if (e.jqXHR?.status === 403) {
        try {
          const r = await ajax("/matchmaking/consent-status");
          this.consentStatus = r.consent_status;
          // If they have consent but no profile, feature is on
          if (this.consentStatus && this.consentStatus.profile_creation) {
            this.featureEnabled = true;
          }
        } catch { this.error = "matchmaking_unavailable"; }
      } else { popupAjaxError(e); }
    } finally { this.loading = false; }
  }

  // Phase 5: Toggle ON → show consent modal
  @action handleToggleOn() {
    this.showConsentModal = true;
  }

  // Phase 5: Toggle OFF → show deactivate choice modal
  @action handleToggleOff() {
    this.showDeactivateModal = true;
  }

  // Phase 5: Accept GDPR consent from modal
  @action async acceptConsent() {
    try {
      const r = await ajax("/matchmaking/grant-consent", { type: "POST" });
      this.consentStatus = r.consent_status;
      this.featureEnabled = true;
      this.showConsentModal = false;
      await this.loadProfile();
    } catch (e) { popupAjaxError(e); }
  }

  // Phase 5: Decline consent (close modal, stay off)
  @action declineConsent() {
    this.showConsentModal = false;
  }

  // Phase 5: Deactivate — keep data but hide profile
  @action async deactivateKeepData() {
    try {
      if (this.profile) {
        await ajax("/matchmaking/profile", {
          type: "PUT",
          contentType: "application/json",
          data: JSON.stringify({ matchmaking_profile: { active: false, visible: false } }),
        });
      }
      this.featureEnabled = false;
      this.showDeactivateModal = false;
      this.profileActive = false;
      this.profileVisible = false;
    } catch (e) { popupAjaxError(e); }
  }

  // Phase 5: Deactivate — delete everything
  @action async deactivateDeleteAll() {
    try {
      await ajax("/matchmaking/profile", { type: "DELETE" });
      this.profile = null;
      this.featureEnabled = false;
      this.showDeactivateModal = false;
      this.deleteConfirming = false;
      this._populate({ active: true, visible: true });
      const r = await ajax("/matchmaking/consent-status");
      this.consentStatus = r.consent_status;
    } catch (e) { popupAjaxError(e); }
  }

  // Phase 5: Cancel deactivate modal
  @action cancelDeactivate() {
    this.showDeactivateModal = false;
  }

  // Phase 5: Export matchmaking data
  @action async exportData() {
    this.exporting = true;
    this.exported = false;
    try {
      const result = await ajax("/matchmaking/export");
      const blob = new Blob([JSON.stringify(result, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "matchmaking-data-export.json";
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      this.exported = true;
    } catch (e) { popupAjaxError(e); }
    finally { this.exporting = false; }
  }

  // Legacy consent grant (kept for compatibility)
  @action async grantConsent() {
    try {
      const r = await ajax("/matchmaking/grant-consent", { type: "POST" });
      this.consentStatus = r.consent_status;
      this.featureEnabled = true;
      await this.loadProfile();
    } catch (e) { popupAjaxError(e); }
  }

  @action updateField(field, event) { this[field] = event.target.value; this.saved = false; }
  @action updateCheckbox(field, event) { this[field] = event.target.checked; this.saved = false; }

  @action toggleChip(field, value) {
    const c = [...this[field]];
    const i = c.indexOf(value);
    if (i === -1) { c.push(value); } else { c.splice(i, 1); }
    this[field] = c;
    this.saved = false;
  }

  @action async saveProfile() {
    this.saving = true; this.saved = false; this.validationErrors = [];
    try {
      const type = this.hasProfile ? "PUT" : "POST";
      const result = await ajax("/matchmaking/profile", {
        type,
        contentType: "application/json",
        data: JSON.stringify(this._payload()),
      });
      this.profile = result.matchmaking_profile;
      if (this.profile) this._populate(this.profile);
      this.saved = true;
    } catch (e) {
      if (e.jqXHR?.status === 422) {
        this.validationErrors = e.jqXHR.responseJSON?.errors || ["An error occurred."];
      } else { popupAjaxError(e); }
    } finally { this.saving = false; }
  }

  @action toggleDeleteConfirm() { this.deleteConfirming = !this.deleteConfirming; }

  @action async deleteProfile() {
    try {
      await ajax("/matchmaking/profile", { type: "DELETE" });
      this.profile = null; this.deleteConfirming = false;
      this.featureEnabled = false;
      this._populate({ active: true, visible: true });
      const r = await ajax("/matchmaking/consent-status");
      this.consentStatus = r.consent_status;
    } catch (e) { popupAjaxError(e); }
  }

  <template>
    <div class="matchmaking-profile-editor">

      {{#if this.loading}}
        <p>{{i18n "loading"}}</p>

      {{else if this.error}}
        <p>{{i18n "discourse_matchmaking.errors.not_enabled"}}</p>

      {{else}}

        {{! ── Phase 5: Feature Header with Toggle ── }}
        <div class="matchmaking-feature-header">
          <div class="feature-header-content">
            <div class="feature-title">{{i18n "discourse_matchmaking.feature.title"}}</div>
            <div class="feature-description">{{i18n "discourse_matchmaking.feature.description"}}</div>
          </div>
          <div class="feature-toggle">
            {{#if this.isFeatureOn}}
              <button type="button" class="toggle-switch on" {{on "click" this.handleToggleOff}} aria-label="Disable matchmaking">
                <span class="toggle-knob"></span>
              </button>
            {{else}}
              <button type="button" class="toggle-switch off" {{on "click" this.handleToggleOn}} aria-label="Enable matchmaking">
                <span class="toggle-knob"></span>
              </button>
            {{/if}}
          </div>
        </div>

        {{! ── Phase 5: GDPR Consent Modal ── }}
        {{#if this.showConsentModal}}
          <div class="matchmaking-modal-overlay" {{on "click" this.declineConsent}}>
            <div class="matchmaking-modal" {{on "click" this.stopPropagation}}>
              <div class="modal-header">
                <h3>{{i18n "discourse_matchmaking.consent_modal.title"}}</h3>
              </div>
              <div class="modal-body">
                <p>{{i18n "discourse_matchmaking.consent_modal.intro"}}</p>
                <div class="consent-data-list">
                  <div class="consent-data-item">
                    <span class="consent-icon">✦</span>
                    <span>{{i18n "discourse_matchmaking.consent_modal.data_religious"}}</span>
                  </div>
                  <div class="consent-data-item">
                    <span class="consent-icon">✦</span>
                    <span>{{i18n "discourse_matchmaking.consent_modal.data_matching"}}</span>
                  </div>
                  <div class="consent-data-item">
                    <span class="consent-icon">✦</span>
                    <span>{{i18n "discourse_matchmaking.consent_modal.data_llm"}}</span>
                  </div>
                </div>
                <p class="consent-legal">{{i18n "discourse_matchmaking.consent_modal.gdpr_notice"}}</p>
                <p class="consent-rights">{{i18n "discourse_matchmaking.consent_modal.rights"}}</p>
              </div>
              <div class="modal-footer">
                <DButton @action={{this.acceptConsent}} @label="discourse_matchmaking.consent_modal.accept" class="btn-primary" />
                <DButton @action={{this.declineConsent}} @label="discourse_matchmaking.consent_modal.decline" class="btn-flat" />
              </div>
            </div>
          </div>
        {{/if}}

        {{! ── Phase 5: Deactivate Choice Modal ── }}
        {{#if this.showDeactivateModal}}
          <div class="matchmaking-modal-overlay" {{on "click" this.cancelDeactivate}}>
            <div class="matchmaking-modal" {{on "click" this.stopPropagation}}>
              <div class="modal-header">
                <h3>{{i18n "discourse_matchmaking.deactivate_modal.title"}}</h3>
              </div>
              <div class="modal-body">
                <p>{{i18n "discourse_matchmaking.deactivate_modal.description"}}</p>
              </div>
              <div class="modal-footer modal-footer-stacked">
                <DButton @action={{this.deactivateKeepData}} @label="discourse_matchmaking.deactivate_modal.keep_data" class="btn-default" />
                <DButton @action={{this.deactivateDeleteAll}} @label="discourse_matchmaking.deactivate_modal.delete_all" class="btn-danger" />
                <DButton @action={{this.cancelDeactivate}} @label="cancel" class="btn-flat" />
              </div>
            </div>
          </div>
        {{/if}}

        {{! ── Feature ON: Show profile editor ── }}
        {{#if this.isFeatureOn}}

          <div class="profile-completion">
            <div class="completion-bar"><div class="completion-fill" style={{this.completionStyle}}></div></div>
            <span class="completion-text">{{this.completionPercentage}}% {{i18n "discourse_matchmaking.profile.completion"}}</span>
          </div>

          {{! ── Trust Gate: Verification Status Banner ── }}
          {{#if this.showVerificationBanner}}
            <div class="verification-status-banner {{this.verificationBannerClass}}">
              <span class="verification-icon">{{this.verificationIcon}}</span>
              <div class="verification-content">
                {{#if this.isVerificationPending}}
                  <div class="verification-title">{{i18n "discourse_matchmaking.verification.status_pending"}}</div>
                  <div class="verification-description">{{i18n "discourse_matchmaking.verification.status_pending_description"}}</div>
                  <a href={{this.aiConversationsUrl}} class="btn btn-primary btn-small">{{i18n "discourse_matchmaking.verification.status_pending_action"}}</a>
                {{else if this.isVerificationReview}}
                  <div class="verification-title">{{i18n "discourse_matchmaking.verification.status_review"}}</div>
                  <div class="verification-description">{{i18n "discourse_matchmaking.verification.status_review_description"}}</div>
                {{else if this.isVerificationVerified}}
                  <div class="verification-title">{{i18n "discourse_matchmaking.verification.status_verified"}}</div>
                  <div class="verification-description">{{i18n "discourse_matchmaking.verification.status_verified_description"}}</div>
                {{else if this.isVerificationRejected}}
                  <div class="verification-title">{{i18n "discourse_matchmaking.verification.status_rejected"}}</div>
                  <div class="verification-description">{{i18n "discourse_matchmaking.verification.status_rejected_description"}}</div>
                {{/if}}
              </div>
            </div>
          {{/if}}

          {{#if this.hasErrors}}
            <div class="matchmaking-errors">{{#each this.validationErrors as |err|}}<p>{{err}}</p>{{/each}}</div>
          {{/if}}

          {{! ── About You ── }}
          <div class="profile-section">
            <div class="profile-section-title">{{i18n "discourse_matchmaking.profile.section_identity"}}</div>
            <div class="profile-field-row">
              <div class="profile-field">
                <label>{{i18n "discourse_matchmaking.profile.gender"}}</label>
                <select {{on "change" (fn this.updateField "gender")}}>
                  <option value="">—</option>
                  <option value="male" selected={{this.genderMale}}>{{i18n "discourse_matchmaking.gender_options.male"}}</option>
                  <option value="female" selected={{this.genderFemale}}>{{i18n "discourse_matchmaking.gender_options.female"}}</option>
                </select>
              </div>
              <div class="profile-field">
                <label>{{i18n "discourse_matchmaking.profile.seeking_gender"}}</label>
                <select {{on "change" (fn this.updateField "seekingGender")}}>
                  <option value="">—</option>
                  <option value="male" selected={{this.seekingMale}}>{{i18n "discourse_matchmaking.gender_options.male"}}</option>
                  <option value="female" selected={{this.seekingFemale}}>{{i18n "discourse_matchmaking.gender_options.female"}}</option>
                </select>
              </div>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.birth_year"}}</label>
              <input type="number" min="1930" max="2008" value={{this.birthYear}} {{on "input" (fn this.updateField "birthYear")}} />
            </div>
            <div class="profile-field-row">
              <div class="profile-field">
                <label>{{i18n "discourse_matchmaking.profile.age_min"}}</label>
                <input type="number" min="18" max="80" value={{this.ageMinPreference}} {{on "input" (fn this.updateField "ageMinPreference")}} />
              </div>
              <div class="profile-field">
                <label>{{i18n "discourse_matchmaking.profile.age_max"}}</label>
                <input type="number" min="18" max="80" value={{this.ageMaxPreference}} {{on "input" (fn this.updateField "ageMaxPreference")}} />
              </div>
            </div>
          </div>

          {{! ── Location ── }}
          <div class="profile-section">
            <div class="profile-section-title">{{i18n "discourse_matchmaking.profile.section_location"}}</div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.country"}}</label>
              <input type="text" value={{this.country}} {{on "input" (fn this.updateField "country")}} />
            </div>
            <div class="profile-field-row">
              <div class="profile-field">
                <label>{{i18n "discourse_matchmaking.profile.state"}}</label>
                <input type="text" value={{this.state}} {{on "input" (fn this.updateField "state")}} />
              </div>
              <div class="profile-field">
                <label>{{i18n "discourse_matchmaking.profile.city"}}</label>
                <input type="text" value={{this.city}} {{on "input" (fn this.updateField "city")}} />
              </div>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.location_flexibility"}}</label>
              <select {{on "change" (fn this.updateField "locationFlexibility")}}>
                <option value="">—</option>
                <option value="local_only" selected={{this.locLocal}}>{{i18n "discourse_matchmaking.location_flexibility_options.local_only"}}</option>
                <option value="state" selected={{this.locState}}>{{i18n "discourse_matchmaking.location_flexibility_options.state"}}</option>
                <option value="regional" selected={{this.locRegional}}>{{i18n "discourse_matchmaking.location_flexibility_options.regional"}}</option>
                <option value="national" selected={{this.locNational}}>{{i18n "discourse_matchmaking.location_flexibility_options.national"}}</option>
                <option value="international" selected={{this.locInternational}}>{{i18n "discourse_matchmaking.location_flexibility_options.international"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.zip_code"}}</label>
              <input type="text" maxlength="10" value={{this.zipCode}} {{on "input" (fn this.updateField "zipCode")}} />
            </div>
          </div>
          {{! ── Faith Foundation ── }}
          <div class="profile-section">
            <div class="profile-section-title">{{i18n "discourse_matchmaking.profile.section_faith"}}</div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.denomination"}}</label>
              <select {{on "change" (fn this.updateField "denomination")}}>
                <option value="">—</option>
                <option value="baptist" selected={{this.denomBaptist}}>{{i18n "discourse_matchmaking.denomination_options.baptist"}}</option>
                <option value="reformed" selected={{this.denomReformed}}>{{i18n "discourse_matchmaking.denomination_options.reformed"}}</option>
                <option value="non_denominational" selected={{this.denomNonDenom}}>{{i18n "discourse_matchmaking.denomination_options.non_denominational"}}</option>
                <option value="catholic" selected={{this.denomCatholic}}>{{i18n "discourse_matchmaking.denomination_options.catholic"}}</option>
                <option value="pentecostal" selected={{this.denomPentecostal}}>{{i18n "discourse_matchmaking.denomination_options.pentecostal"}}</option>
                <option value="methodist" selected={{this.denomMethodist}}>{{i18n "discourse_matchmaking.denomination_options.methodist"}}</option>
                <option value="presbyterian" selected={{this.denomPresbyterian}}>{{i18n "discourse_matchmaking.denomination_options.presbyterian"}}</option>
                <option value="lutheran" selected={{this.denomLutheran}}>{{i18n "discourse_matchmaking.denomination_options.lutheran"}}</option>
                <option value="anglican" selected={{this.denomAnglican}}>{{i18n "discourse_matchmaking.denomination_options.anglican"}}</option>
                <option value="orthodox" selected={{this.denomOrthodox}}>{{i18n "discourse_matchmaking.denomination_options.orthodox"}}</option>
                <option value="church_of_christ" selected={{this.denomChurchOfChrist}}>{{i18n "discourse_matchmaking.denomination_options.church_of_christ"}}</option>
                <option value="adventist" selected={{this.denomAdventist}}>{{i18n "discourse_matchmaking.denomination_options.adventist"}}</option>
                <option value="other" selected={{this.denomOther}}>{{i18n "discourse_matchmaking.denomination_options.other"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.denomination_importance"}}</label>
              <select {{on "change" (fn this.updateField "denominationImportance")}}>
                <option value="">—</option>
                <option value="essential" selected={{this.diEssential}}>{{i18n "discourse_matchmaking.denomination_importance_options.essential"}}</option>
                <option value="preferred" selected={{this.diPreferred}}>{{i18n "discourse_matchmaking.denomination_importance_options.preferred"}}</option>
                <option value="flexible" selected={{this.diFlexible}}>{{i18n "discourse_matchmaking.denomination_importance_options.flexible"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.church_attendance"}}</label>
              <select {{on "change" (fn this.updateField "churchAttendance")}}>
                <option value="">—</option>
                <option value="multiple_weekly" selected={{this.caMultiple}}>{{i18n "discourse_matchmaking.church_attendance_options.multiple_weekly"}}</option>
                <option value="weekly" selected={{this.caWeekly}}>{{i18n "discourse_matchmaking.church_attendance_options.weekly"}}</option>
                <option value="bi_weekly" selected={{this.caBiWeekly}}>{{i18n "discourse_matchmaking.church_attendance_options.bi_weekly"}}</option>
                <option value="monthly" selected={{this.caMonthly}}>{{i18n "discourse_matchmaking.church_attendance_options.monthly"}}</option>
                <option value="occasional" selected={{this.caOccasional}}>{{i18n "discourse_matchmaking.church_attendance_options.occasional"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.baptism_status"}}</label>
              <select {{on "change" (fn this.updateField "baptismStatus")}}>
                <option value="">—</option>
                <option value="baptized" selected={{this.bsBaptized}}>{{i18n "discourse_matchmaking.baptism_status_options.baptized"}}</option>
                <option value="not_yet" selected={{this.bsNotYet}}>{{i18n "discourse_matchmaking.baptism_status_options.not_yet"}}</option>
                <option value="planning" selected={{this.bsPlanning}}>{{i18n "discourse_matchmaking.baptism_status_options.planning"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.bible_engagement"}}</label>
              <select {{on "change" (fn this.updateField "bibleEngagement")}}>
                <option value="">—</option>
                <option value="daily" selected={{this.beDaily}}>{{i18n "discourse_matchmaking.bible_engagement_options.daily"}}</option>
                <option value="several_weekly" selected={{this.beSeveral}}>{{i18n "discourse_matchmaking.bible_engagement_options.several_weekly"}}</option>
                <option value="weekly" selected={{this.beWeekly}}>{{i18n "discourse_matchmaking.bible_engagement_options.weekly"}}</option>
                <option value="occasional" selected={{this.beOccasional}}>{{i18n "discourse_matchmaking.bible_engagement_options.occasional"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.testimony"}}</label>
              <div class="field-help">{{i18n "discourse_matchmaking.profile.testimony_help"}}</div>
              <textarea maxlength="500" {{on "input" (fn this.updateField "testimony")}}>{{this.testimony}}</textarea>
              <div class="char-count {{if this.testimonyNear 'near-limit'}}">{{this.testimonyLen}}/500</div>
            </div>
          </div>

          {{! ── Theological Views ── }}
          <div class="profile-section">
            <div class="profile-section-title">{{i18n "discourse_matchmaking.profile.section_theology"}}</div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.theological_views.spiritual_gifts"}}</label>
              <select {{on "change" (fn this.updateField "tvSpiritualGifts")}}>
                <option value="">—</option>
                <option value="continuationist" selected={{this.sgCont}}>{{i18n "discourse_matchmaking.theological_options.spiritual_gifts.continuationist"}}</option>
                <option value="cessationist" selected={{this.sgCess}}>{{i18n "discourse_matchmaking.theological_options.spiritual_gifts.cessationist"}}</option>
                <option value="open_but_cautious" selected={{this.sgOpen}}>{{i18n "discourse_matchmaking.theological_options.spiritual_gifts.open_but_cautious"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.theological_views.creation"}}</label>
              <select {{on "change" (fn this.updateField "tvCreation")}}>
                <option value="">—</option>
                <option value="young_earth" selected={{this.crYoung}}>{{i18n "discourse_matchmaking.theological_options.creation.young_earth"}}</option>
                <option value="old_earth" selected={{this.crOld}}>{{i18n "discourse_matchmaking.theological_options.creation.old_earth"}}</option>
                <option value="theistic_evolution" selected={{this.crTheistic}}>{{i18n "discourse_matchmaking.theological_options.creation.theistic_evolution"}}</option>
                <option value="undecided" selected={{this.crUndecided}}>{{i18n "discourse_matchmaking.theological_options.creation.undecided"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.theological_views.gender_roles"}}</label>
              <select {{on "change" (fn this.updateField "tvGenderRoles")}}>
                <option value="">—</option>
                <option value="complementarian" selected={{this.grComp}}>{{i18n "discourse_matchmaking.theological_options.gender_roles.complementarian"}}</option>
                <option value="egalitarian" selected={{this.grEgal}}>{{i18n "discourse_matchmaking.theological_options.gender_roles.egalitarian"}}</option>
                <option value="somewhere_between" selected={{this.grBetween}}>{{i18n "discourse_matchmaking.theological_options.gender_roles.somewhere_between"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.theological_views.end_times"}}</label>
              <select {{on "change" (fn this.updateField "tvEndTimes")}}>
                <option value="">—</option>
                <option value="premillennial" selected={{this.etPre}}>{{i18n "discourse_matchmaking.theological_options.end_times.premillennial"}}</option>
                <option value="amillennial" selected={{this.etAmil}}>{{i18n "discourse_matchmaking.theological_options.end_times.amillennial"}}</option>
                <option value="postmillennial" selected={{this.etPost}}>{{i18n "discourse_matchmaking.theological_options.end_times.postmillennial"}}</option>
                <option value="pan_millennial" selected={{this.etPan}}>{{i18n "discourse_matchmaking.theological_options.end_times.pan_millennial"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.theological_views.salvation_security"}}</label>
              <select {{on "change" (fn this.updateField "tvSalvationSecurity")}}>
                <option value="">—</option>
                <option value="eternal_security" selected={{this.ssEternal}}>{{i18n "discourse_matchmaking.theological_options.salvation_security.eternal_security"}}</option>
                <option value="conditional" selected={{this.ssCond}}>{{i18n "discourse_matchmaking.theological_options.salvation_security.conditional"}}</option>
                <option value="undecided" selected={{this.ssUndecided}}>{{i18n "discourse_matchmaking.theological_options.salvation_security.undecided"}}</option>
              </select>
            </div>
          </div>

          {{! ── Values & Goals ── }}
          <div class="profile-section">
            <div class="profile-section-title">{{i18n "discourse_matchmaking.profile.section_values"}}</div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.relationship_intention"}}</label>
              <select {{on "change" (fn this.updateField "relationshipIntention")}}>
                <option value="">—</option>
                <option value="marriage_minded" selected={{this.riMarriage}}>{{i18n "discourse_matchmaking.relationship_intention_options.marriage_minded"}}</option>
                <option value="exploring" selected={{this.riExploring}}>{{i18n "discourse_matchmaking.relationship_intention_options.exploring"}}</option>
                <option value="friendship_first" selected={{this.riFriendship}}>{{i18n "discourse_matchmaking.relationship_intention_options.friendship_first"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.children_preference"}}</label>
              <select {{on "change" (fn this.updateField "childrenPreference")}}>
                <option value="">—</option>
                <option value="want_children" selected={{this.cpWant}}>{{i18n "discourse_matchmaking.children_preference_options.want_children"}}</option>
                <option value="have_and_want_more" selected={{this.cpHaveMore}}>{{i18n "discourse_matchmaking.children_preference_options.have_and_want_more"}}</option>
                <option value="have_done" selected={{this.cpDone}}>{{i18n "discourse_matchmaking.children_preference_options.have_done"}}</option>
                <option value="open" selected={{this.cpOpen}}>{{i18n "discourse_matchmaking.children_preference_options.open"}}</option>
                <option value="no_children" selected={{this.cpNo}}>{{i18n "discourse_matchmaking.children_preference_options.no_children"}}</option>
              </select>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.life_goals"}}</label>
              <div class="field-help">{{i18n "discourse_matchmaking.profile.life_goals_help"}}</div>
              <textarea maxlength="500" {{on "input" (fn this.updateField "lifeGoals")}}>{{this.lifeGoals}}</textarea>
              <div class="char-count {{if this.lifeGoalsNear 'near-limit'}}">{{this.lifeGoalsLen}}/500</div>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.ministry_involvement"}}</label>
              <div class="field-help">{{i18n "discourse_matchmaking.profile.ministry_involvement_help"}}</div>
              <textarea maxlength="500" {{on "input" (fn this.updateField "ministryInvolvement")}}>{{this.ministryInvolvement}}</textarea>
              <div class="char-count {{if this.ministryNear 'near-limit'}}">{{this.ministryLen}}/500</div>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.interests"}}</label>
              <div class="chip-selector">
                {{#each this.interestChips as |chip|}}
                  <button type="button" class="chip {{if chip.selected 'selected'}}" {{on "click" (fn this.toggleChip "selectedInterests" chip.value)}}>{{chip.label}}</button>
                {{/each}}
              </div>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.lifestyle"}}</label>
              <div class="chip-selector">
                {{#each this.lifestyleChips as |chip|}}
                  <button type="button" class="chip {{if chip.selected 'selected'}}" {{on "click" (fn this.toggleChip "selectedLifestyle" chip.value)}}>{{chip.label}}</button>
                {{/each}}
              </div>
            </div>
          </div>

          {{! ── Partner Preferences ── }}
          <div class="profile-section">
            <div class="profile-section-title">{{i18n "discourse_matchmaking.profile.section_partner"}}</div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.partner_description"}}</label>
              <div class="field-help">{{i18n "discourse_matchmaking.profile.partner_description_help"}}</div>
              <textarea maxlength="500" {{on "input" (fn this.updateField "partnerDescription")}}>{{this.partnerDescription}}</textarea>
              <div class="char-count {{if this.partnerNear 'near-limit'}}">{{this.partnerLen}}/500</div>
            </div>
            <div class="profile-field">
              <label>{{i18n "discourse_matchmaking.profile.dealbreakers"}}</label>
              <div class="chip-selector">
                {{#each this.dealbreakerChips as |chip|}}
                  <button type="button" class="chip {{if chip.selected 'selected'}}" {{on "click" (fn this.toggleChip "selectedDealbreakers" chip.value)}}>{{chip.label}}</button>
                {{/each}}
              </div>
            </div>
          </div>

          {{! ── Visibility ── }}
          <div class="profile-section">
            <div class="profile-field"><label><input type="checkbox" checked={{this.profileActive}} {{on "change" (fn this.updateCheckbox "profileActive")}} /> {{i18n "discourse_matchmaking.profile.active"}}</label></div>
            <div class="profile-field"><label><input type="checkbox" checked={{this.profileVisible}} {{on "change" (fn this.updateCheckbox "profileVisible")}} /> {{i18n "discourse_matchmaking.profile.visible"}}</label></div>
          </div>

          {{! ── Save ── }}
          <div class="profile-actions">
            <DButton @action={{this.saveProfile}} @label={{this.saveLabel}} @disabled={{this.saving}} class="btn-primary" />
            {{#if this.saved}}<span class="save-status">{{i18n "discourse_matchmaking.profile.saved"}}</span>{{/if}}
          </div>

          {{! ── Data Management ── }}
          <div class="profile-data-management">
            <div class="data-management-title">{{i18n "discourse_matchmaking.data.title"}}</div>
            <div class="data-management-actions">
              <DButton @action={{this.exportData}} @label="discourse_matchmaking.data.export" @disabled={{this.exporting}} class="btn-default" />
              {{#if this.exported}}<span class="export-status">{{i18n "discourse_matchmaking.data.exported"}}</span>{{/if}}
            </div>
          </div>

          {{! ── Danger Zone ── }}
          {{#if this.hasProfile}}
            <div class="profile-danger-zone">
              <div class="danger-title">{{i18n "discourse_matchmaking.profile.delete"}}</div>
              {{#if this.deleteConfirming}}
                <div class="danger-description">{{i18n "discourse_matchmaking.profile.delete_confirm"}}</div>
                <DButton @action={{this.deleteProfile}} @label="discourse_matchmaking.profile.delete" class="btn-danger" />
                <DButton @action={{this.toggleDeleteConfirm}} @label="cancel" class="btn-flat" />
              {{else}}
                <DButton @action={{this.toggleDeleteConfirm}} @label="discourse_matchmaking.profile.delete" class="btn-danger" />
              {{/if}}
            </div>
          {{/if}}

        {{/if}}
      {{/if}}
    </div>
  </template>

  // Prevent click propagation on modal body (so clicking modal doesn't close it)
  @action stopPropagation(event) { event.stopPropagation(); }

  // Selected-state getters for every select option
  get genderMale() { return this.gender === "male"; }
  get genderFemale() { return this.gender === "female"; }
  get seekingMale() { return this.seekingGender === "male"; }
  get seekingFemale() { return this.seekingGender === "female"; }

  get locLocal() { return this.locationFlexibility === "local_only"; }
  get locState() { return this.locationFlexibility === "state"; }
  get locRegional() { return this.locationFlexibility === "regional"; }
  get locNational() { return this.locationFlexibility === "national"; }
  get locInternational() { return this.locationFlexibility === "international"; }

  get denomBaptist() { return this.denomination === "baptist"; }
  get denomReformed() { return this.denomination === "reformed"; }
  get denomNonDenom() { return this.denomination === "non_denominational"; }
  get denomCatholic() { return this.denomination === "catholic"; }
  get denomPentecostal() { return this.denomination === "pentecostal"; }
  get denomMethodist() { return this.denomination === "methodist"; }
  get denomPresbyterian() { return this.denomination === "presbyterian"; }
  get denomLutheran() { return this.denomination === "lutheran"; }
  get denomAnglican() { return this.denomination === "anglican"; }
  get denomOrthodox() { return this.denomination === "orthodox"; }
  get denomChurchOfChrist() { return this.denomination === "church_of_christ"; }
  get denomAdventist() { return this.denomination === "adventist"; }
  get denomOther() { return this.denomination === "other"; }

  get diEssential() { return this.denominationImportance === "essential"; }
  get diPreferred() { return this.denominationImportance === "preferred"; }
  get diFlexible() { return this.denominationImportance === "flexible"; }

  get caMultiple() { return this.churchAttendance === "multiple_weekly"; }
  get caWeekly() { return this.churchAttendance === "weekly"; }
  get caBiWeekly() { return this.churchAttendance === "bi_weekly"; }
  get caMonthly() { return this.churchAttendance === "monthly"; }
  get caOccasional() { return this.churchAttendance === "occasional"; }

  get bsBaptized() { return this.baptismStatus === "baptized"; }
  get bsNotYet() { return this.baptismStatus === "not_yet"; }
  get bsPlanning() { return this.baptismStatus === "planning"; }

  get beDaily() { return this.bibleEngagement === "daily"; }
  get beSeveral() { return this.bibleEngagement === "several_weekly"; }
  get beWeekly() { return this.bibleEngagement === "weekly"; }
  get beOccasional() { return this.bibleEngagement === "occasional"; }

  get sgCont() { return this.tvSpiritualGifts === "continuationist"; }
  get sgCess() { return this.tvSpiritualGifts === "cessationist"; }
  get sgOpen() { return this.tvSpiritualGifts === "open_but_cautious"; }

  get crYoung() { return this.tvCreation === "young_earth"; }
  get crOld() { return this.tvCreation === "old_earth"; }
  get crTheistic() { return this.tvCreation === "theistic_evolution"; }
  get crUndecided() { return this.tvCreation === "undecided"; }

  get grComp() { return this.tvGenderRoles === "complementarian"; }
  get grEgal() { return this.tvGenderRoles === "egalitarian"; }
  get grBetween() { return this.tvGenderRoles === "somewhere_between"; }

  get etPre() { return this.tvEndTimes === "premillennial"; }
  get etAmil() { return this.tvEndTimes === "amillennial"; }
  get etPost() { return this.tvEndTimes === "postmillennial"; }
  get etPan() { return this.tvEndTimes === "pan_millennial"; }

  get ssEternal() { return this.tvSalvationSecurity === "eternal_security"; }
  get ssCond() { return this.tvSalvationSecurity === "conditional"; }
  get ssUndecided() { return this.tvSalvationSecurity === "undecided"; }

  get riMarriage() { return this.relationshipIntention === "marriage_minded"; }
  get riExploring() { return this.relationshipIntention === "exploring"; }
  get riFriendship() { return this.relationshipIntention === "friendship_first"; }

  get cpWant() { return this.childrenPreference === "want_children"; }
  get cpHaveMore() { return this.childrenPreference === "have_and_want_more"; }
  get cpDone() { return this.childrenPreference === "have_done"; }
  get cpOpen() { return this.childrenPreference === "open"; }
  get cpNo() { return this.childrenPreference === "no_children"; }
}
